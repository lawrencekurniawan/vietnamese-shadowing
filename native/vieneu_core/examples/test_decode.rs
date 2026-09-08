use std::fs;
use std::path::Path;

use ndarray::{Array2, Array3, Array4};
use ort::{
    ep,
    session::{Session, builder::GraphOptimizationLevel},
    value::TensorRef,
};

use vieneu_core::embeddings::VieNeuHeads;
use vieneu_core::prompt::{VieNeuPromptConfig, build_prompt};
use vieneu_core::tokenizer::VieNeuTokenizer;
use vieneu_core::voice::VieNeuVoiceStore;

const N_LAYERS: usize = 12;
const N_VQ: usize = 16;
const HIDDEN: usize = 768;

fn preload_onnxruntime() -> Result<(), Box<dyn std::error::Error>> {
    let path = std::env::var("ORT_DYLIB_PATH")?;

    println!("Using ORT dylib:");
    println!("{path}");

    ort::util::preload_dylib(Path::new(&path))?;

    Ok(())
}

fn read_f32_file(path: &str) -> Result<Vec<f32>, Box<dyn std::error::Error>> {
    let bytes = fs::read(path)?;

    if bytes.len() % 4 != 0 {
        return Err(format!("{} has {} bytes, not divisible by 4", path, bytes.len()).into());
    }

    let mut values = Vec::with_capacity(bytes.len() / 4);

    for chunk in bytes.chunks_exact(4) {
        values.push(f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]));
    }

    Ok(values)
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    preload_onnxruntime()?;

    let root = "/Users/lawrencewong/Movies/vietnamese_shadowing";

    let model_path = format!("{root}/assets/vieneu/model/vieneu_decode_step.onnx");

    let tokenizer_path = format!("{root}/assets/vieneu/model/tokenizer.json");

    let heads_path = format!("{root}/assets/vieneu/model/vieneu_heads.json");

    let voices_path = format!("{root}/assets/vieneu/voices_v3_turbo.json");

    // ---------------------------------------------------------
    // Load model data
    // ---------------------------------------------------------

    println!("Loading tokenizer...");

    let tokenizer = VieNeuTokenizer::from_file(&tokenizer_path)?;

    println!("Loading heads...");

    let heads = VieNeuHeads::from_json(&heads_path)?;

    println!("Loading voices...");

    let voices = VieNeuVoiceStore::from_file(&voices_path)?;

    let voice = voices.get("Xuân Vĩnh")?;

    // ---------------------------------------------------------
    // Build exactly the same prefill prompt
    // ---------------------------------------------------------

    let phonemes = "hˈom nˈaj bˈaː6n xwˈɛ4 xˌoŋ?";

    let phone_ids = tokenizer.encode(phonemes)?;

    let prompt = build_prompt(&phone_ids, &voice.codes, VieNeuPromptConfig::default())?;

    let prompt_length = prompt.rows_count;

    println!("Prompt length: {}", prompt_length);

    // ---------------------------------------------------------
    // Speaker anchor
    // ---------------------------------------------------------

    let anchor = heads.speaker_anchor(&voice.speaker_emb)?;

    // ---------------------------------------------------------
    // Rebuild prompt embeddings
    // ---------------------------------------------------------

    let prompt_embeddings = heads.embed_rows(&prompt, Some(&anchor))?;

    let prompt_input =
        ndarray::Array3::from_shape_vec((1, prompt_length, HIDDEN), prompt_embeddings)?;

    // ---------------------------------------------------------
    // Load prefill KV cache
    // ---------------------------------------------------------

    println!("Loading prefill KV cache...");

    let kv_values = 1 * 4 * prompt_length * 64;

    let mut past_k: Vec<Array4<f32>> = Vec::with_capacity(N_LAYERS);

    let mut past_v: Vec<Array4<f32>> = Vec::with_capacity(N_LAYERS);

    for i in 0..N_LAYERS {
        let filename = format!("rust_prefill_{:02}.f32", 1 + i);

        let values = read_f32_file(&filename)?;

        if values.len() != kv_values {
            return Err(format!(
                "{}: expected {} values, got {}",
                filename,
                kv_values,
                values.len()
            )
            .into());
        }

        past_k.push(Array4::from_shape_vec((1, 4, prompt_length, 64), values)?);
    }

    for i in 0..N_LAYERS {
        let filename = format!("rust_prefill_{:02}.f32", 13 + i);

        let values = read_f32_file(&filename)?;

        if values.len() != kv_values {
            return Err(format!(
                "{}: expected {} values, got {}",
                filename,
                kv_values,
                values.len()
            )
            .into());
        }

        past_v.push(Array4::from_shape_vec((1, 4, prompt_length, 64), values)?);
    }

    println!(
        "Loaded {} K tensors and {} V tensors.",
        past_k.len(),
        past_v.len()
    );

    // ---------------------------------------------------------
    // Deterministic first decode frame
    //
    // Reference engine feeds:
    //
    //   [SGS, code_0, ..., code_15]
    //
    // after the acoustic frame has been generated.
    //
    // We don't have sampling yet, so use the first reference
    // frame as a deterministic test input.
    // ---------------------------------------------------------

    if voice.codes.is_empty() {
        return Err("Voice has no reference frames".into());
    }

    let codes = &voice.codes[0];

    if codes.len() != N_VQ {
        return Err(format!("Expected {} codes, got {}", N_VQ, codes.len()).into());
    }

    let sgs = {
        let config_path = format!("{root}/assets/vieneu/model/config.json");

        let config_text = std::fs::read_to_string(config_path)?;

        let config_json: serde_json::Value = serde_json::from_str(&config_text)?;

        config_json["speech_generation_start_token_id"]
            .as_i64()
            .ok_or("Missing speech_generation_start_token_id")?
    };

    println!("SGS token: {sgs}");

    let mut frame_rows = vec![vec![VieNeuPromptConfig::default().audio_pad; N_VQ + 1]];

    frame_rows[0][0] = sgs;

    for ch in 0..N_VQ {
        frame_rows[0][ch + 1] = codes[ch];
    }

    let frame_prompt = vieneu_core::prompt::VieNeuPrompt {
        rows: frame_rows.into_iter().flatten().collect(),
        rows_count: 1,
        columns: N_VQ + 1,
    };

    let frame_embeddings = heads.embed_rows(&frame_prompt, Some(&anchor))?;

    let frame_input = Array3::from_shape_vec((1, 1, HIDDEN), frame_embeddings)?;

    let frame_input_path = "rust_decode_input.f32";

    let mut frame_file = fs::File::create(frame_input_path)?;

    for &value in frame_input.iter() {
        use std::io::Write;

        frame_file.write_all(&value.to_le_bytes())?;
    }

    println!("Saved decode input: {frame_input_path}");

    println!("Decode embedding shape: {:?}", frame_input.shape());

    // ---------------------------------------------------------
    // Position
    //
    // First generated frame:
    //
    // position = prompt length
    // ---------------------------------------------------------

    let position_ids = Array2::from_shape_vec((1, 1), vec![prompt_length as i64])?;

    // ---------------------------------------------------------
    // Load decoder
    // ---------------------------------------------------------

    println!();
    println!("Loading decode model...");

    let mut session = Session::builder()?
        .with_optimization_level(GraphOptimizationLevel::Disable)?
        .with_inter_threads(1)?
        .with_intra_threads(1)?
        .with_intra_op_spinning(false)?
        .with_execution_providers([ep::CPU::default().build()])?
        .commit_from_file(&model_path)?;

    println!("Decoder loaded.");

    // ---------------------------------------------------------
    // Build decoder inputs
    //
    // We already know inputs_embeds and position_ids work with
    // TensorRef::from_array_view().
    //
    // For the dynamic KV names, start with the inputs! macro
    // plus direct inserts using the exact SessionInputs API
    // exposed by ort 2.0.0-rc.12.
    // ---------------------------------------------------------

    let mut inputs = ort::inputs![
        "inputs_embeds" =>
            TensorRef::from_array_view(&frame_input)?,

        "position_ids" =>
            TensorRef::from_array_view(&position_ids)?,
    ];

    for i in 0..N_LAYERS {
        inputs.push((
            format!("past_k_{i}").into(),
            TensorRef::from_array_view(&past_k[i])?.into(),
        ));

        inputs.push((
            format!("past_v_{i}").into(),
            TensorRef::from_array_view(&past_v[i])?.into(),
        ));
    }

    println!();
    println!("Running decoder...");

    let outputs = session.run(inputs)?;

    println!("Number of outputs: {}", outputs.len());

    // ---------------------------------------------------------
    // Dump outputs
    // ---------------------------------------------------------

    for (index, (name, output)) in outputs.iter().enumerate() {
        let (shape, data) = output.try_extract_tensor::<f32>()?;

        println!(
            "output[{index:02}] {name}: \
             shape={shape:?}, values={}",
            data.len()
        );

        println!("  first 5: {:?}", &data[..data.len().min(5)]);

        let filename = format!("rust_decode_{index:02}.f32");

        let mut file = fs::File::create(&filename)?;

        for &value in data {
            use std::io::Write;

            file.write_all(&value.to_le_bytes())?;
        }
    }

    println!();
    println!("Decode SUCCESS.");

    Ok(())
}
