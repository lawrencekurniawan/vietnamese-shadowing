use std::env;

use vieneu_core::tokenizer::VieNeuTokenizer;

fn main() {
    let tokenizer_path = env::args()
        .nth(1)
        .expect("Usage: test_tokenizer <tokenizer.json>");

    let tokenizer = VieNeuTokenizer::from_file(&tokenizer_path).expect("Failed to load tokenizer");

    let text = "hˈom nˈaj bˈaː6n xwˈɛ4 xˌoŋ?";

    let (ids, tokens) = tokenizer
        .encode_with_tokens(text)
        .expect("Tokenization failed");

    println!("Text:");
    println!("{}", text);

    println!();
    println!("Tokens:");

    for (i, token) in tokens.iter().enumerate() {
        println!("  {:>2}: {:?}", i, token);
    }

    println!();
    println!("IDs:");
    println!("{:?}", ids);
}
