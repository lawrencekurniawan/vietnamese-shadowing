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

use std::fs;
use std::path::Path;

use serde_json::Value;

use crate::prompt::VieNeuPrompt;
use crate::voice::VoicePreset;

pub struct VieNeuHeads {
    pub text_emb: Vec<f32>,
    pub audio_emb: Vec<f32>,

    pub xvec_w: Vec<f32>,
    pub xvec_b: Vec<f32>,
    pub xvec_ln_w: Vec<f32>,
    pub xvec_ln_b: Vec<f32>,
    pub xvec_ln_eps: f32,

    pub hidden_size: usize,
    pub text_vocab: usize,
    pub n_vq: usize,
    pub audio_vocab: usize,
}

impl VieNeuHeads {
    pub fn from_json<P: AsRef<Path>>(path: P) -> Result<Self, String> {
        let text = fs::read_to_string(path).map_err(|e| e.to_string())?;

        let root: Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;

        Ok(Self {
            text_emb: read_f32_array(&root["text_emb"])?,
            audio_emb: read_f32_array(&root["audio_emb"])?,
            xvec_w: read_f32_array(&root["xvec_w"])?,
            xvec_b: read_f32_array(&root["xvec_b"])?,
            xvec_ln_w: read_f32_array(&root["xvec_ln_w"])?,
            xvec_ln_b: read_f32_array(&root["xvec_ln_b"])?,
            xvec_ln_eps: root["xvec_ln_eps"]
                .as_f64()
                .ok_or_else(|| "Missing xvec_ln_eps".to_string())? as f32,

            hidden_size: 768,
            text_vocab: 419,
            n_vq: 16,
            audio_vocab: 1024,
        })
    }

    pub fn text_embedding(&self, token_id: usize) -> &[f32] {
        assert!(token_id < self.text_vocab);

        let start = token_id * self.hidden_size;

        &self.text_emb[start..start + self.hidden_size]
    }

    pub fn audio_embedding(&self, channel: usize, code: usize) -> &[f32] {
        assert!(channel < self.n_vq);
        assert!(code < self.audio_vocab);

        let start = (channel * self.audio_vocab + code) * self.hidden_size;

        &self.audio_emb[start..start + self.hidden_size]
    }

    pub fn speaker_anchor_debug(
        &self,
        speaker_emb: &[f32],
    ) -> Result<(Vec<f32>, Vec<f32>, f32, f32, Vec<f32>, Vec<f32>), String> {
        if speaker_emb.len() != 192 {
            return Err(format!(
                "Expected 192-dimensional speaker embedding, got {}",
                speaker_emb.len()
            ));
        }

        let mut projected = vec![0.0f32; self.hidden_size];

        unsafe {
            cblas_sgemv(
                101, // CblasRowMajor
                111, // CblasNoTrans
                self.hidden_size as i32,
                192,
                1.0,
                self.xvec_w.as_ptr(),
                192,
                speaker_emb.as_ptr(),
                1,
                0.0,
                projected.as_mut_ptr(),
                1,
            );
        }

        // Add bias after the matrix-vector multiplication.
        for i in 0..self.hidden_size {
            projected[i] += self.xvec_b[i];
        }

        let mut projected_f64 = vec![0.0f32; self.hidden_size];

        for i in 0..self.hidden_size {
            let mut value = self.xvec_b[i] as f64;

            for j in 0..192 {
                value += (self.xvec_w[i * 192 + j] as f64) * (speaker_emb[j] as f64);
            }

            projected_f64[i] = value as f32;
        }

        let mut mean = 0.0f32;

        for &value in &projected {
            mean += value;
        }

        mean /= self.hidden_size as f32;

        let mut variance = 0.0f32;

        for &value in &projected {
            let d = value - mean;
            variance += d * d;
        }

        variance /= self.hidden_size as f32;

        let inv_std = 1.0f32 / (variance + self.xvec_ln_eps).sqrt();

        let mut normalized = vec![0.0f32; self.hidden_size];

        let mut output = vec![0.0f32; self.hidden_size];

        for i in 0..self.hidden_size {
            normalized[i] = (projected[i] - mean) * inv_std;

            output[i] = normalized[i] * self.xvec_ln_w[i] + self.xvec_ln_b[i];
        }

        Ok((projected, projected_f64, mean, variance, normalized, output))
    }

    pub fn speaker_anchor(&self, speaker_emb: &[f32]) -> Result<Vec<f32>, String> {
        let (_projected, _projected_f64, _mean, _variance, _normalized, output) =
            self.speaker_anchor_debug(speaker_emb)?;

        Ok(output)
    }

