use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use chrono::Local;

use crate::config::SynthesisConfig;
use crate::engine::SynthesisResult;
use crate::wav::write_wav_mono_f32;

const CACHE_VERSION: &str = "v2";

pub const CACHE_MAX_AGE: Duration = Duration::from_secs(7 * 24 * 60 * 60);

pub struct TtsCache {
    pub(crate) directory: PathBuf,
}

impl TtsCache {
    pub fn new(directory: impl AsRef<Path>) -> Result<Self, String> {
        let directory = directory.as_ref().to_path_buf();

        fs::create_dir_all(&directory).map_err(|e| {
            format!(
                "Could not create cache directory {}: {e}",
                directory.display()
            )
        })?;

        Ok(Self { directory })
    }

    pub fn remove(
        &self,
        text: &str,
        voice_id: &str,
        config: &SynthesisConfig,
    ) -> std::io::Result<bool> {
        let path = match self.find_existing_path(text, voice_id, config) {
            Some(path) => path,
            None => return Ok(false),
        };

        fs::remove_file(path)?;

        Ok(true)
    }

    pub fn path_for(&self, text: &str, voice_id: &str, config: &SynthesisConfig) -> PathBuf {
        if let Some(path) = self.find_existing_path(text, voice_id, config) {
            return path;
        }

        self.new_path(text, voice_id, config)
    }

    pub fn existing_path(
        &self,
        text: &str,
        voice_id: &str,
        config: &SynthesisConfig,
    ) -> Option<PathBuf> {
        self.find_existing_path(text, voice_id, config)
    }

    pub fn store(
        &self,
        text: &str,
        voice_id: &str,
        config: &SynthesisConfig,
        result: &SynthesisResult,
    ) -> Result<PathBuf, String> {
        let path = match self.find_existing_path(text, voice_id, config) {
            Some(path) => path,

            None => self.new_path(text, voice_id, config),
        };

        write_wav_mono_f32(&path, &result.samples, result.sample_rate)
            .map_err(|e| format!("Could not write cache file {}: {e}", path.display()))?;

        Ok(path)
    }

    pub fn load(
        &self,
        text: &str,
        voice_id: &str,
        config: &SynthesisConfig,
    ) -> Result<Option<(Vec<f32>, u32)>, String> {
        let path = match self.find_existing_path(text, voice_id, config) {
            Some(path) => path,
            None => return Ok(None),
        };

        let data = fs::read(&path)
            .map_err(|e| format!("Could not read cache file {}: {e}", path.display()))?;

        let (sample_rate, samples) = decode_cached_wav(&data)?;

        Ok(Some((samples, sample_rate)))
    }

    pub fn purge_older_than(&self, max_age: Duration) -> std::io::Result<usize> {
        if !self.directory.exists() {
            return Ok(0);
        }

        let now = std::time::SystemTime::now();

        let mut removed = 0usize;

        for entry in std::fs::read_dir(&self.directory)? {
            let entry = match entry {
                Ok(entry) => entry,

                Err(error) => {
                    eprintln!("VieNeu cache: failed to read cache entry: {error}");

                    continue;
                }
            };

            let path = entry.path();

            if !path.is_file() {
                continue;
            }

            let modified = match entry.metadata()?.modified() {
                Ok(time) => time,

                Err(error) => {
                    eprintln!(
                        "VieNeu cache: failed to get modification time for {}: {error}",
                        path.display()
                    );

                    continue;
                }
            };

            let age = match now.duration_since(modified) {
                Ok(age) => age,

                Err(_) => {
                    continue;
                }
            };

            if age > max_age {
                match std::fs::remove_file(&path) {
                    Ok(()) => {
                        removed += 1;

                        eprintln!("VieNeu cache: removed expired entry: {}", path.display());
                    }

                    Err(error) => {
                        eprintln!(
                            "VieNeu cache: failed to remove expired entry {}: {error}",
                            path.display()
                        );
                    }
                }
            }
        }

        Ok(removed)
    }

    fn find_existing_path(
        &self,
        text: &str,
        voice_id: &str,
        config: &SynthesisConfig,
    ) -> Option<PathBuf> {
        let hash = cache_hash(text, voice_id, config);

        let safe_voice = safe_filename_component(voice_id);

        let suffix = format!("__{hash}__{safe_voice}.wav");

        let entries = fs::read_dir(&self.directory).ok()?;

        for entry in entries.flatten() {
            let path = entry.path();

            if !path.is_file() {
                continue;
            }

            let name = path.file_name()?.to_str()?;

            if name.ends_with(&suffix) {
                return Some(path);
            }
        }

        None
    }

