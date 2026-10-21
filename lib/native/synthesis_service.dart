import 'vieneu_ffi.dart';

/// Operations the UI needs from the background synthesis engine.
///
/// The production implementation is [VieNeuSynthesisWorker]. Tests can provide
/// a fake without spawning an isolate or loading the native library.
abstract interface class SynthesisService {
  Future<List<VietnameseVoice>> initialize({
    required String assetsRoot,
    required String cacheRoot,
    String? ortPath,
    String? libraryPath,
  });

  Future<({String path, bool cacheHit})> synthesizeToWav({
    required String text,
    required String voiceId,
  });

  Future<String> previewSpeechText(String text);

  Future<void> clearCache();

  Future<bool> clearCachedText({required String text, required String voiceId});

  Future<void> dispose();
}
