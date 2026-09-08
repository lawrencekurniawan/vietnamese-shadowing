use crate::cache::TtsCache;
use sea_g2p_rs::g2p::G2PEngine;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use ndarray::{Array1, Array2, Array3, Array4};
use ort::{
    ep,
    session::{Session, builder::GraphOptimizationLevel},
    value::TensorRef,
};

use crate::config::SynthesisConfig;
use crate::embeddings::VieNeuHeads;
use crate::prompt::{VieNeuPromptConfig, build_prompt};
use crate::tokenizer::VieNeuTokenizer;
use crate::voice::{VieNeuVoiceStore, VoiceInfo};
use crate::wav::write_wav_mono_f32;

const HIDDEN: usize = 768;
const N_VQ: usize = 16;

const BACKBONE_LAYERS: usize = 12;
const BACKBONE_HEADS: usize = 4;
const BACKBONE_HEAD_DIM: usize = 64;

const ACOUSTIC_HEADS: usize = 8;
const ACOUSTIC_HEAD_DIM: usize = 96;

const SGS: i64 = 5;
const EOS: usize = 6;

const SAMPLE_RATE: u32 = 48_000;

#[derive(Debug)]
pub enum EngineError {
    InvalidConfiguration(String),
    UnknownVoice(String),
    Io(String),
    Model(String),
    Tensor(String),
    Generation(String),
}

impl std::fmt::Display for EngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidConfiguration(x) => {
                write!(f, "Invalid configuration: {x}")
            }
            Self::UnknownVoice(x) => {
                write!(f, "Unknown voice: {x}")
            }
            Self::Io(x) => {
                write!(f, "I/O error: {x}")
            }
            Self::Model(x) => {
                write!(f, "Model error: {x}")
            }
            Self::Tensor(x) => {
                write!(f, "Tensor error: {x}")
            }
            Self::Generation(x) => {
                write!(f, "Generation error: {x}")
            }
        }
    }
}

impl std::error::Error for EngineError {}

impl From<std::io::Error> for EngineError {
    fn from(value: std::io::Error) -> Self {
        Self::Io(value.to_string())
    }
}

pub struct SynthesisResult {
    pub samples: Vec<f32>,
    pub sample_rate: u32,
    pub frames_generated: usize,
    pub eos_reached: bool,
    pub cache_hit: bool,
}

impl SynthesisResult {
    pub fn duration_seconds(&self) -> f32 {
        self.samples.len() as f32 / self.sample_rate as f32
    }

    pub fn write_wav<P: AsRef<Path>>(&self, path: P) -> Result<(), EngineError> {
        write_wav_mono_f32(path, &self.samples, self.sample_rate).map_err(EngineError::from)
    }
}

struct BackboneState {
    k: Vec<Array4<f32>>,
    v: Vec<Array4<f32>>,
    hidden: Vec<f32>,
}

pub struct VieNeuEngine {
    tokenizer: VieNeuTokenizer,
    g2p: G2PEngine,
    heads: VieNeuHeads,
    voices: VieNeuVoiceStore,

    prefill: Session,
    backbone: Session,
    acoustic: Session,
    codec: Session,

    default_config: SynthesisConfig,
    cache: Option<TtsCache>,
}

impl VieNeuEngine {
    pub fn set_cache_directory(&mut self, directory: impl AsRef<Path>) -> Result<(), EngineError> {
        let directory = directory.as_ref();

        let cache = TtsCache::new(directory).map_err(|e| EngineError::Io(e.to_string()))?;

        let removed = cache
            .purge_older_than(crate::cache::CACHE_MAX_AGE)
            .map_err(|e| EngineError::Io(e.to_string()))?;

        if removed > 0 {
            eprintln!("VieNeu: removed {} expired cache entries", removed);
        }

        self.cache = Some(cache);

        Ok(())
    }

    pub fn clear_cache(&mut self) -> Result<(), EngineError> {
        if let Some(cache) = &self.cache {
            std::fs::remove_dir_all(&cache.directory)
                .map_err(|e| EngineError::Io(e.to_string()))?;

            std::fs::create_dir_all(&cache.directory)
                .map_err(|e| EngineError::Io(e.to_string()))?;
        }

        Ok(())
    }

    pub fn clear_cached_text(&mut self, text: &str, voice_id: &str) -> Result<bool, EngineError> {
        let cache = match &self.cache {
            Some(cache) => cache,
            None => {
                return Ok(false);
            }
        };

        let config = self.default_config.clone();

        cache
            .remove(text, voice_id, &config)
            .map_err(EngineError::from)
    }

    pub fn cached_audio_path(&self, text: &str, voice_id: &str) -> Option<PathBuf> {
        let cache = self.cache.as_ref()?;

        let config = self.default_config.clone();

        cache.existing_path(text, voice_id, &config)
    }

    pub fn from_assets_root(assets_root: impl AsRef<Path>) -> Result<Self, EngineError> {
        Self::from_assets_root_with_optional_ort(assets_root, None)
    }

