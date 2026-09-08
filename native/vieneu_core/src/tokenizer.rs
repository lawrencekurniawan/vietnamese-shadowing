use std::path::Path;

use tokenizers::Tokenizer;

pub struct VieNeuTokenizer {
    tokenizer: Tokenizer,
}

impl VieNeuTokenizer {
    pub fn from_file<P: AsRef<Path>>(path: P) -> Result<Self, String> {
        let tokenizer = Tokenizer::from_file(path).map_err(|e| e.to_string())?;

        Ok(Self { tokenizer })
    }

    pub fn encode(&self, text: &str) -> Result<Vec<u32>, String> {
        let encoding = self
            .tokenizer
            .encode(text, false)
            .map_err(|e| e.to_string())?;

        Ok(encoding.get_ids().to_vec())
    }

    pub fn encode_with_tokens(&self, text: &str) -> Result<(Vec<u32>, Vec<String>), String> {
        let encoding = self
            .tokenizer
            .encode(text, false)
            .map_err(|e| e.to_string())?;

        Ok((encoding.get_ids().to_vec(), encoding.get_tokens().to_vec()))
    }
}
