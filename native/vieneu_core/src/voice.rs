use std::collections::HashMap;
use std::fs;
use std::path::Path;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Deserialize)]
pub struct VoicePreset {
    pub description: String,
    pub gender: String,
    pub region: String,
    pub style: String,

    pub speaker_emb: Vec<f32>,
    pub codes: Vec<Vec<i64>>,
}

#[derive(Debug, Deserialize)]
struct VoiceFile {
    presets: HashMap<String, VoicePreset>,
}

/// UI-facing metadata.
///
/// This intentionally does NOT expose the raw speaker embedding
/// or reference codes to Flutter.
#[derive(Debug, Clone, Serialize)]
pub struct VoiceInfo {
    pub id: String,
    pub name: String,
    pub description: String,
    pub gender: String,
    pub accent: String,
    pub style: String,
}

impl VoiceInfo {
    fn from_preset(name: &str, preset: &VoicePreset) -> Self {
        Self {
            id: name.to_string(),
            name: name.to_string(),
            description: preset.description.clone(),
            gender: preset.gender.clone(),
            accent: preset.region.clone(),
            style: preset.style.clone(),
        }
    }
}

#[derive(Debug)]
pub struct VieNeuVoiceStore {
    voices: VoiceFile,
}

impl VieNeuVoiceStore {
    pub fn from_file<P: AsRef<Path>>(path: P) -> Result<Self, String> {
        let text = fs::read_to_string(path).map_err(|e| e.to_string())?;

        let voices: VoiceFile = serde_json::from_str(&text).map_err(|e| e.to_string())?;

        Ok(Self { voices })
    }

    /// Get a complete preset for native inference.
    pub fn get(&self, name: &str) -> Result<&VoicePreset, String> {
        self.voices
            .presets
            .get(name)
            .ok_or_else(|| format!("Unknown voice preset: {}", name))
    }

    /// Return UI-friendly voice metadata.
    ///
    /// Sorted by display name so Flutter receives stable ordering.
    pub fn list(&self) -> Vec<VoiceInfo> {
        let mut voices: Vec<VoiceInfo> = self
            .voices
            .presets
            .iter()
            .map(|(name, preset)| VoiceInfo::from_preset(name, preset))
            .collect();

        voices.sort_by(|a, b| a.name.cmp(&b.name));

        voices
    }

    pub fn contains(&self, name: &str) -> bool {
        self.voices.presets.contains_key(name)
    }

    pub fn len(&self) -> usize {
        self.voices.presets.len()
    }

    pub fn is_empty(&self) -> bool {
        self.voices.presets.is_empty()
    }
}