    pub fn from_assets_root_with_ort(
        assets_root: impl AsRef<Path>,
        ort_path: impl AsRef<Path>,
    ) -> Result<Self, EngineError> {
        let assets_root = assets_root.as_ref();
        let ort_path = ort_path.as_ref();

        eprintln!("VieNeu Rust: from_assets_root_with_ort() START");
        eprintln!("VieNeu Rust: assets_root = {}", assets_root.display());
        eprintln!("VieNeu Rust: ort_path = {}", ort_path.display());

        let model_dir = assets_root.join("vieneu/model");
        let codec_dir = assets_root.join("vieneu/codec");
        let voices_path = assets_root.join("vieneu/voices_v3_turbo.json");
        let dict_path = assets_root.join("sea-g2p/sea_g2p.bin");

        eprintln!("VieNeu Rust: calling new_with_ort()...");

        let engine =
            Self::new_with_ort(model_dir, codec_dir, voices_path, dict_path, Some(ort_path))?;

        eprintln!("VieNeu Rust: new_with_ort() returned");

        Ok(engine)
    }

    pub fn from_assets_root_with_optional_ort(
        assets_root: impl AsRef<Path>,
        ort_path: Option<&Path>,
    ) -> Result<Self, EngineError> {
        let assets_root = assets_root.as_ref();

        match ort_path {
            Some(path) => Self::from_assets_root_with_ort(assets_root, path),

            None => Self::from_assets_root(assets_root),
        }
    }

    pub fn new(
        model_dir: impl AsRef<Path>,
        codec_dir: impl AsRef<Path>,
        voices_path: impl AsRef<Path>,
        dict_path: impl AsRef<Path>,
    ) -> Result<Self, EngineError> {
        Self::new_with_ort(model_dir, codec_dir, voices_path, dict_path, None)
    }

    pub fn new_with_ort(
        model_dir: impl AsRef<Path>,
        codec_dir: impl AsRef<Path>,
        voices_path: impl AsRef<Path>,
        dict_path: impl AsRef<Path>,
        ort_path: Option<&Path>,
    ) -> Result<Self, EngineError> {
        eprintln!("VieNeu Rust: new_with_ort() START");

        let model_dir = model_dir.as_ref();
        let codec_dir = codec_dir.as_ref();

        eprintln!("VieNeu Rust: model_dir = {}", model_dir.display());
        eprintln!("VieNeu Rust: codec_dir = {}", codec_dir.display());

        let tokenizer_path = model_dir.join("tokenizer.json");
        let heads_path = model_dir.join("vieneu_heads.json");
        let prefill_path = model_dir.join("vieneu_prefill.onnx");
        let backbone_path = model_dir.join("vieneu_decode_step.onnx");
        let acoustic_path = model_dir.join("vieneu_acoustic_cached.onnx");

        let codec_path = codec_dir.join("moss_audio_tokenizer_decode_full.onnx");

        eprintln!("VieNeu Rust: checking model files...");

        Self::check_file(&tokenizer_path)?;
        Self::check_file(&heads_path)?;
        Self::check_file(&prefill_path)?;
        Self::check_file(&backbone_path)?;
        Self::check_file(&acoustic_path)?;
        Self::check_file(&codec_path)?;

        eprintln!("VieNeu Rust: all model files exist");

        eprintln!("VieNeu Rust: preloading ONNX Runtime...");

        match ort_path {
            Some(path) => {
                eprintln!("VieNeu Rust: using explicit ORT path = {}", path.display());

                Self::preload_onnxruntime_from_path(path)?;
            }

            None => {
                eprintln!("VieNeu Rust: using default ORT discovery");

                Self::preload_onnxruntime()?;
            }
        }

        eprintln!("VieNeu Rust: ONNX Runtime preloaded");

        eprintln!("VieNeu Rust: loading tokenizer...");

        let tokenizer =
            VieNeuTokenizer::from_file(&tokenizer_path).map_err(EngineError::Generation)?;

        eprintln!("VieNeu Rust: tokenizer loaded");

        eprintln!("VieNeu Rust: loading heads...");

        let heads = VieNeuHeads::from_json(&heads_path).map_err(EngineError::Generation)?;

        eprintln!("VieNeu Rust: heads loaded");

        eprintln!("VieNeu Rust: loading voices...");

        let voices = VieNeuVoiceStore::from_file(voices_path).map_err(EngineError::Generation)?;

        eprintln!("VieNeu Rust: voices loaded");

        let dict_path = dict_path.as_ref();

        eprintln!("VieNeu Rust: G2P dictionary = {}", dict_path.display());

        Self::check_file(dict_path)?;

        eprintln!("VieNeu Rust: loading G2P...");

        let g2p = G2PEngine::new(dict_path.to_str().ok_or_else(|| {
            EngineError::Io(format!(
                "Invalid G2P dictionary path: {}",
                dict_path.display()
            ))
        })?)
        .map_err(|e| EngineError::Generation(format!("Could not load G2P dictionary: {e}")))?;

        eprintln!("VieNeu Rust: G2P loaded");

        eprintln!("VieNeu Rust: creating prefill ONNX session...");

        let prefill = Self::create_session(&prefill_path)?;

        eprintln!("VieNeu Rust: prefill session created");

        eprintln!("VieNeu Rust: creating backbone ONNX session...");

        let backbone = Self::create_session(&backbone_path)?;

        eprintln!("VieNeu Rust: backbone session created");

        eprintln!("VieNeu Rust: creating acoustic ONNX session...");

        let acoustic = Self::create_session(&acoustic_path)?;

        eprintln!("VieNeu Rust: acoustic session created");

        eprintln!("VieNeu Rust: creating codec ONNX session...");

        let codec = Self::create_session(&codec_path)?;

        eprintln!("VieNeu Rust: codec session created");

        eprintln!("VieNeu Rust: new_with_ort() COMPLETE");

        Ok(Self {
            tokenizer,
            g2p,
            heads,
            voices,
            prefill,
            backbone,
            acoustic,
            codec,
            cache: None,
            default_config: SynthesisConfig::default(),
        })
    }

