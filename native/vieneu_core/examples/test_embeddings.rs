use std::fs::File;
use std::io::Write;

use vieneu_core::embeddings::VieNeuHeads;
use vieneu_core::prompt::{VieNeuPromptConfig, build_prompt};
use vieneu_core::tokenizer::VieNeuTokenizer;
use vieneu_core::voice::VieNeuVoiceStore;

fn main() {
    let root = "/Users/lawrencewong/Movies/vietnamese_shadowing";

    let tokenizer_path = format!("{root}/assets/vieneu/model/tokenizer.json");

    let heads_path = format!("{root}/assets/vieneu/model/vieneu_heads.json");

    let voices_path = format!("{root}/assets/vieneu/voices_v3_turbo.json");

    let tokenizer = VieNeuTokenizer::from_file(&tokenizer_path).expect("Failed to load tokenizer");

    let heads = VieNeuHeads::from_json(&heads_path).expect("Failed to load heads");

    let voices = VieNeuVoiceStore::from_file(&voices_path).expect("Failed to load voices");

    let voice = voices.get("Xuân Vĩnh").expect("Voice not found");

    let phonemes = "hˈom nˈaj bˈaː6n xwˈɛ4 xˌoŋ?";

    let phone_ids = tokenizer.encode(phonemes).expect("Tokenization failed");

    let ref_codes = voice.codes.clone();

    let prompt = build_prompt(&phone_ids, &ref_codes, VieNeuPromptConfig::default())
        .expect("Prompt build failed");

    let anchor = heads
        .speaker_anchor(&voice.speaker_emb)
        .expect("Anchor failed");

    let embeddings = heads
        .embed_rows(&prompt, Some(&anchor))
        .expect("Embedding failed");

    println!("Prompt shape: ({}, {})", prompt.rows_count, prompt.columns);

    println!("Embedding shape: (1, {}, 768)", prompt.rows_count);

    println!("Embedding values: {}", embeddings.len());

    println!();
    println!("First 10 values:");

    for value in embeddings.iter().take(10) {
        println!("{value:.9}");
    }

    let mut file = File::create("rust_prompt_embeds.f32").expect("Failed to create output");

    for value in &embeddings {
        file.write_all(&value.to_le_bytes())
            .expect("Failed to write output");
    }

    println!();
    println!("Saved rust_prompt_embeds.f32");
}
