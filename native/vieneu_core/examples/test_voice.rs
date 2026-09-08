use std::env;

use vieneu_core::voice::VieNeuVoiceStore;

fn main() {
    let path = env::args()
        .nth(1)
        .expect("Usage: test_voice <voices_v3_turbo.json>");

    let store = VieNeuVoiceStore::from_file(path).expect("Failed to load voice file");

    let voice = store.get("Xuân Vĩnh").expect("Xuân Vĩnh not found");

    println!("Name: Xuân Vĩnh");
    println!("Description: {}", voice.description);
    println!("Gender: {}", voice.gender);
    println!("Region: {}", voice.region);
    println!("Style: {}", voice.style);
    println!("speaker_emb length: {}", voice.speaker_emb.len());
    println!("reference frames: {}", voice.codes.len());

    if let Some(first) = voice.codes.first() {
        println!("codes per frame: {}", first.len());
    }
}
