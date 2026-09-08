pub mod cache;
pub mod config;
pub mod embeddings;
pub mod engine;
pub mod prompt;
pub mod tokenizer;
pub mod voice;
pub mod wav;

use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use sea_g2p_rs::g2p::G2PEngine;

use crate::engine::VieNeuEngine;

// =========================================================
// Existing G2P native engine
// =========================================================

pub struct VieNeuNativeEngine {
    g2p: G2PEngine,
}

/// Create a native G2P engine.
///
/// `dict_path` must point to `sea_g2p.bin`.
#[unsafe(no_mangle)]
pub extern "C" fn vieneu_g2p_create(dict_path: *const c_char) -> *mut VieNeuNativeEngine {
    if dict_path.is_null() {
        return std::ptr::null_mut();
    }

    let dict_path = unsafe { CStr::from_ptr(dict_path) };

    let dict_path = match dict_path.to_str() {
        Ok(path) => path,
        Err(_) => return std::ptr::null_mut(),
    };

    let g2p = match G2PEngine::new(dict_path) {
        Ok(engine) => engine,
        Err(_) => return std::ptr::null_mut(),
    };

    Box::into_raw(Box::new(VieNeuNativeEngine { g2p }))
}

/// Phonemize Vietnamese text.
///
/// The returned string is allocated by Rust and must be
/// released using `vieneu_free_string()`.
#[unsafe(no_mangle)]
pub extern "C" fn vieneu_g2p_phonemize(
    engine: *mut VieNeuNativeEngine,
    text: *const c_char,
) -> *mut c_char {
    if engine.is_null() || text.is_null() {
        return std::ptr::null_mut();
    }

    let engine = unsafe { &*engine };

    let text = unsafe { CStr::from_ptr(text) };

    let text = match text.to_str() {
        Ok(value) => value,
        Err(_) => return std::ptr::null_mut(),
    };

    let phonemes = engine.g2p.phonemize(text);

    match CString::new(phonemes) {
        Ok(value) => value.into_raw(),

        Err(_) => std::ptr::null_mut(),
    }
}

/// Destroy the native G2P engine.
#[unsafe(no_mangle)]
pub extern "C" fn vieneu_g2p_destroy(engine: *mut VieNeuNativeEngine) {
    if engine.is_null() {
        return;
    }

    unsafe {
        drop(Box::from_raw(engine));
    }
}

// =========================================================
// Native VieNeu TTS engine
// =========================================================

pub struct VieNeuTtsNativeEngine {
    engine: VieNeuEngine,
}

/// Create the native VieNeu TTS engine.
///
/// `assets_root` should contain:
///
/// assets/
///   vieneu/model/
///   vieneu/codec/
///   vieneu/voices_v3_turbo.json
///   sea-g2p/sea_g2p.bin
///
/// `cache_root` is where generated WAV files are cached.
#[unsafe(no_mangle)]
pub extern "C" fn vieneu_tts_create(
    assets_root: *const c_char,
    cache_root: *const c_char,
    ort_path: *const c_char,
) -> *mut VieNeuTtsNativeEngine {
    if assets_root.is_null() || cache_root.is_null() || ort_path.is_null() {
        return std::ptr::null_mut();
    }

    let assets_root = unsafe { CStr::from_ptr(assets_root) };

    let cache_root = unsafe { CStr::from_ptr(cache_root) };

    let ort_path = unsafe { CStr::from_ptr(ort_path) };

    let assets_root = match assets_root.to_str() {
        Ok(value) => value,
        Err(_) => return std::ptr::null_mut(),
    };

    let cache_root = match cache_root.to_str() {
        Ok(value) => value,
        Err(_) => return std::ptr::null_mut(),
    };

    let ort_path = match ort_path.to_str() {
        Ok(value) => value,
        Err(_) => return std::ptr::null_mut(),
    };

    eprintln!("VieNeu native: calling from_assets_root_with_ort()...");

    let mut engine = match VieNeuEngine::from_assets_root_with_ort(assets_root, ort_path) {
        Ok(engine) => engine,
        Err(error) => {
            eprintln!("VieNeu native engine creation failed: {}", error);
            return std::ptr::null_mut();
        }
    };

    eprintln!("VieNeu native: from_assets_root_with_ort() returned");

    if let Err(error) = engine.set_cache_directory(cache_root) {
        eprintln!("VieNeu cache initialization failed: {}", error);

        return std::ptr::null_mut();
    }

    Box::into_raw(Box::new(VieNeuTtsNativeEngine { engine }))
}

/// Destroy the native VieNeu TTS engine.
#[unsafe(no_mangle)]
pub extern "C" fn vieneu_tts_destroy(engine: *mut VieNeuTtsNativeEngine) {
    if engine.is_null() {
        return;
    }

    unsafe {
        drop(Box::from_raw(engine));
    }
}