    /// Reproduce VieNeu's `_embed_rows()`:
    ///
    /// rows: (T, 17)
    /// output: (T, 768), flattened row-major
    pub fn embed_rows(
        &self,
        prompt: &VieNeuPrompt,
        anchor: Option<&[f32]>,
    ) -> Result<Vec<f32>, String> {
        if prompt.columns != self.n_vq + 1 {
            return Err(format!(
                "Expected {} columns, got {}",
                self.n_vq + 1,
                prompt.columns
            ));
        }

        if let Some(anchor) = anchor {
            if anchor.len() != self.hidden_size {
                return Err(format!(
                    "Anchor must have {} values, got {}",
                    self.hidden_size,
                    anchor.len()
                ));
            }
        }

        let mut output = vec![0.0f32; prompt.rows_count * self.hidden_size];

        for row_index in 0..prompt.rows_count {
            let row = prompt
                .row(row_index)
                .ok_or_else(|| "Invalid prompt row".to_string())?;

            let text_id =
                usize::try_from(row[0]).map_err(|_| "Negative text token ID".to_string())?;

            let text_embedding = self.text_embedding(text_id);

            let out_start = row_index * self.hidden_size;

            // Start with the text embedding.
            for h in 0..self.hidden_size {
                output[out_start + h] = text_embedding[h];
            }

            // Add each valid audio-code embedding.
            //
            // 1024 is the pad ID and does NOT contribute.
            for ch in 0..self.n_vq {
                let code = row[ch + 1];

                if code == 1024 {
                    continue;
                }

                let code = usize::try_from(code).map_err(|_| {
                    format!("Negative audio code at row {}, channel {}", row_index, ch)
                })?;

                let audio = self.audio_embedding(ch, code);

                for h in 0..self.hidden_size {
                    output[out_start + h] += audio[h];
                }
            }

            // Add speaker anchor to every row.
            if let Some(anchor) = anchor {
                for h in 0..self.hidden_size {
                    output[out_start + h] += anchor[h];
                }
            }
        }

        Ok(output)
    }

    pub fn debug_embed_rows(
        &self,
        prompt: &VieNeuPrompt,
        anchor: Option<&[f32]>,
    ) -> Result<(Vec<f32>, Vec<f32>, Vec<f32>), String> {
        if prompt.columns != self.n_vq + 1 {
            return Err(format!(
                "Expected {} columns, got {}",
                self.n_vq + 1,
                prompt.columns
            ));
        }

        if let Some(anchor) = anchor {
            if anchor.len() != self.hidden_size {
                return Err(format!(
                    "Anchor must have {} values, got {}",
                    self.hidden_size,
                    anchor.len()
                ));
            }
        }

        let count = prompt.rows_count * self.hidden_size;

        let mut text_only = vec![0.0f32; count];

        let mut text_audio = vec![0.0f32; count];

        let mut full = vec![0.0f32; count];

        for row_index in 0..prompt.rows_count {
            let row = prompt
                .row(row_index)
                .ok_or_else(|| "Invalid prompt row".to_string())?;

            let text_id =
                usize::try_from(row[0]).map_err(|_| "Negative text token ID".to_string())?;

            let text = self.text_embedding(text_id);

            let start = row_index * self.hidden_size;

            // 1. Text only.
            for h in 0..self.hidden_size {
                text_only[start + h] = text[h];
            }

            // 2. Text + audio.
            for h in 0..self.hidden_size {
                text_audio[start + h] = text[h];
            }

            for ch in 0..self.n_vq {
                let code = row[ch + 1];

                if code == 1024 {
                    continue;
                }

                let code = usize::try_from(code).map_err(|_| {
                    format!("Negative audio code at row {}, channel {}", row_index, ch)
                })?;

                let audio = self.audio_embedding(ch, code);

                for h in 0..self.hidden_size {
                    text_audio[start + h] += audio[h];
                }
            }

            // 3. Full = text + audio + anchor.
            for h in 0..self.hidden_size {
                full[start + h] = text_audio[start + h];

                if let Some(anchor) = anchor {
                    full[start + h] += anchor[h];
                }
            }
        }

        Ok((text_only, text_audio, full))
    }
}

fn read_f32_array(value: &Value) -> Result<Vec<f32>, String> {
    value["data"]
        .as_array()
        .ok_or_else(|| "Expected array data".to_string())?
        .iter()
        .map(|v| {
            v.as_f64()
                .map(|x| x as f32)
                .ok_or_else(|| "Invalid float value".to_string())
        })
        .collect()
}