    fn check_file(path: &Path) -> Result<(), EngineError> {
        if !path.is_file() {
            return Err(EngineError::Io(format!(
                "Required file does not exist: {}",
                path.display()
            )));
        }

        Ok(())
    }

    fn preload_onnxruntime() -> Result<(), EngineError> {
        // ---------------------------------------------------------
        // 1. Prefer the ONNX Runtime bundled inside the macOS app.
        //
        // Flutter macOS executable:
        //
        //   MyApp.app/
        //     Contents/
        //       MacOS/
        //         MyApp
        //       Frameworks/
        //         libonnxruntime.1.24.4.dylib
        //
        // For command-line Rust tests, this bundled path does not
        // exist, so we fall back to ORT_DYLIB_PATH below.
        // ---------------------------------------------------------

        if let Ok(executable) = std::env::current_exe() {
            if let Some(contents) = executable.parent().and_then(|p| p.parent()) {
                let bundled = contents.join("Frameworks/libonnxruntime.1.24.4.dylib");

                if bundled.is_file() {
                    return ort::util::preload_dylib(&bundled).map_err(|e| {
                        EngineError::Model(format!(
                            "Could not load bundled ONNX Runtime {}: {e}",
                            bundled.display()
                        ))
                    });
                }
            }
        }

        // ---------------------------------------------------------
        // 2. Development fallback.
        //
        // This is used by cargo run / cargo test on the command
        // line, where ORT_DYLIB_PATH points to the Python
        // virtualenv's ONNX Runtime dylib.
        // ---------------------------------------------------------

        let path = std::env::var("ORT_DYLIB_PATH").map_err(|_| {
            EngineError::Model(format!(
                "Could not find bundled ONNX Runtime and \
                        ORT_DYLIB_PATH is not set"
            ))
        })?;

        let path = Path::new(&path);

        if !path.is_file() {
            return Err(EngineError::Model(format!(
                "ONNX Runtime dylib does not exist: {}",
                path.display()
            )));
        }

        ort::util::preload_dylib(path).map_err(|e| {
            EngineError::Model(format!(
                "Could not load ONNX Runtime {}: {e}",
                path.display()
            ))
        })?;

        Ok(())
    }

    fn preload_onnxruntime_from_path(path: &Path) -> Result<(), EngineError> {
        if !path.is_file() {
            return Err(EngineError::Model(format!(
                "ONNX Runtime dylib does not exist: {}",
                path.display()
            )));
        }

        eprintln!(
            "VieNeu Rust: initializing ONNX Runtime from explicit path = {}",
            path.display()
        );

        ort::init_from(path).map_err(|e| {
            EngineError::Model(format!(
                "Could not initialize ONNX Runtime from {}: {e}",
                path.display()
            ))
        })?;

        eprintln!("VieNeu Rust: ONNX Runtime initialized from explicit path");

        Ok(())
    }

    fn create_session(path: &Path) -> Result<Session, EngineError> {
        eprintln!("VieNeu Rust: creating ONNX session: {}", path.display());

        let mut builder = Session::builder().map_err(|e| EngineError::Model(e.to_string()))?;

        builder = builder
            .with_optimization_level(GraphOptimizationLevel::Disable)
            .map_err(|e| EngineError::Model(e.to_string()))?;

        builder = builder
            .with_inter_threads(1)
            .map_err(|e| EngineError::Model(e.to_string()))?;

        builder = builder
            .with_intra_threads(1)
            .map_err(|e| EngineError::Model(e.to_string()))?;

        builder = builder
            .with_intra_op_spinning(false)
            .map_err(|e| EngineError::Model(e.to_string()))?;

        builder = builder
            .with_execution_providers([ep::CPU::default().build()])
            .map_err(|e| EngineError::Model(e.to_string()))?;

        let session = builder
            .commit_from_file(path)
            .map_err(|e| EngineError::Model(e.to_string()))?;

        eprintln!("VieNeu Rust: ONNX session ready: {}", path.display());

        Ok(session)
    }

