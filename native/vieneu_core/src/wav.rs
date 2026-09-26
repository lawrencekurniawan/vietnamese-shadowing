use std::fs::File;
use std::io::{self, Write};
use std::path::Path;

const SILENCE_THRESHOLD: f32 = 0.002;
const PADDING_MS: u32 = 20;

fn trim_silence(samples: &[f32], sample_rate: u32) -> &[f32] {
    if samples.is_empty() {
        return samples;
    }

    let first = samples
        .iter()
        .position(|sample| sample.abs() > SILENCE_THRESHOLD);

    let last = samples
        .iter()
        .rposition(|sample| sample.abs() > SILENCE_THRESHOLD);

    let (first, last) = match (first, last) {
        (Some(first), Some(last)) if first <= last => (first, last),
        _ => return samples,
    };

    let padding = ((sample_rate as u64 * PADDING_MS as u64) / 1000) as usize;

    let start = first.saturating_sub(padding);
    let end = (last + padding + 1).min(samples.len());

    &samples[start..end]
}

pub fn write_wav_mono_f32(
    path: impl AsRef<Path>,
    samples: &[f32],
    sample_rate: u32,
) -> io::Result<()> {
    let samples = trim_silence(samples, sample_rate);

    // Convert float32 [-1, 1] to signed 16-bit PCM.
    let mut pcm = Vec::with_capacity(samples.len() * 2);

    for &sample in samples {
        let x = sample.clamp(-1.0, 1.0);

        let value = (x * i16::MAX as f32).round() as i16;

        pcm.extend_from_slice(&value.to_le_bytes());
    }

    let byte_rate = sample_rate * 1 * 2;

    let block_align = 1u16 * 2u16;

    let data_size = pcm.len() as u32;

    let riff_size = 36u32 + data_size;

    let mut file = File::create(path)?;

    // RIFF header
    file.write_all(b"RIFF")?;
    file.write_all(&riff_size.to_le_bytes())?;
    file.write_all(b"WAVE")?;

    // fmt chunk
    file.write_all(b"fmt ")?;
    file.write_all(&16u32.to_le_bytes())?; // PCM fmt chunk size
    file.write_all(&1u16.to_le_bytes())?; // PCM
    file.write_all(&1u16.to_le_bytes())?; // mono
    file.write_all(&sample_rate.to_le_bytes())?;
    file.write_all(&byte_rate.to_le_bytes())?;
    file.write_all(&block_align.to_le_bytes())?;
    file.write_all(&16u16.to_le_bytes())?; // 16-bit

    // data chunk
    file.write_all(b"data")?;
    file.write_all(&data_size.to_le_bytes())?;
    file.write_all(&pcm)?;

    Ok(())
}