use std::fs;
use std::io::Write;
use std::path::Path;

use ndarray::{Array1, Array3};
use ort::{
    ep,
    session::{Session, builder::GraphOptimizationLevel},
    value::TensorRef,
};

const N_VQ: usize = 16;

fn preload_onnxruntime() -> Result<(), Box<dyn std::error::Error>> {
    let path = std::env::var("ORT_DYLIB_PATH")?;

    println!("Using ORT dylib:");
    println!("{path}");

    ort::util::preload_dylib(Path::new(&path))?;

    Ok(())
}

fn save_f32(path: &str, values: &[f32]) -> Result<(), Box<dyn std::error::Error>> {
    let mut file = fs::File::create(path)?;

    for &value in values {
        file.write_all(&value.to_le_bytes())?;
    }

    Ok(())
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    preload_onnxruntime()?;

    let root = "/Users/lawrencewong/Movies/vietnamese_shadowing";

    let model_path = format!("{root}/assets/vieneu/codec/moss_audio_tokenizer_decode_full.onnx");

    // ---------------------------------------------------------
    // These are the exact 3 frames produced by our validated
    // deterministic VieNeu generation test.
    // Shape: (3, 16)
    // ---------------------------------------------------------

    let codes: [[i32; N_VQ]; 3] = [
        [
            482, 194, 670, 241, 909, 406, 417, 626, 171, 334, 923, 273, 870, 689, 272, 49,
        ],
        [
            741, 471, 176, 747, 908, 804, 326, 869, 127, 644, 825, 690, 673, 81, 603, 697,
        ],
        [
            511, 726, 793, 357, 1014, 343, 214, 687, 420, 798, 1015, 764, 852, 802, 2, 184,
        ],
    ];

    let code_length = codes.len();

    // ---------------------------------------------------------
    // Flatten to [1, 3, 16]
    // ---------------------------------------------------------

    let mut flat = Vec::with_capacity(code_length * N_VQ);

    for frame in &codes {
        for &code in frame {
            flat.push(code);
        }
    }

    let audio_codes = Array3::from_shape_vec((1, code_length, N_VQ), flat)?;

    let audio_code_lengths = Array1::from_vec(vec![code_length as i32]);

    println!("audio_codes shape: {:?}", audio_codes.shape());

    println!("audio_code_lengths: {:?}", audio_code_lengths);

    // ---------------------------------------------------------
    // Load codec model
    // ---------------------------------------------------------

    println!();
    println!("Loading MOSS codec...");

    let mut session = Session::builder()?
        .with_optimization_level(GraphOptimizationLevel::Disable)?
        .with_inter_threads(1)?
        .with_intra_threads(1)?
        .with_intra_op_spinning(false)?
        .with_execution_providers([ep::CPU::default().build()])?
        .commit_from_file(&model_path)?;

    println!("Codec loaded.");

    // ---------------------------------------------------------
    // Decode
    // ---------------------------------------------------------

    println!();
    println!("Running codec decode...");

    let outputs = session.run(ort::inputs![
        "audio_codes" =>
            TensorRef::from_array_view(
                &audio_codes
            )?,

        "audio_code_lengths" =>
            TensorRef::from_array_view(
                &audio_code_lengths
            )?,
    ])?;

    if outputs.len() != 2 {
        return Err(format!("Expected 2 outputs, got {}", outputs.len()).into());
    }

    // ---------------------------------------------------------
    // Audio output
    //
    // Python:
    //
    // out[0][0].mean(0)
    //
    // So if output is [1, C, samples],
    // we average over C.
    // ---------------------------------------------------------

    let audio = outputs[0].try_extract_tensor::<f32>()?;

    println!("Audio shape: {:?}", audio.0);

    println!("Audio values: {}", audio.1.len());

    // Expected:
    //
    // [1, C, samples]
    //

    if audio.0.len() != 3 {
        return Err(format!("Expected 3-dimensional audio output, got {:?}", audio.0).into());
    }

    let batch = audio.0[0] as usize;

    let channels = audio.0[1] as usize;

    let samples = audio.0[2] as usize;

    if batch != 1 {
        return Err(format!("Expected batch=1, got {}", batch).into());
    }

    if audio.1.len() != channels * samples {
        return Err(format!(
            "Expected {} audio values, got {}",
            channels * samples,
            audio.1.len()
        )
        .into());
    }

    // ---------------------------------------------------------
    // Mean over channels
    // ---------------------------------------------------------

    let mut wav = vec![0.0f32; samples];

    for channel in 0..channels {
        let start = channel * samples;

        for sample in 0..samples {
            wav[sample] += audio.1[start + sample];
        }
    }

    let inv_channels = 1.0f32 / channels as f32;

    for sample in 0..samples {
        wav[sample] *= inv_channels;
    }

    println!("Waveform samples: {}", wav.len());

    println!("First 20 samples:");

    println!("{:?}", &wav[..wav.len().min(20)]);

    let audio_lengths = outputs[1].try_extract_tensor::<i32>()?;

    println!("audio_lengths shape: {:?}", audio_lengths.0);

    println!("audio_lengths: {:?}", audio_lengths.1);

    // ---------------------------------------------------------
    // Save raw PCM float32 for comparison
    // ---------------------------------------------------------

    save_f32("rust_codec_wav.f32", &wav)?;

    vieneu_core::wav::write_wav_mono_f32("rust_codec_test.wav", &wav, 48_000)?;

    println!("Saved WAV: rust_codec_test.wav");

    println!();
    println!("Saved: rust_codec_wav.f32");

    println!("Codec SUCCESS.");

    Ok(())
}
