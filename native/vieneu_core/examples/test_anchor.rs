use std::env;

use vieneu_core::embeddings::VieNeuHeads;
use vieneu_core::voice::VieNeuVoiceStore;

fn main() {
    let heads_path = env::args()
        .nth(1)
        .expect("Usage: test_anchor <heads.json> <voices.json>");

    let voices_path = env::args()
        .nth(2)
        .expect("Usage: test_anchor <heads.json> <voices.json>");

    let heads = VieNeuHeads::from_json(heads_path).expect("Failed to load heads");

    let voices = VieNeuVoiceStore::from_file(voices_path).expect("Failed to load voices");

    let voice = voices.get("Xuân Vĩnh").expect("Voice not found");

    let anchor = heads
        .speaker_anchor(&voice.speaker_emb)
        .expect("Failed to create speaker anchor");

    println!("Speaker anchor length: {}", anchor.len());

    println!("First 10 values:");

    for value in anchor.iter().take(10) {
        println!("{:.9}", value);
    }
}