    fn new_path(&self, text: &str, voice_id: &str, config: &SynthesisConfig) -> PathBuf {
        let date = Local::now().format("%Y%m%d").to_string();

        let safe_text = safe_filename_component(text);

        let display_text = safe_text.chars().take(80).collect::<String>();

        let safe_voice = safe_filename_component(voice_id);

        let hash = cache_hash(text, voice_id, config);

        let filename = format!("{date}__{display_text}__{hash}__{safe_voice}.wav");

        self.directory.join(filename)
    }
}

fn cache_hash(text: &str, voice_id: &str, config: &SynthesisConfig) -> String {
    let value = format!(
        "{}\n\
             {}\n\
             {}\n\
             temperature={:.9}\n\
             top_k={}\n\
             top_p={:.9}\n\
             repetition_penalty={:.9}\n\
             repetition_window={}\n\
             max_new_frames={}\n\
             use_ref_codes={}",
        CACHE_VERSION,
        text,
        voice_id,
        config.temperature,
        config.top_k,
        config.top_p,
        config.repetition_penalty,
        config.repetition_window,
        config.max_new_frames,
        config.use_ref_codes,
    );

    let hash = fnv1a64(value.as_bytes());

    format!("{hash:016x}")
}

fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut hash = 0xcbf29ce484222325u64;

    for &byte in bytes {
        hash ^= byte as u64;

        hash = hash.wrapping_mul(0x100000001b3u64);
    }

    hash
}

fn safe_filename_component(text: &str) -> String {
    let mut result = String::new();

    let mut previous_separator = false;

    for character in text.chars() {
        let normalized = match character {
            'à' | 'á' | 'ả' | 'ã' | 'ạ' | 'ă' | 'ằ' | 'ắ' | 'ẳ' | 'ẵ' | 'ặ' | 'â' | 'ầ' | 'ấ'
            | 'ẩ' | 'ẫ' | 'ậ' => 'a',

            'đ' => 'd',

            'è' | 'é' | 'ẻ' | 'ẽ' | 'ẹ' | 'ê' | 'ề' | 'ế' | 'ể' | 'ễ' | 'ệ' => {
                'e'
            }

            'ì' | 'í' | 'ỉ' | 'ĩ' | 'ị' => 'i',

            'ò' | 'ó' | 'ỏ' | 'õ' | 'ọ' | 'ô' | 'ồ' | 'ố' | 'ổ' | 'ỗ' | 'ộ' | 'ơ' | 'ờ' | 'ớ'
            | 'ở' | 'ỡ' | 'ợ' => 'o',

            'ù' | 'ú' | 'ủ' | 'ũ' | 'ụ' | 'ư' | 'ừ' | 'ứ' | 'ử' | 'ữ' | 'ự' => {
                'u'
            }

            'ỳ' | 'ý' | 'ỷ' | 'ỹ' | 'ỵ' => 'y',

            'À' | 'Á' | 'Ả' | 'Ã' | 'Ạ' | 'Ă' | 'Ằ' | 'Ắ' | 'Ẳ' | 'Ẵ' | 'Ặ' | 'Â' | 'Ầ' | 'Ấ'
            | 'Ẩ' | 'Ẫ' | 'Ậ' => 'a',

            'Đ' => 'd',

            'È' | 'É' | 'Ẻ' | 'Ẽ' | 'Ẹ' | 'Ê' | 'Ề' | 'Ế' | 'Ể' | 'Ễ' | 'Ệ' => {
                'e'
            }

            'Ì' | 'Í' | 'Ỉ' | 'Ĩ' | 'Ị' => 'i',

            'Ò' | 'Ó' | 'Ỏ' | 'Õ' | 'Ọ' | 'Ô' | 'Ồ' | 'Ố' | 'Ổ' | 'Ỗ' | 'Ộ' | 'Ơ' | 'Ờ' | 'Ớ'
            | 'Ở' | 'Ỡ' | 'Ợ' => 'o',

            'Ù' | 'Ú' | 'Ủ' | 'Ũ' | 'Ụ' | 'Ư' | 'Ừ' | 'Ứ' | 'Ử' | 'Ữ' | 'Ự' => {
                'u'
            }

            'Ỳ' | 'Ý' | 'Ỷ' | 'Ỹ' | 'Ỵ' => 'y',

            character if character.is_ascii_alphanumeric() => character.to_ascii_lowercase(),

            _ => {
                if !previous_separator {
                    result.push('_');
                    previous_separator = true;
                }

                continue;
            }
        };

        result.push(normalized);

        previous_separator = false;
    }

    while result.ends_with('_') {
        result.pop();
    }

    if result.is_empty() {
        "audio".to_string()
    } else {
        result
    }
}

