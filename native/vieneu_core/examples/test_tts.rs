use std::fs;
use std::io::Write;
use std::path::Path;

use ndarray::{Array1, Array2, Array3, Array4};
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
const BACKBONE_HEADS: usize = 4;
const BACKBONE_HEAD_DIM: usize = 64;

const ACOUSTIC_HEADS: usize = 8;
const ACOUSTIC_HEAD_DIM: usize = 96;

const SGS: i64 = 5;
const EOS: usize = 6;

const SAMPLE_RATE: u32 = 48_000;

// Safety cap.
// 50 frames is roughly 4 seconds at ~3840 samples/frame.
const MAX_NEW_FRAMES: usize = 50;

const TEXT: &str = "Hôm nay bạn khỏe không?";

const PHONEMES: &str = "hˈom nˈaj bˈaː6n xwˈɛ4 xˌoŋ?";

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

fn read_f32_file(path: &str) -> Result<Vec<f32>, Box<dyn std::error::Error>> {
    let bytes = fs::read(path)?;

    if bytes.len() % 4 != 0 {
        return Err(format!(
            "File {} has {} bytes; expected multiple of 4",
            path,
            bytes.len()
        )
        .into());
    }

    let mut values = Vec::with_capacity(bytes.len() / 4);

    for chunk in bytes.chunks_exact(4) {
        values.push(f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]));
    }

    Ok(values)
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

    for (i, &value) in values.iter().enumerate() {
        if value > best_value {
            best_value = value;
            best_index = i;
        }
    }

    best_index
}

