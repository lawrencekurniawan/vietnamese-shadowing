use std::path::Path;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let path = std::env::var("ORT_DYLIB_PATH")?;

    println!("Dylib:");
    println!("{path}");

    ort::util::preload_dylib(Path::new(&path))?;

    println!("ort crate MINOR_VERSION: {}", ort::MINOR_VERSION);

    println!("ort crate version: {}", env!("CARGO_PKG_VERSION"));

    Ok(())
}