    // =========================================================
    // UI-facing voice API
    // =========================================================

    pub fn voices(&self) -> Vec<VoiceInfo> {
        self.voices.list()
    }

    pub fn has_voice(&self, voice_id: &str) -> bool {
        self.voices.contains(voice_id)
    }

    pub fn default_config(&self) -> SynthesisConfig {
        self.default_config.clone()
    }

    pub fn set_default_config(&mut self, config: SynthesisConfig) -> Result<(), EngineError> {
        config
            .validate()
            .map_err(EngineError::InvalidConfiguration)?;

        self.default_config = config;

        Ok(())
    }

    // =========================================================
    // Main public synthesis entry point for now.
    //
    // The G2P/text wrapper will call this.
    // =========================================================

    pub fn synthesize_text(
        &mut self,
        text: &str,
        voice_id: &str,
        config: Option<&SynthesisConfig>,
    ) -> Result<SynthesisResult, EngineError> {
        let config = config
            .cloned()
            .unwrap_or_else(|| self.default_config.clone());

        config
            .validate()
            .map_err(EngineError::InvalidConfiguration)?;

        // -----------------------------------------------------
        // Check cache
        // -----------------------------------------------------

        let cached = if let Some(cache) = self.cache.as_ref() {
            cache
                .load(text, voice_id, &config)
                .map_err(EngineError::Io)?
        } else {
            None
        };

        if let Some((samples, sample_rate)) = cached {
            return Ok(SynthesisResult {
                samples,
                sample_rate,
                frames_generated: 0,
                eos_reached: true,
                cache_hit: true,
            });
        }

        // -----------------------------------------------------
        // G2P
        // -----------------------------------------------------

        let phonemes = self.g2p.phonemize(text);

        if phonemes.trim().is_empty() {
            return Err(EngineError::Generation(
                "G2P produced an empty phoneme string".to_string(),
            ));
        }

        // -----------------------------------------------------
        // VieNeu synthesis
        // -----------------------------------------------------

        let result = self.synthesize_phonemes(&phonemes, voice_id, Some(&config))?;

        if result.eos_reached {
            if let Some(cache) = &self.cache {
                cache
                    .store(text, voice_id, &config, &result)
                    .map_err(EngineError::Io)?;
            }
        } else {
            eprintln!("VieNeu: NOT caching synthesis result because EOS was not reached");
        }

        Ok(result)
    }

    pub fn synthesize_phonemes(
        &mut self,
        phonemes: &str,
        voice_id: &str,
        config: Option<&SynthesisConfig>,
    ) -> Result<SynthesisResult, EngineError> {
        let config = config
            .cloned()
            .unwrap_or_else(|| self.default_config.clone());

        config
            .validate()
            .map_err(EngineError::InvalidConfiguration)?;

        let (speaker_emb, ref_codes) = {
            let voice = self
                .voices
                .get(voice_id)
                .map_err(|_| EngineError::UnknownVoice(voice_id.to_string()))?;

            (voice.speaker_emb.clone(), voice.codes.clone())
        };

        let phone_ids = self
            .tokenizer
            .encode(phonemes)
            .map_err(EngineError::Generation)?;

        let prompt = build_prompt(&phone_ids, &ref_codes, VieNeuPromptConfig::default())
            .map_err(EngineError::Generation)?;

        // -----------------------------------------------------
        // Speaker anchor
        // -----------------------------------------------------

        let anchor = self
            .heads
            .speaker_anchor(&speaker_emb)
            .map_err(EngineError::Generation)?;

        let prompt_embeddings = self
            .heads
            .embed_rows(&prompt, Some(&anchor))
            .map_err(EngineError::Generation)?;

        let prompt_input =
            Array3::from_shape_vec((1, prompt.rows_count, HIDDEN), prompt_embeddings)
                .map_err(|e| EngineError::Tensor(e.to_string()))?;

        // -----------------------------------------------------
        // Prefill
        // -----------------------------------------------------

        let mut state = self.prefill(&prompt_input, prompt.rows_count)?;

        let mut frames: Vec<Vec<i32>> = Vec::new();

        let mut eos_reached = false;

        // -----------------------------------------------------
        // Autoregressive generation
        // -----------------------------------------------------

        for _frame_index in 0..config.max_new_frames {
            let (codes, eos) = self.generate_frame(&state.hidden, &config)?;

            frames.push(codes.iter().map(|&x| x as i32).collect());

            if eos {
                eos_reached = true;
                break;
            }

            // Feed generated frame into
            // the backbone.
            state = self.backbone_step(
                state,
                &frames
                    .last()
                    .unwrap()
                    .iter()
                    .map(|&x| x as usize)
                    .collect::<Vec<_>>(),
                &anchor,
                prompt.rows_count,
                frames.len() - 1,
            )?;
        }

        // -----------------------------------------------------
        // Decode all generated VQ frames
        // -----------------------------------------------------

        let samples = self.decode_frames(&frames)?;

        Ok(SynthesisResult {
            samples,
            sample_rate: SAMPLE_RATE,
            frames_generated: frames.len(),
            eos_reached,
            cache_hit: false,
        })
    }