fn create_session(path: &str) -> Result<Session, Box<dyn std::error::Error>> {
    let session = Session::builder()?
        .with_optimization_level(GraphOptimizationLevel::Disable)?
        .with_inter_threads(1)?
        .with_intra_threads(1)?
        .with_intra_op_spinning(false)?
        .with_execution_providers([ep::CPU::default().build()])?
        .commit_from_file(path)?;

    Ok(session)
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    preload_onnxruntime()?;

    let root = "/Users/lawrencewong/Movies/vietnamese_shadowing";

    let model_root = format!("{root}/assets/vieneu/model");

    let codec_root = format!("{root}/assets/vieneu/codec");

    let prefill_path = format!("{model_root}/vieneu_prefill.onnx");

    let decode_path = format!("{model_root}/vieneu_decode_step.onnx");

    let acoustic_path = format!("{model_root}/vieneu_acoustic_cached.onnx");

    let codec_path = format!("{codec_root}/moss_audio_tokenizer_decode_full.onnx");

    let tokenizer_path = format!("{model_root}/tokenizer.json");

    let heads_path = format!("{model_root}/vieneu_heads.json");

    let voices_path = format!("{root}/assets/vieneu/voices_v3_turbo.json");

    // Exact anchor previously validated against Python.
    let exact_anchor_path =
        format!("{root}/tools/vieneu-reference/direct_generation/python_generation_anchor.f32");

    println!();
    println!("========================================");
    println!("VieNeu real TTS test");
    println!("========================================");
    println!("Text: {}", TEXT);
    println!("Phonemes: {}", PHONEMES);
    println!();

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
    // Load exact validated anchor
    // =========================================================

    println!("Loading exact validated speaker anchor...");

    let anchor = read_f32_file(&exact_anchor_path)?;

    if anchor.len() != HIDDEN {
        return Err(format!("Expected {} anchor values, got {}", HIDDEN, anchor.len()).into());
    }

    println!("Anchor loaded: {} values", anchor.len());

    // =========================================================
    // Build prompt
    // =========================================================

    let phone_ids = tokenizer.encode(PHONEMES)?;

    println!("Phone IDs: {:?}", phone_ids);

    let prompt = build_prompt(&phone_ids, &voice.codes, VieNeuPromptConfig::default())?;

    let prompt_length = prompt.rows_count;

    println!("Prompt rows: {}", prompt_length);

    let prompt_embeddings = heads.embed_rows(&prompt, Some(&anchor))?;

    let prompt_input = Array3::from_shape_vec((1, prompt_length, HIDDEN), prompt_embeddings)?;

    // =========================================================
    // Load sessions
    // =========================================================

    println!();
    println!("Loading prefill...");

    let mut prefill = create_session(&prefill_path)?;

    println!("Loading backbone decode...");

    let mut backbone = create_session(&decode_path)?;

    println!("Loading acoustic decoder...");

    let mut acoustic = create_session(&acoustic_path)?;

    println!("Loading MOSS codec...");

    let mut codec = create_session(&codec_path)?;

    // =========================================================
    // PREFILL
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

        let hidden_start = (prompt_length - 1) * HIDDEN;

        let h = hidden.1[hidden_start..hidden_start + HIDDEN].to_vec();

        let mut k = Vec::with_capacity(BACKBONE_LAYERS);

        let mut v = Vec::with_capacity(BACKBONE_LAYERS);

        for i in 0..BACKBONE_LAYERS {
            let value = outputs[1 + i].try_extract_tensor::<f32>()?;

            k.push(Array4::from_shape_vec(
                (1, BACKBONE_HEADS, prompt_length, BACKBONE_HEAD_DIM),
                value.1.to_vec(),
            )?);
        }

        for i in 0..BACKBONE_LAYERS {
            let value = outputs[13 + i].try_extract_tensor::<f32>()?;

            v.push(Array4::from_shape_vec(
                (1, BACKBONE_HEADS, prompt_length, BACKBONE_HEAD_DIM),
                value.1.to_vec(),
            )?);
        }

        (k, v, h)
    };

    println!("Prefill complete.");

    // =========================================================
    // GENERATION
    // =========================================================

    let mut frames: Vec<Vec<i32>> = Vec::new();

    let mut eos_reached = false;

    for frame_index in 0..MAX_NEW_FRAMES {
        println!();
        println!("----------------------------------------");
        println!("Frame {}", frame_index);
        println!("----------------------------------------");

        // =====================================================
        // ACOUSTIC FRAME
        // =====================================================

        let (codes, eos) = {
            // -------------------------------------------------
            // First acoustic call.
            //
            // token_emb =
            // [backbone_hidden, SGS_embedding]
            // -------------------------------------------------

            let sgs = heads.text_embedding(SGS as usize);

            let mut first_input = Vec::with_capacity(HIDDEN * 2);

            first_input.extend_from_slice(&h);

            first_input.extend_from_slice(sgs);

            let acoustic_input = Array3::from_shape_vec((1, 2, HIDDEN), first_input)?;

            let positions = Array2::from_shape_vec((1, 2), vec![0i64, 1i64])?;

            let empty_k = Array4::<f32>::zeros((1, ACOUSTIC_HEADS, 0, ACOUSTIC_HEAD_DIM));

            let empty_v = Array4::<f32>::zeros((1, ACOUSTIC_HEADS, 0, ACOUSTIC_HEAD_DIM));

            let (mut acoustic_k, mut acoustic_v, slot0, code0) = {
                let outputs = acoustic.run(ort::inputs![
                    "token_emb" =>
                        TensorRef::from_array_view(
                            &acoustic_input
                        )?,

                    "position_ids" =>
                        TensorRef::from_array_view(
                            &positions
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
                    return Err(
                        format!("Expected 3 acoustic outputs, got {}", outputs.len()).into(),
                    );
                }

                let hidden = outputs[0].try_extract_tensor::<f32>()?;

                if hidden.1.len() != 2 * HIDDEN {
                    return Err(
                        format!("Unexpected acoustic hidden size: {}", hidden.1.len()).into(),
                    );
                }

                let slot0 = hidden.1[0..HIDDEN].to_vec();

                let channel0 = &hidden.1[HIDDEN..2 * HIDDEN];

                let mut logits = vec![0.0f32; heads.audio_vocab];

                for code in 0..heads.audio_vocab {
                    logits[code] = dot(channel0, heads.audio_embedding(0, code));
                }

                let code0 = argmax(&logits);

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

                (acoustic_k, acoustic_v, slot0, code0)
            };

            let mut codes = Vec::with_capacity(N_VQ);

            codes.push(code0);

            // -------------------------------------------------
            // Acoustic channels 1..15
            // -------------------------------------------------

            for ch in 1..N_VQ {
                let previous_code = codes[ch - 1];

                let embedding = heads.audio_embedding(ch - 1, previous_code);

                let input = Array3::from_shape_vec((1, 1, HIDDEN), embedding.to_vec())?;

                let positions = Array2::from_shape_vec((1, 1), vec![(ch + 1) as i64])?;

                let (next_hidden, next_k, next_v) = {
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

                    if outputs.len() != 3 {
                        return Err(format!(
                            "Acoustic channel {} returned {} outputs",
                            ch,
                            outputs.len()
                        )
                        .into());
                    }

                    let hidden = outputs[0].try_extract_tensor::<f32>()?;

                    let k = outputs[1].try_extract_tensor::<f32>()?;

                    let v = outputs[2].try_extract_tensor::<f32>()?;

                    (hidden.1.to_vec(), k.1.to_vec(), v.1.to_vec())
                };

                acoustic_k =
                    Array4::from_shape_vec((1, ACOUSTIC_HEADS, ch + 2, ACOUSTIC_HEAD_DIM), next_k)?;

                acoustic_v =
                    Array4::from_shape_vec((1, ACOUSTIC_HEADS, ch + 2, ACOUSTIC_HEAD_DIM), next_v)?;

                let mut logits = vec![0.0f32; heads.audio_vocab];

                for code in 0..heads.audio_vocab {
                    logits[code] = dot(&next_hidden, heads.audio_embedding(ch, code));
                }

                let code = argmax(&logits);

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

            (codes, eos_token == EOS)
        };

        let printable_codes: Vec<i32> = codes.iter().map(|&x| x as i32).collect();

        println!("codes = {:?}", printable_codes);

        println!("EOS = {}", eos);

        frames.push(printable_codes);

        if eos {
            eos_reached = true;

            break;
        }

        // =====================================================
        // FEED FRAME BACK INTO BACKBONE
        // =====================================================

        let mut next_embedding = heads.text_embedding(SGS as usize).to_vec();

        for ch in 0..N_VQ {
            let audio = heads.audio_embedding(ch, codes[ch]);

            for h_index in 0..HIDDEN {
                next_embedding[h_index] += audio[h_index];
            }
        }

        for h_index in 0..HIDDEN {
            next_embedding[h_index] += anchor[h_index];
        }

        let next_input = Array3::from_shape_vec((1, 1, HIDDEN), next_embedding)?;

        let next_position =
            Array2::from_shape_vec((1, 1), vec![(prompt_length + frame_index) as i64])?;

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

            let new_length = prompt_length + frame_index + 1;

            let mut next_k = Vec::with_capacity(BACKBONE_LAYERS);

            let mut next_v = Vec::with_capacity(BACKBONE_LAYERS);

            for i in 0..BACKBONE_LAYERS {
                let value = outputs[1 + i].try_extract_tensor::<f32>()?;

                next_k.push(Array4::from_shape_vec(
                    (1, BACKBONE_HEADS, new_length, BACKBONE_HEAD_DIM),
                    value.1.to_vec(),
                )?);
            }

            for i in 0..BACKBONE_LAYERS {
                let value = outputs[13 + i].try_extract_tensor::<f32>()?;

                next_v.push(Array4::from_shape_vec(
                    (1, BACKBONE_HEADS, new_length, BACKBONE_HEAD_DIM),
                    value.1.to_vec(),
                )?);
            }

            (next_h, next_k, next_v)
        };

        h = next_h;

        backbone_k = next_k;

        backbone_v = next_v;

        println!("backbone cache = {}", prompt_length + frame_index + 1);
    }

    // =========================================================
    // Generation summary
    // =========================================================

    println!();
    println!("========================================");
    println!("Generation complete");
    println!("========================================");

    println!("Frames generated: {}", frames.len());

    println!("EOS reached: {}", eos_reached);

    println!(
        "Estimated duration: {:.2} sec",
        frames.len() as f32 * 3840.0 / SAMPLE_RATE as f32
    );

    // =========================================================
    // Flatten codes
    // =========================================================

    let num_frames = frames.len();

    let mut flat_codes = Vec::with_capacity(num_frames * N_VQ);

    for frame in &frames {
        for &code in frame {
            flat_codes.push(code as i64);
        }
    }

    save_i64("rust_tts_codes.i64", &flat_codes)?;

    // =========================================================
    // MOSS codec
    // =========================================================

    println!();
    println!("Running MOSS codec...");

    let audio_codes = Array3::from_shape_vec(
        (1, num_frames, N_VQ),
        flat_codes.iter().map(|&x| x as i32).collect(),
    )?;

    let audio_code_lengths = Array1::from_vec(vec![num_frames as i32]);

    let outputs = codec.run(ort::inputs![
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
        return Err(format!("Expected 2 codec outputs, got {}", outputs.len()).into());
    }

    let audio = outputs[0].try_extract_tensor::<f32>()?;

    println!("Codec output shape: {:?}", audio.0);

    if audio.0.len() != 3 {
        return Err(format!("Expected rank-3 codec output, got {:?}", audio.0).into());
    }

    let batch = audio.0[0] as usize;

    let channels = audio.0[1] as usize;

    let samples = audio.0[2] as usize;

    if batch != 1 {
        return Err(format!("Expected batch=1, got {}", batch).into());
    }

    if audio.1.len() != channels * samples {
        return Err(format!(
            "Expected {} codec samples, got {}",
            channels * samples,
            audio.1.len()
        )
        .into());
    }

    // =========================================================
    // Average codec channels
    // This exactly mirrors Python:
    //
    // out[0][0].mean(0)
    // =========================================================

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

    save_f32("rust_tts_wav.f32", &wav)?;

    // =========================================================
    // WAV
    // =========================================================

    vieneu_core::wav::write_wav_mono_f32("rust_tts.wav", &wav, SAMPLE_RATE)?;

    println!();
    println!("========================================");
    println!("TTS output");
    println!("========================================");

    println!("WAV: rust_tts.wav");

    println!("Samples: {}", wav.len());

    println!("Duration: {:.2} sec", wav.len() as f32 / SAMPLE_RATE as f32);

    let peak = wav.iter().map(|x| x.abs()).fold(0.0f32, f32::max);

    println!("Peak: {:.6}", peak);

    println!();
    println!("TTS SUCCESS.");

    Ok(())
}
