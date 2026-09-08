use std::ffi::CString;
use std::fs;

use vieneu_core::{
    vieneu_free_string, vieneu_tts_create, vieneu_tts_destroy, vieneu_tts_list_voices,
    vieneu_tts_synthesize_to_wav,
};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let assets_root = "/Users/lawrencewong/Movies/vietnamese_shadowing/assets";

    let cache_root = "/Users/lawrencewong/Movies/vietnamese_shadowing/tts-cache";

    let output_path = "/Users/lawrencewong/Movies/vietnamese_shadowing/rust_ffi_test.wav";

    fs::create_dir_all(cache_root)?;

    let assets_root = CString::new(assets_root)?;

    let cache_root = CString::new(cache_root)?;

    let output_path = CString::new(output_path)?;

    let text = CString::new("Hôm nay bạn khỏe không?")?;

    let voice_id = CString::new("Xuân Vĩnh")?;

    println!("Creating native TTS engine...");

    let engine = vieneu_tts_create(assets_root.as_ptr(), cache_root.as_ptr());

    if engine.is_null() {
        return Err("vieneu_tts_create() failed".into());
    }

    println!("Native TTS engine created.");

    println!();
    println!("Loading voices...");

    let voices_ptr = vieneu_tts_list_voices(engine);

    if voices_ptr.is_null() {
        vieneu_tts_destroy(engine);

        return Err("vieneu_tts_list_voices() failed".into());
    }

    let voices = unsafe { std::ffi::CStr::from_ptr(voices_ptr) };

    println!("Voices JSON:");

    println!("{}", voices.to_string_lossy());

    vieneu_free_string(voices_ptr);

    println!();
    println!("Synthesizing...");

    let result = vieneu_tts_synthesize_to_wav(
        engine,
        text.as_ptr(),
        voice_id.as_ptr(),
        output_path.as_ptr(),
    );

    if result != 1 {
        vieneu_tts_destroy(engine);

        return Err("vieneu_tts_synthesize_to_wav() failed".into());
    }

    println!("Synthesis succeeded.");

    println!("Saved: {}", output_path.to_string_lossy());

    vieneu_tts_destroy(engine);

    println!("Native TTS engine destroyed.");

    Ok(())
}