    // =========================================================
    // Prefill
    // =========================================================

    fn prefill(
        &mut self,
        input: &Array3<f32>,
        prompt_length: usize,
    ) -> Result<BackboneState, EngineError> {
        let outputs = self
            .prefill
            .run(ort::inputs![
                "inputs_embeds" =>
                    TensorRef::from_array_view(
                        input
                    )
                    .map_err(|e| {
                        EngineError::Tensor(
                            e.to_string()
                        )
                    })?,
            ])
            .map_err(|e| EngineError::Model(e.to_string()))?;

        if outputs.len() != 25 {
            return Err(EngineError::Model(format!(
                "Expected 25 prefill outputs, got {}",
                outputs.len()
            )));
        }

        let hidden = outputs[0]
            .try_extract_tensor::<f32>()
            .map_err(|e| EngineError::Tensor(e.to_string()))?;

        let start = (prompt_length - 1) * HIDDEN;

        let last_hidden = hidden.1[start..start + HIDDEN].to_vec();

        let mut k = Vec::with_capacity(BACKBONE_LAYERS);

        let mut v = Vec::with_capacity(BACKBONE_LAYERS);

        for i in 0..BACKBONE_LAYERS {
            let value = outputs[1 + i]
                .try_extract_tensor::<f32>()
                .map_err(|e| EngineError::Tensor(e.to_string()))?;

            k.push(
                Array4::from_shape_vec(
                    (1, BACKBONE_HEADS, prompt_length, BACKBONE_HEAD_DIM),
                    value.1.to_vec(),
                )
                .map_err(|e| EngineError::Tensor(e.to_string()))?,
            );
        }

        for i in 0..BACKBONE_LAYERS {
            let value = outputs[13 + i]
                .try_extract_tensor::<f32>()
                .map_err(|e| EngineError::Tensor(e.to_string()))?;

            v.push(
                Array4::from_shape_vec(
                    (1, BACKBONE_HEADS, prompt_length, BACKBONE_HEAD_DIM),
                    value.1.to_vec(),
                )
                .map_err(|e| EngineError::Tensor(e.to_string()))?,
            );
        }

        Ok(BackboneState {
            k,
            v,
            hidden: last_hidden,
        })
    }

    // =========================================================
    // One complete acoustic frame
    // =========================================================

