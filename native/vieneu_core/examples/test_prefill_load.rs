use std::env;

use ort::session::Session;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let model_path = env::args()
        .nth(1)
        .expect("Usage: test_prefill_load <prefill.onnx>");

    println!("Loading:");
    println!("{model_path}");

    let session = Session::builder()?.commit_from_file(&model_path)?;

    println!("Session loaded successfully.");

    println!("Inputs:");
    for input in session.inputs() {
        println!("  {}", input.name());
    }

    println!();
    println!("Outputs:");
    for output in session.outputs() {
        println!("  {}", output.name());
    }

    Ok(())
}