/// Synthesize Vietnamese text.
///
/// Returns a heap-allocated UTF-8 JSON string on success:
///
/// {
///   "path": "/path/to/cache/file.wav",
///   "cache_hit": true
/// }
///
/// Returns null on failure.
///
/// The returned string must be freed with
/// `vieneu_free_string()`.
#[unsafe(no_mangle)]
pub extern "C" fn vieneu_tts_synthesize_to_wav(
    engine: *mut VieNeuTtsNativeEngine,
    text: *const c_char,
    voice_id: *const c_char,
) -> *mut c_char {
    if engine.is_null() || text.is_null() || voice_id.is_null() {
        return std::ptr::null_mut();
    }

    let engine = unsafe { &mut *engine };

    let text = unsafe { CStr::from_ptr(text) };

    let voice_id = unsafe { CStr::from_ptr(voice_id) };

    let text = match text.to_str() {
        Ok(value) => value,
        Err(_) => {
            return std::ptr::null_mut();
        }
    };

    let voice_id = match voice_id.to_str() {
        Ok(value) => value,
        Err(_) => {
            return std::ptr::null_mut();
        }
    };

    let result = match engine.engine.synthesize_text(text, voice_id, None) {
        Ok(result) => result,

        Err(error) => {
            eprintln!("VieNeu native: synthesis failed: {}", error);

            return std::ptr::null_mut();
        }
    };

    eprintln!(
        "VieNeu native: synthesis result: \
         cache_hit={}, frames_generated={}, eos_reached={}",
        result.cache_hit, result.frames_generated, result.eos_reached
    );

    let cache_path = match engine.engine.cached_audio_path(text, voice_id) {
        Some(path) => path,

        None => {
            eprintln!(
                "VieNeu native: synthesis produced \
                     no cache file because EOS was not reached"
            );

            return std::ptr::null_mut();
        }
    };

    let response = serde_json::json!({
        "path": cache_path.to_string_lossy(),
        "cache_hit": result.cache_hit,
    });

    match CString::new(response.to_string()) {
        Ok(value) => value.into_raw(),

        Err(error) => {
            eprintln!(
                "VieNeu native: failed to create \
                 synthesis response: {}",
                error
            );

            std::ptr::null_mut()
        }
    }
}

/// Return the available voices as JSON.
///
/// The returned string must be freed with
/// `vieneu_free_string()`.
#[unsafe(no_mangle)]
pub extern "C" fn vieneu_tts_list_voices(engine: *mut VieNeuTtsNativeEngine) -> *mut c_char {
    if engine.is_null() {
        return std::ptr::null_mut();
    }

    let engine = unsafe { &mut *engine };

    let voices = engine.engine.voices();

    let json = match serde_json::to_string(&voices) {
        Ok(value) => value,
        Err(_) => return std::ptr::null_mut(),
    };

    match CString::new(json) {
        Ok(value) => value.into_raw(),

        Err(_) => std::ptr::null_mut(),
    }
}

/// Clear the TTS cache.
///
/// Returns 1 on success, 0 on failure.
#[unsafe(no_mangle)]
pub extern "C" fn vieneu_tts_clear_cache(engine: *mut VieNeuTtsNativeEngine) -> i32 {
    if engine.is_null() {
        return 0;
    }

    let engine = unsafe { &mut *engine };

    match engine.engine.clear_cache() {
        Ok(_) => 1,
        Err(_) => 0,
    }
}

/// Remove the cache entry for one text/voice combination.
///
/// Returns:
///   1 = cache entry removed
///   0 = no matching cache entry or failure
#[unsafe(no_mangle)]
pub extern "C" fn vieneu_tts_clear_cached_text(
    engine: *mut VieNeuTtsNativeEngine,
    text: *const c_char,
    voice_id: *const c_char,
) -> i32 {
    if engine.is_null() || text.is_null() || voice_id.is_null() {
        return 0;
    }

    let engine = unsafe { &mut *engine };

    let text = unsafe { CStr::from_ptr(text) };

    let voice_id = unsafe { CStr::from_ptr(voice_id) };

    let text = match text.to_str() {
        Ok(value) => value,
        Err(_) => return 0,
    };

    let voice_id = match voice_id.to_str() {
        Ok(value) => value,
        Err(_) => return 0,
    };

    match engine.engine.clear_cached_text(text, voice_id) {
        Ok(removed) => {
            eprintln!(
                "VieNeu native: clear cached text: \
                 voice={}, removed={}",
                voice_id, removed
            );

            if removed { 1 } else { 0 }
        }

        Err(error) => {
            eprintln!("VieNeu native: failed to clear cached text: {}", error);
            0
        }
    }
}

// =========================================================
// Common string deallocation
// =========================================================

/// Free a string returned by this library.
#[unsafe(no_mangle)]
pub extern "C" fn vieneu_free_string(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }

    unsafe {
        drop(CString::from_raw(ptr));
    }
}