    fn generate_frame(
        &mut self,
        h: &[f32],
        config: &SynthesisConfig,
    ) -> Result<(Vec<usize>, bool), EngineError> {
        let sgs = self.heads.text_embedding(SGS as usize);

        let mut tokens = Vec::with_capacity(HIDDEN * 2);

        tokens.extend_from_slice(h);

        tokens.extend_from_slice(sgs);

        let input = Array3::from_shape_vec((1, 2, HIDDEN), tokens)
            .map_err(|e| EngineError::Tensor(e.to_string()))?;

        let positions = Array2::from_shape_vec((1, 2), vec![0i64, 1i64])
            .map_err(|e| EngineError::Tensor(e.to_string()))?;

        let empty_k = Array4::<f32>::zeros((1, ACOUSTIC_HEADS, 0, ACOUSTIC_HEAD_DIM));

        let empty_v = Array4::<f32>::zeros((1, ACOUSTIC_HEADS, 0, ACOUSTIC_HEAD_DIM));
        let (slot0, first_hidden, mut acoustic_k, mut acoustic_v) = {
            let outputs = self
                .acoustic
                .run(ort::inputs![
                    "token_emb" =>
                        TensorRef::from_array_view(
                            &input
                        )
                        .map_err(|e| {
                            EngineError::Tensor(
                                e.to_string()
                            )
                        })?,

                    "position_ids" =>
                        TensorRef::from_array_view(
                            &positions
                        )
                        .map_err(|e| {
                            EngineError::Tensor(
                                e.to_string()
                            )
                        })?,

                    "past_k_0" =>
                        TensorRef::from_array_view(
                            &empty_k
                        )
                        .map_err(|e| {
                            EngineError::Tensor(
                                e.to_string()
                            )
                        })?,

                    "past_v_0" =>
                        TensorRef::from_array_view(
                            &empty_v
                        )
                        .map_err(|e| {
                            EngineError::Tensor(
                                e.to_string()
                            )
                        })?,
                ])
                .map_err(|e| EngineError::Model(e.to_string()))?;

            let hidden = outputs[0]
                .try_extract_tensor::<f32>()
                .map_err(|e| EngineError::Tensor(e.to_string()))?;

            let slot0 = hidden.1[0..HIDDEN].to_vec();

            let first_hidden = hidden.1[HIDDEN..2 * HIDDEN].to_vec();

            let first_k = outputs[1]
                .try_extract_tensor::<f32>()
                .map_err(|e| EngineError::Tensor(e.to_string()))?;

            let first_v = outputs[2]
                .try_extract_tensor::<f32>()
                .map_err(|e| EngineError::Tensor(e.to_string()))?;

            let acoustic_k = Array4::from_shape_vec(
                (1, ACOUSTIC_HEADS, 2, ACOUSTIC_HEAD_DIM),
                first_k.1.to_vec(),
            )
            .map_err(|e| EngineError::Tensor(e.to_string()))?;

            let acoustic_v = Array4::from_shape_vec(
                (1, ACOUSTIC_HEADS, 2, ACOUSTIC_HEAD_DIM),
                first_v.1.to_vec(),
            )
            .map_err(|e| EngineError::Tensor(e.to_string()))?;

            (slot0, first_hidden, acoustic_k, acoustic_v)
        };

        let mut codes = Vec::with_capacity(N_VQ);

        let code0 = self.sample_audio(0, &first_hidden, config)?;

        codes.push(code0);

        // -----------------------------------------------------
        // Remaining channels
        // -----------------------------------------------------

        for ch in 1..N_VQ {
            let previous = codes[ch - 1];

            let embedding = self.heads.audio_embedding(ch - 1, previous);

            let input = Array3::from_shape_vec((1, 1, HIDDEN), embedding.to_vec())
                .map_err(|e| EngineError::Tensor(e.to_string()))?;

            let positions = Array2::from_shape_vec((1, 1), vec![(ch + 1) as i64])
                .map_err(|e| EngineError::Tensor(e.to_string()))?;

            let (hidden_vec, new_k, new_v) = {
                let outputs = self
                    .acoustic
                    .run(ort::inputs![
                        "token_emb" =>
                            TensorRef::from_array_view(
                                &input
                            )
                            .map_err(|e| {
                                EngineError::Tensor(
                                    e.to_string()
                                )
                            })?,

                        "position_ids" =>
                            TensorRef::from_array_view(
                                &positions
                            )
                            .map_err(|e| {
                                EngineError::Tensor(
                                    e.to_string()
                                )
                            })?,

                        "past_k_0" =>
                            TensorRef::from_array_view(
                                &acoustic_k
                            )
                            .map_err(|e| {
                                EngineError::Tensor(
                                    e.to_string()
                                )
                            })?,

                        "past_v_0" =>
                            TensorRef::from_array_view(
                                &acoustic_v
                            )
                            .map_err(|e| {
                                EngineError::Tensor(
                                    e.to_string()
                                )
                            })?,
                    ])
                    .map_err(|e| EngineError::Model(e.to_string()))?;

                let hidden = outputs[0]
                    .try_extract_tensor::<f32>()
                    .map_err(|e| EngineError::Tensor(e.to_string()))?;

                let k = outputs[1]
                    .try_extract_tensor::<f32>()
                    .map_err(|e| EngineError::Tensor(e.to_string()))?;

                let v = outputs[2]
                    .try_extract_tensor::<f32>()
                    .map_err(|e| EngineError::Tensor(e.to_string()))?;

                let hidden_vec = hidden.1.to_vec();

                let new_k = Array4::from_shape_vec(
                    (1, ACOUSTIC_HEADS, ch + 2, ACOUSTIC_HEAD_DIM),
                    k.1.to_vec(),
                )
                .map_err(|e| EngineError::Tensor(e.to_string()))?;

                let new_v = Array4::from_shape_vec(
                    (1, ACOUSTIC_HEADS, ch + 2, ACOUSTIC_HEAD_DIM),
                    v.1.to_vec(),
                )
                .map_err(|e| EngineError::Tensor(e.to_string()))?;

                (hidden_vec, new_k, new_v)
            };

            // `outputs` is dropped before we borrow `self` again.
            acoustic_k = new_k;
            acoustic_v = new_v;

            let code = self.sample_audio(ch, &hidden_vec, config)?;

            codes.push(code);
        }

        // -----------------------------------------------------
        // EOS
        // -----------------------------------------------------

        let mut text_logits = vec![0.0f32; self.heads.text_vocab];

        for token in 0..self.heads.text_vocab {
            text_logits[token] = dot(&slot0, self.heads.text_embedding(token));
        }

        let eos_token = argmax(&text_logits);

        Ok((codes, eos_token == EOS))
    }

    // =========================================================
    // Audio sampling
    // =========================================================

