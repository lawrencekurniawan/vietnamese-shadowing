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
use vieneu_core::prompt::{VieNeuPromptConfig, build_prompt};
use vieneu_core::tokenizer::VieNeuTokenizer;
use vieneu_core::voice::VieNeuVoiceStore;

const HIDDEN: usize = 768;
const N_VQ: usize = 16;
const BACKBONE_LAYERS: usize = 12;

const ACOUSTIC_HEADS: usize = 8;
const ACOUSTIC_HEAD_DIM: usize = 96;

const SGS: i64 = 5;
const EOS: usize = 6;

const NUM_FRAMES: usize = 3;

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

fn save_i64(path: &str, values: &[i64]) -> Result<(), Box<dyn std::error::Error>> {
    let mut file = fs::File::create(path)?;

    for &value in values {
        file.write_all(&value.to_le_bytes())?;
    }

    Ok(())
}

fn dot(a: &[f32], b: &[f32]) -> f32 {
    debug_assert_eq!(a.len(), b.len());

    let mut sum = 0.0f32;

    for i in 0..a.len() {
        sum += a[i] * b[i];
    }

    sum
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

fn build_generation_embedding(
    heads: &VieNeuHeads,
    codes: &[usize],
    anchor: &[f32],
) -> (Vec<f32>, Vec<f32>, Vec<f32>) {
    let text = heads.text_embedding(SGS as usize);

    let mut text_audio = text.to_vec();

    for ch in 0..N_VQ {
        let audio = heads.audio_embedding(ch, codes[ch]);

        for h in 0..HIDDEN {
            text_audio[h] += audio[h];
        }
    }

    let mut full = text_audio.clone();

    for h in 0..HIDDEN {
        full[h] += anchor[h];
    }

    (text.to_vec(), text_audio, full)
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    preload_onnxruntime()?;

    let root = "/Users/lawrencewong/Movies/vietnamese_shadowing";

    let prefill_model = format!("{root}/assets/vieneu/model/vieneu_prefill.onnx");

    let decode_model = format!("{root}/assets/vieneu/model/vieneu_decode_step.onnx");

    let acoustic_model = format!("{root}/assets/vieneu/model/vieneu_acoustic_cached.onnx");

    let tokenizer_path = format!("{root}/assets/vieneu/model/tokenizer.json");

    let heads_path = format!("{root}/assets/vieneu/model/vieneu_heads.json");

    let voices_path = format!("{root}/assets/vieneu/voices_v3_turbo.json");

    // =========================================================
    // Load tokenizer / heads / voice
    // =========================================================

    println!("Loading tokenizer...");

    let tokenizer = VieNeuTokenizer::from_file(&tokenizer_path)?;

    println!("Loading heads...");

    let heads = VieNeuHeads::from_json(&heads_path)?;

    println!("Loading voices...");

    let voices = VieNeuVoiceStore::from_file(&voices_path)?;

    let voice = voices.get("Xuân Vĩnh")?;

    // =========================================================
    // Build prompt
    // =========================================================

    let phonemes = "hˈom nˈaj bˈaː6n xwˈɛ4 xˌoŋ?";

    let phone_ids = tokenizer.encode(phonemes)?;

    let prompt = build_prompt(&phone_ids, &voice.codes, VieNeuPromptConfig::default())?;

    let prompt_length = prompt.rows_count;

    println!("Prompt length: {}", prompt_length);

    // =========================================================
    // Speaker anchor
    // =========================================================

    let anchor = {
        let path = "/Users/lawrencewong/Movies/vietnamese_shadowing/tools/vieneu-reference/direct_generation/python_generation_anchor.f32";

        let bytes = std::fs::read(path)?;

        if bytes.len() != 768 * 4 {
            return Err(format!(
                "Expected Python anchor to contain {} bytes, got {}",
                768 * 4,
                bytes.len()
            )
            .into());
        }

        let mut values = Vec::with_capacity(768);

        for chunk in bytes.chunks_exact(4) {
            values.push(f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]));
        }

        values
    };

    save_f32("rust_generation_anchor.f32", &anchor)?;

    // =========================================================
    // Prompt embeddings
    // =========================================================

    let prompt_embeddings = heads.embed_rows(&prompt, Some(&anchor))?;

    let prompt_input = Array3::from_shape_vec((1, prompt_length, HIDDEN), prompt_embeddings)?;

    // =========================================================
    // Load sessions
    // =========================================================

    println!();
    println!("Loading prefill model...");

    let mut prefill = Session::builder()?
        .with_optimization_level(GraphOptimizationLevel::Disable)?
        .with_inter_threads(1)?
        .with_intra_threads(1)?
        .with_intra_op_spinning(false)?
        .with_execution_providers([ep::CPU::default().build()])?
        .commit_from_file(&prefill_model)?;

    println!("Loading backbone decode model...");

    let mut backbone = Session::builder()?
        .with_optimization_level(GraphOptimizationLevel::Disable)?
        .with_inter_threads(1)?
        .with_intra_threads(1)?
        .with_intra_op_spinning(false)?
        .with_execution_providers([ep::CPU::default().build()])?
        .commit_from_file(&decode_model)?;

    println!("Loading acoustic model...");

    let mut acoustic = Session::builder()?
        .with_optimization_level(GraphOptimizationLevel::Disable)?
        .with_inter_threads(1)?
        .with_intra_threads(1)?
        .with_intra_op_spinning(false)?
        .with_execution_providers([ep::CPU::default().build()])?
        .commit_from_file(&acoustic_model)?;

    // =========================================================
    // Prefill
    // =========================================================

    println!();
    println!("Running prefill...");

    let (mut backbone_k, mut backbone_v, mut h) = {
        let outputs = prefill.run(ort::inputs![
            "inputs_embeds" =>
                TensorRef::from_array_view(
                    &prompt_input
                )?,
        ])?;

        if outputs.len() != 25 {
            return Err(format!("Expected 25 prefill outputs, got {}", outputs.len()).into());
        }

        let hidden = outputs[0].try_extract_tensor::<f32>()?;

        let start = (prompt_length - 1) * HIDDEN;

        let h = hidden.1[start..start + HIDDEN].to_vec();

        save_f32("rust_generation_prefill_hidden.f32", &h)?;

        let mut k = Vec::with_capacity(BACKBONE_LAYERS);

        let mut v = Vec::with_capacity(BACKBONE_LAYERS);

        let kv_values = 4 * prompt_length * 64;

        for i in 0..BACKBONE_LAYERS {
            let value = outputs[1 + i].try_extract_tensor::<f32>()?;

            k.push(Array4::from_shape_vec(
                (1, 4, prompt_length, 64),
                value.1.to_vec(),
            )?);
        }

        for i in 0..BACKBONE_LAYERS {
            let value = outputs[13 + i].try_extract_tensor::<f32>()?;

            v.push(Array4::from_shape_vec(
                (1, 4, prompt_length, 64),
                value.1.to_vec(),
            )?);
        }

        debug_assert_eq!(k[0].len(), kv_values);

        debug_assert_eq!(v[0].len(), kv_values);

        (k, v, h)
    };

    println!("Prefill complete. Hidden = {} values.", h.len());

    // =========================================================
    // Generate frames
    // =========================================================

    let mut all_frames = Vec::<Vec<usize>>::new();

    for frame_index in 0..NUM_FRAMES {
        println!();
        println!("=================================================");
        println!("FRAME {}", frame_index);
        println!("=================================================");

        // -----------------------------------------------------
        // Acoustic frame
        // -----------------------------------------------------

        let (codes, eos) = {
            let sgs_embedding = heads.text_embedding(SGS as usize);

            let mut tokens = Vec::with_capacity(2 * HIDDEN);

            tokens.extend_from_slice(&h);

            tokens.extend_from_slice(sgs_embedding);

            let acoustic_input = Array3::from_shape_vec((1, 2, HIDDEN), tokens)?;

            let acoustic_positions = Array2::from_shape_vec((1, 2), vec![0i64, 1i64])?;

            let empty_k = Array4::<f32>::zeros((1, ACOUSTIC_HEADS, 0, ACOUSTIC_HEAD_DIM));

            let empty_v = Array4::<f32>::zeros((1, ACOUSTIC_HEADS, 0, ACOUSTIC_HEAD_DIM));

            // -------------------------------------------------
            // Acoustic step 0
            // -------------------------------------------------

            let (mut acoustic_k, mut acoustic_v, slot0, code0) = {
                let outputs = acoustic.run(ort::inputs![
                    "token_emb" =>
                        TensorRef::from_array_view(
                            &acoustic_input
                        )?,

                    "position_ids" =>
                        TensorRef::from_array_view(
                            &acoustic_positions
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

                let hidden = outputs[0].try_extract_tensor::<f32>()?;

                if hidden.1.len() != 2 * HIDDEN {
                    return Err(format!(
                        "Unexpected acoustic step-0 hidden length: {}",
                        hidden.1.len()
                    )
                    .into());
                }

                save_f32(
                    &format!(
                        "rust_generation_frame{}_acoustic_ch00_hidden.f32",
                        frame_index
                    ),
                    hidden.1,
                )?;

                let k = outputs[1].try_extract_tensor::<f32>()?;

                let v = outputs[2].try_extract_tensor::<f32>()?;

                let acoustic_k = Array4::from_shape_vec(
                    (1, ACOUSTIC_HEADS, 2, ACOUSTIC_HEAD_DIM),
                    k.1.to_vec(),
                )?;

                let acoustic_v = Array4::from_shape_vec(
                    (1, ACOUSTIC_HEADS, 2, ACOUSTIC_HEAD_DIM),
                    v.1.to_vec(),
                )?;

                let slot0 = hidden.1[0..HIDDEN].to_vec();

                let channel_hidden = &hidden.1[HIDDEN..2 * HIDDEN];

                let mut logits = vec![0.0f32; heads.audio_vocab];

                for code in 0..heads.audio_vocab {
                    logits[code] = dot(channel_hidden, heads.audio_embedding(0, code));
                }

                let code0 = argmax(&logits);

                save_f32(
                    &format!(
                        "rust_generation_frame{}_acoustic_ch00_logits.f32",
                        frame_index
                    ),
                    &logits,
                )?;

                (acoustic_k, acoustic_v, slot0, code0)
            };

            let mut codes = Vec::with_capacity(N_VQ);

            codes.push(code0);

            // -------------------------------------------------
            // Acoustic channels 1..15
            // -------------------------------------------------

            for ch in 1..N_VQ {
                let previous_code = codes[ch - 1];

                let input_embedding = heads.audio_embedding(ch - 1, previous_code);

                let input = Array3::from_shape_vec((1, 1, HIDDEN), input_embedding.to_vec())?;

                let positions = Array2::from_shape_vec((1, 1), vec![(ch + 1) as i64])?;

                let (hidden_values, next_k, next_v) = {
                    let outputs = acoustic.run(ort::inputs![
                        "token_emb" =>
                            TensorRef::from_array_view(
                                &input
                            )?,

                        "position_ids" =>
                            TensorRef::from_array_view(
                                &positions
                            )?,

                        "past_k_0" =>
                            TensorRef::from_array_view(
                                &acoustic_k
                            )?,

                        "past_v_0" =>
                            TensorRef::from_array_view(
                                &acoustic_v
                            )?,
                    ])?;

                    let hidden = outputs[0].try_extract_tensor::<f32>()?;

                    let k = outputs[1].try_extract_tensor::<f32>()?;

                    let v = outputs[2].try_extract_tensor::<f32>()?;

                    (hidden.1.to_vec(), k.1.to_vec(), v.1.to_vec())
                };

                let expected_hidden = HIDDEN;

                if hidden_values.len() != expected_hidden {
                    return Err(format!(
                        "Frame {} channel {} hidden: expected {}, got {}",
                        frame_index,
                        ch,
                        expected_hidden,
                        hidden_values.len()
                    )
                    .into());
                }

                save_f32(
                    &format!(
                        "rust_generation_frame{}_acoustic_ch{:02}_hidden.f32",
                        frame_index, ch
                    ),
                    &hidden_values,
                )?;

                let new_cache_length = ch + 2;

                acoustic_k = Array4::from_shape_vec(
                    (1, ACOUSTIC_HEADS, new_cache_length, ACOUSTIC_HEAD_DIM),
                    next_k,
                )?;

                acoustic_v = Array4::from_shape_vec(
                    (1, ACOUSTIC_HEADS, new_cache_length, ACOUSTIC_HEAD_DIM),
                    next_v,
                )?;

                let mut logits = vec![0.0f32; heads.audio_vocab];

                for code in 0..heads.audio_vocab {
                    logits[code] = dot(&hidden_values, heads.audio_embedding(ch, code));
                }

                let code = argmax(&logits);

                save_f32(
                    &format!(
                        "rust_generation_frame{}_acoustic_ch{:02}_logits.f32",
                        frame_index, ch
                    ),
                    &logits,
                )?;

                codes.push(code);
            }

            // -------------------------------------------------
            // EOS
            // -------------------------------------------------

            let mut text_logits = vec![0.0f32; heads.text_vocab];

            for token in 0..heads.text_vocab {
                text_logits[token] = dot(&slot0, heads.text_embedding(token));
            }

            let eos_token = argmax(&text_logits);

            save_f32(
                &format!(
                    "rust_generation_frame{}_acoustic_text_logits.f32",
                    frame_index
                ),
                &text_logits,
            )?;

            (codes, eos_token == EOS)
        };

        println!("Generated codes:");

        println!("{codes:?}");

        println!("EOS: {}", eos);

        let code_values: Vec<i64> = codes.iter().map(|&x| x as i64).collect();

        save_i64(
            &format!("rust_generation_frame{}_codes.i64", frame_index),
            &code_values,
        )?;

        all_frames.push(codes.clone());

        if eos {
            break;
        }

        // -----------------------------------------------------
        // Build next backbone embedding
        // -----------------------------------------------------

        let (text_component, text_audio_component, full_embedding) =
            build_generation_embedding(&heads, &codes, &anchor);

        save_f32(
            &format!("rust_generation_frame{}_text.f32", frame_index),
            &text_component,
        )?;

        save_f32(
            &format!("rust_generation_frame{}_text_audio.f32", frame_index),
            &text_audio_component,
        )?;

        save_f32(
            &format!("rust_generation_frame{}_anchor.f32", frame_index),
            &anchor,
        )?;

        save_f32(
            &format!("rust_generation_frame{}_backbone_input.f32", frame_index),
            &full_embedding,
        )?;

        // Save each individual audio embedding too.
        for ch in 0..N_VQ {
            save_f32(
                &format!(
                    "rust_generation_frame{}_audio_emb_{:02}.f32",
                    frame_index, ch
                ),
                heads.audio_embedding(ch, codes[ch]),
            )?;
        }

        let next_input = Array3::from_shape_vec((1, 1, HIDDEN), full_embedding)?;

        let next_position =
            Array2::from_shape_vec((1, 1), vec![(prompt_length + frame_index) as i64])?;

        println!("Running backbone decode...");

        let (next_h, next_k, next_v) = {
            let mut inputs = ort::inputs![
                "inputs_embeds" =>
                    TensorRef::from_array_view(
                        &next_input
                    )?,

                "position_ids" =>
                    TensorRef::from_array_view(
                        &next_position
                    )?,
            ];

            for i in 0..BACKBONE_LAYERS {
                inputs.push((
                    format!("past_k_{i}").into(),
                    TensorRef::from_array_view(&backbone_k[i])?.into(),
                ));

                inputs.push((
                    format!("past_v_{i}").into(),
                    TensorRef::from_array_view(&backbone_v[i])?.into(),
                ));
            }

            let outputs = backbone.run(inputs)?;

            if outputs.len() != 25 {
                return Err(format!("Expected 25 backbone outputs, got {}", outputs.len()).into());
            }

            let hidden = outputs[0].try_extract_tensor::<f32>()?;

            let next_h = hidden.1.to_vec();

            save_f32(
                &format!(
                    "rust_generation_frame{}_backbone_hidden.f32",
                    frame_index + 1
                ),
                &next_h,
            )?;

            let new_length = prompt_length + frame_index + 1;

            let mut next_k = Vec::with_capacity(BACKBONE_LAYERS);

            let mut next_v = Vec::with_capacity(BACKBONE_LAYERS);

            for i in 0..BACKBONE_LAYERS {
                let value = outputs[1 + i].try_extract_tensor::<f32>()?;

                next_k.push(Array4::from_shape_vec(
                    (1, 4, new_length, 64),
                    value.1.to_vec(),
                )?);
            }

            for i in 0..BACKBONE_LAYERS {
                let value = outputs[13 + i].try_extract_tensor::<f32>()?;

                next_v.push(Array4::from_shape_vec(
                    (1, 4, new_length, 64),
                    value.1.to_vec(),
                )?);
            }

            (next_h, next_k, next_v)
        };

        h = next_h;

        backbone_k = next_k;

        backbone_v = next_v;

        println!("Backbone cache length: {}", prompt_length + frame_index + 1);
    }

    println!();
    println!("=================================================");
    println!("GENERATED FRAMES");
    println!("=================================================");

    for (i, frame) in all_frames.iter().enumerate() {
        println!("frame {}: {:?}", i, frame);
    }

    println!();
    println!("Generation SUCCESS.");

    Ok(())
}
