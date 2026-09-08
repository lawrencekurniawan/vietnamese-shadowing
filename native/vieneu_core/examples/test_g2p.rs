use std::env;

use sea_g2p_rs::g2p::G2PEngine;

fn main() {
    let dict_path = env::args().nth(1).expect("Usage: test_g2p <sea_g2p.bin>");

    println!("Loading SEA-G2P...");
    println!("Dictionary: {}", dict_path);

    let engine = G2PEngine::new(&dict_path).expect("Failed to load SEA-G2P dictionary");

    println!("SEA-G2P loaded.");

    let text = "Hôm nay bạn khỏe không?";

    let phonemes = engine.phonemize(text);

    println!("Text: {}", text);
    println!("Phonemes: {}", phonemes);
}