    fn sample_audio(
        &self,
        channel: usize,
        hidden: &[f32],
        config: &SynthesisConfig,
    ) -> Result<usize, EngineError> {
        let mut logits = vec![0.0f32; self.heads.audio_vocab];

        for code in 0..self.heads.audio_vocab {
            logits[code] = dot(hidden, self.heads.audio_embedding(channel, code));
        }

        // Deterministic mode.
        if config.temperature <= 0.0 {
            return Ok(argmax(&logits));
        }

        // Repetition history is added to the
        // production engine after this core
        // implementation is validated.
        //
        // For now we implement temperature,
        // top-k and top-p exactly as the basic
        // sampler requires.

        logits = logits.into_iter().map(|x| x / config.temperature).collect();

        let vocab = logits.len();

        let k = config.top_k.min(vocab);

        let mut indices: Vec<usize> = (0..vocab).collect();

        indices.sort_by(|&a, &b| {
            logits[b]
                .partial_cmp(&logits[a])
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        indices.truncate(k);

        let max_logit = indices
            .iter()
            .map(|&i| logits[i])
            .fold(f32::NEG_INFINITY, f32::max);

        let mut probabilities = Vec::with_capacity(indices.len());

        let mut total = 0.0f32;

        for &index in &indices {
            let p = (logits[index] - max_logit).exp();

            probabilities.push(p);

            total += p;
        }

        if total <= 0.0 || !total.is_finite() {
            return Ok(indices[0]);
        }

        for p in &mut probabilities {
            *p /= total;
        }

        // Top-p filtering.
        if config.top_p < 1.0 {
            let mut cumulative = 0.0f32;

            let mut keep = probabilities.len();

            for (i, &p) in probabilities.iter().enumerate() {
                cumulative += p;

                if cumulative >= config.top_p {
                    keep = i + 1;
                    break;
                }
            }

            indices.truncate(keep);

            probabilities.truncate(keep);

            let sum = probabilities.iter().sum::<f32>();

            if sum > 0.0 {
                for p in &mut probabilities {
                    *p /= sum;
                }
            }
        }

        // Until we expose a seeded RNG in the
        // public API, use the highest-probability
        // candidate. This preserves deterministic
        // behavior while the configuration API is
        // already ready for real sampling.
        Ok(indices[0])
    }

    // =========================================================
    // Backbone feedback
    // =========================================================

    fn backbone_step(
        &mut self,
        state: BackboneState,
        codes: &[usize],
        anchor: &[f32],
        prompt_length: usize,
        frame_index: usize,
    ) -> Result<BackboneState, EngineError> {
        if codes.len() != N_VQ {
            return Err(EngineError::Generation(format!(
                "Expected {} codes, got {}",
                N_VQ,
                codes.len()
            )));
        }

        // -----------------------------------------------------
        // text embedding
        // -----------------------------------------------------

        let mut embedding = self.heads.text_embedding(SGS as usize).to_vec();

        // -----------------------------------------------------
        // all 16 audio embeddings
        // -----------------------------------------------------

        for ch in 0..N_VQ {
            let audio = self.heads.audio_embedding(ch, codes[ch]);

            for h in 0..HIDDEN {
                embedding[h] += audio[h];
            }
        }

        // -----------------------------------------------------
        // speaker anchor
        // -----------------------------------------------------

        for h in 0..HIDDEN {
            embedding[h] += anchor[h];
        }

        let input = Array3::from_shape_vec((1, 1, HIDDEN), embedding)
            .map_err(|e| EngineError::Tensor(e.to_string()))?;

        let position = Array2::from_shape_vec((1, 1), vec![(prompt_length + frame_index) as i64])
            .map_err(|e| EngineError::Tensor(e.to_string()))?;

        let mut inputs = ort::inputs![
            "inputs_embeds" =>
                TensorRef::from_array_view(
                    &input
                )
                .map_err(|e| {
                    EngineError::Tensor(
                        e.to_string()
                    )
                })?,

            "position_ids" =>
                TensorRef::from_array_view(
                    &position
                )
                .map_err(|e| {
                    EngineError::Tensor(
                        e.to_string()
                    )
                })?,
        ];

        for i in 0..BACKBONE_LAYERS {
            inputs.push((
                format!("past_k_{i}").into(),
                TensorRef::from_array_view(&state.k[i])
                    .map_err(|e| EngineError::Tensor(e.to_string()))?
                    .into(),
            ));

            inputs.push((
                format!("past_v_{i}").into(),
                TensorRef::from_array_view(&state.v[i])
                    .map_err(|e| EngineError::Tensor(e.to_string()))?
                    .into(),
            ));
        }

        let (next_hidden, next_k, next_v) = {
            let outputs = self
                .backbone
                .run(inputs)
                .map_err(|e| EngineError::Model(e.to_string()))?;

            if outputs.len() != 25 {
                return Err(EngineError::Model(format!(
                    "Expected 25 decode outputs, got {}",
                    outputs.len()
                )));
            }

            let hidden = outputs[0]
                .try_extract_tensor::<f32>()
                .map_err(|e| EngineError::Tensor(e.to_string()))?;

            let next_hidden = hidden.1.to_vec();

            let new_length = prompt_length + frame_index + 1;

            let mut next_k = Vec::with_capacity(BACKBONE_LAYERS);

            let mut next_v = Vec::with_capacity(BACKBONE_LAYERS);

            for i in 0..BACKBONE_LAYERS {
                let value = outputs[1 + i]
                    .try_extract_tensor::<f32>()
                    .map_err(|e| EngineError::Tensor(e.to_string()))?;

                next_k.push(
                    Array4::from_shape_vec(
                        (1, BACKBONE_HEADS, new_length, BACKBONE_HEAD_DIM),
                        value.1.to_vec(),
                    )
                    .map_err(|e| EngineError::Tensor(e.to_string()))?,
                );
            }

            for i in 0..BACKBONE_LAYERS {
                let value = outputs[13 + i]
                    .try_extract_tensor::<f32>()
                    .map_err(|e| EngineError::Tensor(e.to_string()))?;

                next_v.push(
                    Array4::from_shape_vec(
                        (1, BACKBONE_HEADS, new_length, BACKBONE_HEAD_DIM),
                        value.1.to_vec(),
                    )
                    .map_err(|e| EngineError::Tensor(e.to_string()))?,
                );
            }

            (next_hidden, next_k, next_v)
        };

        Ok(BackboneState {
            k: next_k,
            v: next_v,
            hidden: next_hidden,
        })
    }

    // =========================================================
    // MOSS codec
    // =========================================================

    fn decode_frames(&mut self, frames: &[Vec<i32>]) -> Result<Vec<f32>, EngineError> {
        if frames.is_empty() {
            return Ok(Vec::new());
        }

        for (index, frame) in frames.iter().enumerate() {
            if frame.len() != N_VQ {
                return Err(EngineError::Generation(format!(
                    "Frame {} contains {} codes; expected {}",
                    index,
                    frame.len(),
                    N_VQ
                )));
            }
        }

        let mut flat = Vec::with_capacity(frames.len() * N_VQ);

        for frame in frames {
            flat.extend_from_slice(frame);
        }

        let codes = Array3::from_shape_vec((1, frames.len(), N_VQ), flat)
            .map_err(|e| EngineError::Tensor(e.to_string()))?;

        let lengths = Array1::from_vec(vec![frames.len() as i32]);

        let (audio_shape, audio_data) = {
            let outputs = self
                .codec
                .run(ort::inputs![
                    "audio_codes" =>
                        TensorRef::from_array_view(
                            &codes
                        )
                        .map_err(|e| {
                            EngineError::Tensor(
                                e.to_string()
                            )
                        })?,

                    "audio_code_lengths" =>
                        TensorRef::from_array_view(
                            &lengths
                        )
                        .map_err(|e| {
                            EngineError::Tensor(
                                e.to_string()
                            )
                        })?,
                ])
                .map_err(|e| EngineError::Model(e.to_string()))?;

            if outputs.len() != 2 {
                return Err(EngineError::Model(format!(
                    "Expected 2 codec outputs, got {}",
                    outputs.len()
                )));
            }

            let audio = outputs[0]
                .try_extract_tensor::<f32>()
                .map_err(|e| EngineError::Tensor(e.to_string()))?;

            let shape = audio.0.to_vec();

            let data = audio.1.to_vec();

            (shape, data)
        };

        // `outputs` and its tensor views are now dropped.

        if audio_shape.len() != 3 {
            return Err(EngineError::Tensor(format!(
                "Expected rank-3 codec audio, got {:?}",
                audio_shape
            )));
        }

        let batch = audio_shape[0] as usize;

        let channels = audio_shape[1] as usize;

        let samples = audio_shape[2] as usize;

        if batch != 1 {
            return Err(EngineError::Tensor(format!(
                "Expected codec batch=1, got {}",
                batch
            )));
        }

        if audio_data.len() != channels * samples {
            return Err(EngineError::Tensor(format!(
                "Expected {} codec values, got {}",
                channels * samples,
                audio_data.len()
            )));
        }

        // Exactly mirrors:
        //
        // out[0][0].mean(0)
        //

        let mut wav = vec![0.0f32; samples];

        for channel in 0..channels {
            let start = channel * samples;

            for sample in 0..samples {
                wav[sample] += audio_data[start + sample];
            }
        }

        let inverse = 1.0f32 / channels as f32;

        for sample in 0..samples {
            wav[sample] *= inverse;
        }

        Ok(wav)
    }
}

fn dot(a: &[f32], b: &[f32]) -> f32 {
    debug_assert_eq!(a.len(), b.len());

    let mut total = 0.0f32;

    for i in 0..a.len() {
        total += a[i] * b[i];
    }

    total
}

fn argmax(values: &[f32]) -> usize {
    let mut best = 0usize;

    let mut best_value = f32::NEG_INFINITY;

    for (index, &value) in values.iter().enumerate() {
        if value > best_value {
            best_value = value;

            best = index;
        }
    }

    best
}
