use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SynthesisConfig {
    /// Sampling temperature.
    ///
    /// 0.0 means deterministic argmax.
    pub temperature: f32,

    /// Keep only the top K logits.
    pub top_k: usize,

    /// Nucleus sampling threshold.
    pub top_p: f32,

    /// Repetition penalty.
    pub repetition_penalty: f32,

    /// Number of previous generated codes kept
    /// for repetition control.
    pub repetition_window: usize,

    /// Maximum generated acoustic frames.
    pub max_new_frames: usize,

    /// Whether reference acoustic codes are included
    /// in the prompt.
    pub use_ref_codes: bool,

    /// Playback speed.
    ///
    /// This is stored in the UI configuration now,
    /// but actual time-stretching will be implemented
    /// in the audio/output layer rather than inside
    /// VieNeu generation.
    pub playback_speed: f32,
}

impl Default for SynthesisConfig {
    fn default() -> Self {
        Self {
            // These match the current Python reference.
            temperature: 0.8,
            top_k: 25,
            top_p: 0.95,
            repetition_penalty: 1.2,
            repetition_window: 64,
            max_new_frames: 300,

            use_ref_codes: true,

            playback_speed: 1.0,
        }
    }
}

impl SynthesisConfig {
    pub fn validate(&self) -> Result<(), String> {
        if !self.temperature.is_finite() || self.temperature < 0.0 {
            return Err("temperature must be >= 0".to_string());
        }

        if self.top_k == 0 {
            return Err("top_k must be greater than 0".to_string());
        }

        if !self.top_p.is_finite() || self.top_p <= 0.0 || self.top_p > 1.0 {
            return Err("top_p must be in (0, 1]".to_string());
        }

        if !self.repetition_penalty.is_finite() || self.repetition_penalty <= 0.0 {
            return Err("repetition_penalty must be > 0".to_string());
        }

        if self.max_new_frames == 0 {
            return Err("max_new_frames must be > 0".to_string());
        }

        if !self.playback_speed.is_finite() || self.playback_speed <= 0.0 {
            return Err("playback_speed must be > 0".to_string());
        }

        Ok(())
    }
}