fn decode_cached_wav(data: &[u8]) -> Result<(u32, Vec<f32>), String> {
    if data.len() < 12 {
        return Err("Cached WAV is too small".to_string());
    }

    if &data[0..4] != b"RIFF" || &data[8..12] != b"WAVE" {
        return Err("Cached file is not a RIFF/WAVE file".to_string());
    }

    let mut offset = 12usize;

    let mut sample_rate = None;

    let mut audio_format = None;

    let mut channels = None;

    let mut bits_per_sample = None;

    let mut data_offset = None;

    let mut data_size = None;

    while offset + 8 <= data.len() {
        let chunk_id = &data[offset..offset + 4];

        let chunk_size = u32::from_le_bytes([
            data[offset + 4],
            data[offset + 5],
            data[offset + 6],
            data[offset + 7],
        ]) as usize;

        let chunk_data_start = offset + 8;

        let chunk_data_end = chunk_data_start
            .checked_add(chunk_size)
            .ok_or_else(|| "Cached WAV chunk size overflow".to_string())?;

        if chunk_data_end > data.len() {
            return Err("Cached WAV chunk extends past file".to_string());
        }

        if chunk_id == b"fmt " {
            if chunk_size < 16 {
                return Err("Cached WAV fmt chunk is too small".to_string());
            }

            audio_format = Some(u16::from_le_bytes([
                data[chunk_data_start],
                data[chunk_data_start + 1],
            ]));

            channels = Some(u16::from_le_bytes([
                data[chunk_data_start + 2],
                data[chunk_data_start + 3],
            ]));

            sample_rate = Some(u32::from_le_bytes([
                data[chunk_data_start + 4],
                data[chunk_data_start + 5],
                data[chunk_data_start + 6],
                data[chunk_data_start + 7],
            ]));

            bits_per_sample = Some(u16::from_le_bytes([
                data[chunk_data_start + 14],
                data[chunk_data_start + 15],
            ]));
        }

        if chunk_id == b"data" {
            data_offset = Some(chunk_data_start);

            data_size = Some(chunk_size);

            break;
        }

        offset = chunk_data_end + (chunk_size % 2);
    }

    let audio_format = audio_format.ok_or_else(|| "Cached WAV has no fmt chunk".to_string())?;

    let channels = channels.ok_or_else(|| "Cached WAV has no channel information".to_string())?;

    let sample_rate = sample_rate.ok_or_else(|| "Cached WAV has no sample rate".to_string())?;

    let bits_per_sample =
        bits_per_sample.ok_or_else(|| "Cached WAV has no bit-depth information".to_string())?;

    let data_start = data_offset.ok_or_else(|| "Cached WAV has no data chunk".to_string())?;

    let data_size = data_size.ok_or_else(|| "Cached WAV has no data size".to_string())?;

    if audio_format != 1 {
        return Err(format!("Unsupported cached WAV format: {}", audio_format,));
    }

    if channels != 1 {
        return Err(format!(
            "Expected mono cached WAV, got {} channels",
            channels,
        ));
    }

    if bits_per_sample != 16 {
        return Err(format!(
            "Expected 16-bit cached WAV, got {} bits",
            bits_per_sample,
        ));
    }

    if data_size % 2 != 0 {
        return Err("Cached WAV PCM data has odd byte length".to_string());
    }

    let data_end = data_start
        .checked_add(data_size)
        .ok_or_else(|| "Cached WAV data size overflow".to_string())?;

    if data_end > data.len() {
        return Err("Cached WAV data extends past file".to_string());
    }

    let sample_count = data_size / 2;

    let mut samples = Vec::with_capacity(sample_count);

    for i in 0..sample_count {
        let pos = data_start + i * 2;

        let value = i16::from_le_bytes([data[pos], data[pos + 1]]);

        samples.push(value as f32 / 32768.0);
    }

    Ok((sample_rate, samples))
}
