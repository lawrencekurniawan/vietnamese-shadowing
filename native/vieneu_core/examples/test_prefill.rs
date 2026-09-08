use std::fs::File;
use std::io::Write;
use std::path::Path;

use ndarray::Array3;
use ort::value::TensorRef;
use ort::{
    ep,
    session::{Session, builder::GraphOptimizationLevel},
};

use vieneu_core::embeddings::VieNeuHeads;
use vieneu_core::prompt::{VieNeuPromptConfig, build_prompt};
use vieneu_core::tokenizer::VieNeuTokenizer;
use vieneu_core::voice::VieNeuVoiceStore;

fn preload_onnxruntime() -> Result<(), Box<dyn std::error::Error>> {
    let path = std::env::var("ORT_DYLIB_PATH")?;

    println!("Using ORT dylib:");
    println!("{path}");

    ort::util::preload_dylib(Path::new(&path))?;

    Ok(())
}

fn save_f32(path: &str, values: &[f32]) -> Result<(), Box<dyn std::error::Error>> {
    let mut file = File::create(path)?;

    for &value in values {
        file.write_all(&value.to_le_bytes())?;
    }

    Ok(())
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    preload_onnxruntime()?;
    let root = "/Users/lawrencewong/Movies/vietnamese_shadowing";

    let model_path = format!("{root}/assets/vieneu/model/vieneu_prefill.onnx");

    let tokenizer_path = format!("{root}/assets/vieneu/model/tokenizer.json");

    let heads_path = format!("{root}/assets/vieneu/model/vieneu_heads.json");

    let voices_path = format!("{root}/assets/vieneu/voices_v3_turbo.json");

    // ---------------------------------------------------------
    // Load tokenizer
    // ---------------------------------------------------------

    println!("Loading tokenizer...");

    let tokenizer = VieNeuTokenizer::from_file(&tokenizer_path)?;

    // ---------------------------------------------------------
    // Load embeddings / heads
    // ---------------------------------------------------------

    println!("Loading heads...");

    let heads = VieNeuHeads::from_json(&heads_path)?;

    // ---------------------------------------------------------
    // Load voice
    // ---------------------------------------------------------

    println!("Loading voices...");

    let voices = VieNeuVoiceStore::from_file(&voices_path)?;

    let voice = voices.get("Xuân Vĩnh")?;

    let speaker_emb = voice.speaker_emb.as_slice();

    // ---------------------------------------------------------
    // Tokenize known-good phonemes
    // ---------------------------------------------------------

    let phonemes = "hˈom nˈaj bˈaː6n xwˈɛ4 xˌoŋ?";

    let phone_ids = tokenizer.encode(phonemes)?;

    println!();
    println!("Phone IDs:");
    println!("{phone_ids:?}");

    // ---------------------------------------------------------
    // Build prompt
    // ---------------------------------------------------------

    let prompt = build_prompt(&phone_ids, &voice.codes, VieNeuPromptConfig::default())?;

    println!();
    println!("Prompt shape: ({}, {})", prompt.rows_count, prompt.columns);

    // ---------------------------------------------------------
    // Speaker anchor
    // ---------------------------------------------------------

    let (rust_projected, rust_projected_f64, rust_mean, rust_variance, rust_normalized, anchor) =
        heads.speaker_anchor_debug(&speaker_emb)?;

    save_f32("rust_anchor_projected_f64.f32", &rust_projected_f64)?;

    save_f32("rust_anchor_projected.f32", &rust_projected)?;

    save_f32("rust_anchor_mean.f32", &[rust_mean])?;

    save_f32("rust_anchor_var.f32", &[rust_variance])?;

    save_f32("rust_anchor_normalized.f32", &rust_normalized)?;

    save_f32("rust_anchor.f32", &anchor)?;

    save_f32("rust_speaker_emb.f32", &speaker_emb)?;

    save_f32("rust_xvec_w.f32", &heads.xvec_w)?;

    save_f32("rust_xvec_b.f32", &heads.xvec_b)?;

    println!("Anchor shape: ({})", anchor.len());

    // ---------------------------------------------------------
    // Build embeddings
    // ---------------------------------------------------------

    let embeddings = heads.embed_rows(&prompt, Some(&anchor))?;

    // ---------------------------------------------------------
    // Diagnostic: save embedding stages
    // ---------------------------------------------------------

    let mut rust_text_only = vec![0.0f32; prompt.rows_count * 768];

    let mut rust_text_audio = vec![0.0f32; prompt.rows_count * 768];

    let mut rust_full = vec![0.0f32; prompt.rows_count * 768];

    for row_index in 0..prompt.rows_count {
        let row = prompt.row(row_index).ok_or("Invalid prompt row")?;

        let text_id = usize::try_from(row[0]).map_err(|_| "Negative text token ID")?;

        let text_embedding = heads.text_embedding(text_id);

        let start = row_index * 768;

        // Stage 1: text only
        for h in 0..768 {
            rust_text_only[start + h] = text_embedding[h];
        }

        // Stage 2: text + audio
        for h in 0..768 {
            rust_text_audio[start + h] = text_embedding[h];
        }

        for ch in 0..16 {
            let code = row[ch + 1];

            if code == 1024 {
                continue;
            }

            let code = usize::try_from(code).map_err(|_| "Negative audio code")?;

            let audio = heads.audio_embedding(ch, code);

            for h in 0..768 {
                rust_text_audio[start + h] += audio[h];
            }
        }

        // Stage 3: text + audio + speaker anchor
        for h in 0..768 {
            rust_full[start + h] = rust_text_audio[start + h] + anchor[h];
        }
    }

    save_f32("rust_text_only.f32", &rust_text_only)?;

    save_f32("rust_text_audio.f32", &rust_text_audio)?;

    save_f32("rust_full.f32", &rust_full)?;

    let embedding_path = "/Users/lawrencewong/Movies/vietnamese_shadowing/native/vieneu_core/rust_prompt_embeddings.f32";

    let mut embedding_file = File::create(embedding_path)?;

    for value in embeddings.iter() {
        embedding_file.write_all(&value.to_le_bytes())?;
    }

    println!("Saved prompt embeddings: {embedding_path}");

    println!("Embedding values: {}", embeddings.len());

    let sequence_length = prompt.rows_count;

    if embeddings.len() != sequence_length * 768 {
        return Err(format!("Unexpected embedding length: {}", embeddings.len()).into());
    }

    let input = Array3::from_shape_vec((1, sequence_length, 768), embeddings)?;

    let input_path =
        "/Users/lawrencewong/Movies/vietnamese_shadowing/native/vieneu_core/rust_prefill_input.f32";

    let mut input_file = File::create(input_path)?;

    for value in input.iter() {
        input_file.write_all(&value.to_le_bytes())?;
    }

    println!("Saved input: {input_path}");

    // ---------------------------------------------------------
    // Load ONNX model
    // ---------------------------------------------------------

    println!();
    println!("Loading ONNX prefill...");

    let mut session = Session::builder()?
        .with_optimization_level(GraphOptimizationLevel::Disable)?
        .with_inter_threads(1)?
        .with_intra_threads(1)?
        .with_intra_op_spinning(false)?
        .with_execution_providers([ep::CPU::default().build()])?
        .commit_from_file(&model_path)?;

    println!("Session loaded.");

    // Capture the names before session.run().
    //
    // SessionOutputs borrows the session, so we must not
    // borrow session again while outputs is alive.
    let output_names: Vec<String> = session
        .outputs()
        .iter()
        .map(|output| output.name().to_string())
        .collect();

    // ---------------------------------------------------------
    // Run prefill
    // ---------------------------------------------------------

    println!();
    println!("Running prefill...");

    let outputs = session.run(ort::inputs![
        "inputs_embeds" =>
            TensorRef::from_array_view(&input)?
    ])?;

    println!("Number of outputs: {}", outputs.len());

    // ---------------------------------------------------------
    // Inspect output tensors
    // ---------------------------------------------------------

    for (index, (name, output)) in outputs.iter().enumerate() {
        let (shape, data) = output.try_extract_tensor::<f32>()?;

        println!(
            "output[{index:02}] {name}: \
            shape={shape:?}, values={}",
            data.len()
        );

        println!("  first 5: {:?}", &data[..data.len().min(5)]);

        let filename = format!("rust_prefill_{index:02}.f32");

        let mut file = File::create(&filename)?;

        for value in data {
            file.write_all(&value.to_le_bytes())?;
        }

        println!("  saved: {filename}");
    }

    println!();
    println!("Prefill SUCCESS.");

    Ok(())
}
