use std::fs;
use std::io::Write;
use std::path::Path;

use ndarray::{Array2, Array3, Array4};
use ort::{
    ep,
    session::{Session, builder::GraphOptimizationLevel},
    value::TensorRef,
};

use vieneu_core::embeddings::VieNeuHeads;

const HIDDEN: usize = 768;
const N_VQ: usize = 16;
const N_HEADS: usize = 8;
const HEAD_DIM: usize = 96;

const SGS: i64 = 5;
const EOS: usize = 6;

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

fn save_f32(path: &str, values: &[f32]) -> Result<(), Box<dyn std::error::Error>> {
    let mut file = fs::File::create(path)?;

    for &value in values {
        file.write_all(&value.to_le_bytes())?;
    }

    Ok(())
}

fn argmax(values: &[f32]) -> usize {
    let mut best_index = 0usize;
    let mut best_value = f32::NEG_INFINITY;

    for (index, &value) in values.iter().enumerate() {
        if value > best_value {
            best_value = value;
            best_index = index;
        }
    }

    best_index
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    preload_onnxruntime()?;

    let root = "/Users/lawrencewong/Movies/vietnamese_shadowing";

    let acoustic_model = format!("{root}/assets/vieneu/model/vieneu_acoustic_cached.onnx");

    let heads_path = format!("{root}/assets/vieneu/model/vieneu_heads.json");

    println!("Loading heads...");

    let heads = VieNeuHeads::from_json(&heads_path)?;

    println!("Loading decoder hidden...");

    let cond = read_f32_file("rust_decode_00.f32")?;

    if cond.len() != HIDDEN {
        return Err(format!("Expected {} hidden values, got {}", HIDDEN, cond.len()).into());
    }

    println!("Conditioning hidden: {} values", cond.len());

    let sgs_embedding = heads.text_embedding(SGS as usize).to_vec();

    if sgs_embedding.len() != HIDDEN {
        return Err(format!(
            "Expected SGS embedding of length {}, got {}",
            HIDDEN,
            sgs_embedding.len()
        )
        .into());
    }

    // ---------------------------------------------------------
    // First acoustic call
    // ---------------------------------------------------------

    let mut first_tokens = Vec::with_capacity(2 * HIDDEN);

    first_tokens.extend_from_slice(&cond);
    first_tokens.extend_from_slice(&sgs_embedding);

    let first_input = Array3::from_shape_vec((1, 2, HIDDEN), first_tokens)?;

    let first_positions = Array2::from_shape_vec((1, 2), vec![0i64, 1i64])?;

    let empty_k = Array4::<f32>::zeros((1, N_HEADS, 0, HEAD_DIM));

    let empty_v = Array4::<f32>::zeros((1, N_HEADS, 0, HEAD_DIM));

    println!("Loading acoustic model...");

    let mut session = Session::builder()?
        .with_optimization_level(GraphOptimizationLevel::Disable)?
        .with_inter_threads(1)?
        .with_intra_threads(1)?
        .with_intra_op_spinning(false)?
        .with_execution_providers([ep::CPU::default().build()])?
        .commit_from_file(&acoustic_model)?;

    println!("Acoustic model loaded.");

    println!();
    println!("Acoustic step 0...");

    // ---------------------------------------------------------
    // IMPORTANT:
    //
    // Everything extracted from `outputs` is copied out here.
    // The SessionOutputs is then dropped before we call
    // session.run() again.
    // ---------------------------------------------------------

    let (slot0, channel0_hidden, mut past_k, mut past_v) = {
        let outputs = session.run(ort::inputs![
            "token_emb" =>
                TensorRef::from_array_view(
                    &first_input
                )?,

            "position_ids" =>
                TensorRef::from_array_view(
                    &first_positions
                )?,

            "past_k_0" =>
                TensorRef::from_array_view(
                    &empty_k
                )?,

            "past_v_0" =>
                TensorRef::from_array_view(
                    &empty_v
                )?,
        ])?;

        if outputs.len() != 3 {
            return Err(format!("Expected 3 acoustic outputs, got {}", outputs.len()).into());
        }

        let hidden = outputs[0].try_extract_tensor::<f32>()?;

        if hidden.1.len() != 2 * HIDDEN {
            return Err(format!(
                "Expected {} hidden values, got {}",
                2 * HIDDEN,
                hidden.1.len()
            )
            .into());
        }

        println!("hidden shape: {:?}", hidden.0);

        println!("hidden first 10: {:?}", &hidden.1[..10]);

        save_f32("rust_acoustic_step0_hidden.f32", hidden.1)?;

        let slot0 = hidden.1[..HIDDEN].to_vec();

        let channel0_hidden = hidden.1[HIDDEN..2 * HIDDEN].to_vec();

        let k = outputs[1].try_extract_tensor::<f32>()?;

        let v = outputs[2].try_extract_tensor::<f32>()?;

        println!("present_k shape: {:?}", k.0);

        println!("present_v shape: {:?}", v.0);

        save_f32("rust_acoustic_step0_k.f32", k.1)?;

        save_f32("rust_acoustic_step0_v.f32", v.1)?;

        let past_k = Array4::from_shape_vec((1, N_HEADS, 2, HEAD_DIM), k.1.to_vec())?;

        let past_v = Array4::from_shape_vec((1, N_HEADS, 2, HEAD_DIM), v.1.to_vec())?;

        (slot0, channel0_hidden, past_k, past_v)
    };

    // ---------------------------------------------------------
    // Code 0
    // ---------------------------------------------------------

    let audio_vocab = heads.audio_vocab;

    let mut code0_logits = vec![0.0f32; audio_vocab];

    for code in 0..audio_vocab {
        let embedding = heads.audio_embedding(0, code);

        let mut sum = 0.0f32;

        for h in 0..HIDDEN {
            sum += channel0_hidden[h] * embedding[h];
        }

        code0_logits[code] = sum;
    }

    let code0 = argmax(&code0_logits);

    let mut codes = Vec::with_capacity(N_VQ);

    codes.push(code0);

    println!("code[0] = {}", code0);

    save_f32("rust_acoustic_code0_logits.f32", &code0_logits)?;

    // ---------------------------------------------------------
    // EOS check
    // ---------------------------------------------------------

    let text_vocab = heads.text_vocab;

    let mut text_logits = vec![0.0f32; text_vocab];

    for token in 0..text_vocab {
        let embedding = heads.text_embedding(token);

        let mut sum = 0.0f32;

        for h in 0..HIDDEN {
            sum += slot0[h] * embedding[h];
        }

        text_logits[token] = sum;
    }

    let eos_argmax = argmax(&text_logits);

    println!("EOS argmax token = {}", eos_argmax);

    println!("Expected EOS token = {}", EOS);

    save_f32("rust_acoustic_text_logits.f32", &text_logits)?;

    // ---------------------------------------------------------
    // Channels 1..15
    // ---------------------------------------------------------

    for ch in 1..N_VQ {
        let previous_code = codes[ch - 1];

        println!();
        println!(
            "Acoustic channel {} (previous code = {})...",
            ch, previous_code
        );

        let input_embedding = heads.audio_embedding(ch - 1, previous_code);

        let next_input = Array3::from_shape_vec((1, 1, HIDDEN), input_embedding.to_vec())?;

        let next_position = Array2::from_shape_vec((1, 1), vec![(ch + 1) as i64])?;

        // -----------------------------------------------------
        // Put the entire ONNX call inside a scope.
        //
        // This guarantees `outputs` is dropped before the
        // next loop iteration calls session.run().
        // -----------------------------------------------------

        let (hidden_values, new_k, new_v) = {
            let outputs = session.run(ort::inputs![
                "token_emb" =>
                    TensorRef::from_array_view(
                        &next_input
                    )?,

                "position_ids" =>
                    TensorRef::from_array_view(
                        &next_position
                    )?,

                "past_k_0" =>
                    TensorRef::from_array_view(
                        &past_k
                    )?,

                "past_v_0" =>
                    TensorRef::from_array_view(
                        &past_v
                    )?,
            ])?;

            if outputs.len() != 3 {
                return Err(
                    format!("Channel {}: expected 3 outputs, got {}", ch, outputs.len()).into(),
                );
            }

            let hidden = outputs[0].try_extract_tensor::<f32>()?;

            if hidden.1.len() != HIDDEN {
                return Err(format!(
                    "Channel {}: expected {} hidden values, got {}",
                    ch,
                    HIDDEN,
                    hidden.1.len()
                )
                .into());
            }

            let k = outputs[1].try_extract_tensor::<f32>()?;

            let v = outputs[2].try_extract_tensor::<f32>()?;

            (hidden.1.to_vec(), k.1.to_vec(), v.1.to_vec())
        };

        println!("hidden first 5: {:?}", &hidden_values[..5]);

        // -----------------------------------------------------
        // Update cache
        // -----------------------------------------------------

        let new_cache_length = ch + 2;

        let expected_cache_values = N_HEADS * new_cache_length * HEAD_DIM;

        if new_k.len() != expected_cache_values {
            return Err(format!(
                "Channel {} K cache has {} values, expected {}",
                ch,
                new_k.len(),
                expected_cache_values
            )
            .into());
        }

        if new_v.len() != expected_cache_values {
            return Err(format!(
                "Channel {} V cache has {} values, expected {}",
                ch,
                new_v.len(),
                expected_cache_values
            )
            .into());
        }

        past_k = Array4::from_shape_vec((1, N_HEADS, new_cache_length, HEAD_DIM), new_k.clone())?;

        past_v = Array4::from_shape_vec((1, N_HEADS, new_cache_length, HEAD_DIM), new_v.clone())?;

        // -----------------------------------------------------
        // Predict code for this channel
        // -----------------------------------------------------

        let mut logits = vec![0.0f32; audio_vocab];

        for code in 0..audio_vocab {
            let embedding = heads.audio_embedding(ch, code);

            let mut sum = 0.0f32;

            for h in 0..HIDDEN {
                sum += hidden_values[h] * embedding[h];
            }

            logits[code] = sum;
        }

        let code = argmax(&logits);

        codes.push(code);

        println!("code[{}] = {}", ch, code);

        save_f32(&format!("rust_acoustic_code{}_logits.f32", ch), &logits)?;

        save_f32(
            &format!("rust_acoustic_step{}_hidden.f32", ch),
            &hidden_values,
        )?;

        save_f32(&format!("rust_acoustic_step{}_k.f32", ch), &new_k)?;

        save_f32(&format!("rust_acoustic_step{}_v.f32", ch), &new_v)?;

        println!("cache length after channel {}: {}", ch, new_cache_length);
    }

    println!();
    println!("Codes:");
    println!("{codes:?}");

    println!();

    if eos_argmax == EOS {
        println!("EOS detected: yes");
    } else {
        println!("EOS detected: no");
    }

    println!();
    println!("Acoustic SUCCESS.");

    Ok(())
}
