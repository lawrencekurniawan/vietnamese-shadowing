use std::env;

use vieneu_core::prompt::{VieNeuPromptConfig, build_prompt};

use vieneu_core::tokenizer::VieNeuTokenizer;

fn main() {
    let tokenizer_path = env::args()
        .nth(1)
        .expect("Usage: test_prompt <tokenizer.json>");

    let tokenizer = VieNeuTokenizer::from_file(&tokenizer_path).expect("Failed to load tokenizer");

    let phonemes = "hˈom nˈaj bˈaː6n xwˈɛ4 xˌoŋ?";

    let phone_ids = tokenizer.encode(phonemes).expect("Tokenization failed");

    // Xuân Vĩnh reference codes from the actual
    // voices_v3_turbo.json are 40 x 16.
    //
    // For this test, we do not hard-code the values.
    // We only verify the row structure.
    let reference = vec![vec![0i64; 16]; 40];

    let prompt = build_prompt(&phone_ids, &reference, VieNeuPromptConfig::default())
        .expect("Failed to build prompt");

    println!("Phone IDs:");
    println!("{:?}", phone_ids);

    println!();
    println!("Prompt shape: ({}, {})", prompt.rows_count, prompt.columns);

    println!();
    println!("First 3 rows:");

    for i in 0..3 {
        println!("{:?}", prompt.row(i).unwrap());
    }

    println!();
    println!("Last 5 rows:");

    for i in prompt.rows_count - 5..prompt.rows_count {
        println!("{:?}", prompt.row(i).unwrap());
    }
}
