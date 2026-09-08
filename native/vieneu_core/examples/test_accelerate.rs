use std::path::Path;

use vieneu_core::embeddings::VieNeuHeads;
use vieneu_core::voice::VieNeuVoiceStore;

#[link(name = "Accelerate", kind = "framework")]
unsafe extern "C" {
    fn cblas_sgemv(
        order: i32,
        trans: i32,
        m: i32,
        n: i32,
        alpha: f32,
        a: *const f32,
        lda: i32,
        x: *const f32,
        incx: i32,
        beta: f32,
        y: *mut f32,
        incy: i32,
    );
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let root = "/Users/lawrencewong/Movies/vietnamese_shadowing";

    let heads_path = format!("{root}/assets/vieneu/model/vieneu_heads.json");

    let voices_path = format!("{root}/assets/vieneu/voices_v3_turbo.json");

    println!("Loading heads...");

    let heads = VieNeuHeads::from_json(&heads_path)?;

    println!("Loading voice...");

    let voices = VieNeuVoiceStore::from_file(&voices_path)?;

    let voice = voices.get("Xuân Vĩnh")?;

    let speaker_emb = &voice.speaker_emb;

    println!("speaker_emb length: {}", speaker_emb.len());
    println!("xvec_w length: {}", heads.xvec_w.len());
    println!("xvec_b length: {}", heads.xvec_b.len());

    assert_eq!(speaker_emb.len(), 192);

    assert_eq!(heads.xvec_w.len(), 768 * 192);

    assert_eq!(heads.xvec_b.len(), 768);

    // ---------------------------------------------------------
    // Accelerate: y = W * speaker_emb
    //
    // W is 768 x 192, row-major.
    // ---------------------------------------------------------

    let mut projected = vec![0.0f32; 768];

    unsafe {
        cblas_sgemv(
            101, // CblasRowMajor
            111, // CblasNoTrans
            768,
            192,
            1.0,
            heads.xvec_w.as_ptr(),
            192,
            speaker_emb.as_ptr(),
            1,
            0.0,
            projected.as_mut_ptr(),
            1,
        );
    }

    // Add bias exactly as the Python expression:
    //
    // v @ W.T + b
    //
    for i in 0..768 {
        projected[i] += heads.xvec_b[i];
    }

    println!("Projected length: {}", projected.len());

    println!();
    println!("First 20 Accelerate projected values:");

    for value in projected.iter().take(20) {
        println!("{:.9}", value);
    }

    // Save for comparison with Python.
    let path = "/Users/lawrencewong/Movies/vietnamese_shadowing/native/vieneu_core/rust_accelerate_projected.f32";

    let bytes = projected
        .iter()
        .flat_map(|v| v.to_le_bytes())
        .collect::<Vec<u8>>();

    std::fs::write(Path::new(path), bytes)?;

    println!();
    println!("Saved:");
    println!("{path}");

    Ok(())
}
