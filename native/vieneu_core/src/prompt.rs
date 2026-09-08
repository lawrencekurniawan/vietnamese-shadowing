use std::convert::TryInto;

/// VieNeu v3 Turbo prompt constants.
///
/// These are read from the current model config, but for this first
/// implementation we keep them explicit and validate them against
/// config.json in the next step.
#[derive(Debug, Clone, Copy)]
pub struct VieNeuPromptConfig {
    pub n_vq: usize,
    pub audio_pad: i64,
    pub text_prompt_start: i64,
    pub text_prompt_end: i64,
    pub audio_ref_slot: i64,
    pub default_style: i64,
}

impl Default for VieNeuPromptConfig {
    fn default() -> Self {
        Self {
            n_vq: 16,
            audio_pad: 1024,
            text_prompt_start: 3,
            text_prompt_end: 4,
            audio_ref_slot: 7,
            default_style: 16,
        }
    }
}

#[derive(Debug, Clone)]
pub struct VieNeuPrompt {
    /// Flattened row-major representation of shape:
    ///
    /// (T, n_vq + 1)
    ///
    /// For v3 Turbo this is (T, 17).
    pub rows: Vec<i64>,

    pub rows_count: usize,
    pub columns: usize,
}

impl VieNeuPrompt {
    pub fn as_slice(&self) -> &[i64] {
        &self.rows
    }

    pub fn row(&self, index: usize) -> Option<&[i64]> {
        if index >= self.rows_count {
            return None;
        }

        let start = index * self.columns;
        let end = start + self.columns;

        Some(&self.rows[start..end])
    }
}

/// Build the exact row layout used by VieNeu's `_build_rows()`.
///
/// `phone_ids` are the IDs produced by tokenizer.json.
/// `ref_codes` must contain `n_vq` code IDs per reference frame.
pub fn build_prompt(
    phone_ids: &[u32],
    ref_codes: &[Vec<i64>],
    config: VieNeuPromptConfig,
) -> Result<VieNeuPrompt, String> {
    if config.n_vq == 0 {
        return Err("n_vq must be greater than zero".to_string());
    }

    for (i, frame) in ref_codes.iter().enumerate() {
        if frame.len() != config.n_vq {
            return Err(format!(
                "reference frame {} has {} codes; expected {}",
                i,
                frame.len(),
                config.n_vq
            ));
        }
    }

    let columns = config.n_vq + 1;

    let text_token_count = phone_ids.len() + 3;

    let total_rows = text_token_count + ref_codes.len();

    let mut rows = vec![config.audio_pad; total_rows * columns];

    // text_ids =
    // [style_id, TEXT_PROMPT_START, ...phone_ids, TEXT_PROMPT_END]
    let mut row = 0usize;

    rows[row * columns] = config.default_style;
    row += 1;

    rows[row * columns] = config.text_prompt_start;
    row += 1;

    for &phone_id in phone_ids {
        rows[row * columns] = i64::from(phone_id);
        row += 1;
    }

    rows[row * columns] = config.text_prompt_end;
    row += 1;

    // Reference rows:
    //
    // [audio_ref_slot, code_0, ..., code_15]
    for frame in ref_codes {
        let offset = row * columns;

        rows[offset] = config.audio_ref_slot;

        for ch in 0..config.n_vq {
            rows[offset + 1 + ch] = frame[ch];
        }

        row += 1;
    }

    debug_assert_eq!(row, total_rows);

    Ok(VieNeuPrompt {
        rows,
        rows_count: total_rows,
        columns,
    })
}
