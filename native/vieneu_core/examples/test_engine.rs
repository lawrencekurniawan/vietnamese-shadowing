use vieneu_core::config::SynthesisConfig;
use vieneu_core::engine::VieNeuEngine;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let assets_root = "/Users/lawrencewong/Movies/vietnamese_shadowing/assets";

    println!("Loading VieNeuEngine...");

    let mut engine = VieNeuEngine::from_assets_root(assets_root)?;

    let cache_dir = "/Users/lawrencewong/Movies/vietnamese_shadowing/tts-cache";

    engine.set_cache_directory(cache_dir)?;

    println!("Available voices:");

    for voice in engine.voices() {
        println!(
            "  {} | {} | {} | {}",
            voice.id, voice.gender, voice.accent, voice.style,
        );
    }

    let mut config = SynthesisConfig::default();

    // Deterministic test mode.
    config.temperature = 0.0;

    // Keep this short for the first
    // production-engine test.
    config.max_new_frames = 50;

    engine.set_default_config(config.clone())?;

    println!();
    println!("Generating...");

    let result = engine.synthesize_text("Hôm nay bạn khỏe không?", "Xuân Vĩnh", None)?;

    println!();
    println!("Frames generated: {}", result.frames_generated);

    println!("EOS reached: {}", result.eos_reached);

    println!("Cache hit: {}", result.cache_hit);

    println!("Duration: {:.2} sec", result.duration_seconds());

    result.write_wav("rust_engine_test.wav")?;

    println!();
    println!("Saved: rust_engine_test.wav");

    Ok(())
}
