use std::env;
use std::path::Path;

use ort::session::Session;

fn main() {
    let ort_path = env::var("ORT_DYLIB_PATH").expect("ORT_DYLIB_PATH must be set");

    println!("ORT dylib: {}", ort_path);

    if !Path::new(&ort_path).is_file() {
        panic!("ORT dylib does not exist");
    }

    println!("Preloading ONNX Runtime...");
    ort::util::preload_dylib(&ort_path).expect("Failed to preload ONNX Runtime");
    println!("ONNX Runtime preloaded.");

    println!("Calling Session::builder()...");
    let _builder = Session::builder().expect("Session::builder() failed");

    println!("Session::builder() returned successfully.");
}
