import 'package:vietnamese_shadowing/native/synthesis_service.dart';
import 'package:vietnamese_shadowing/native/vieneu_ffi.dart';

class FakeSynthesisService implements SynthesisService {
  FakeSynthesisService({
    required this.voices,
    required this.wavPath,
    this.normalizedText = 'hôm nay bạn khỏe không?',
    this.cacheHit = false,
  });

  final List<VietnameseVoice> voices;
  final String wavPath;
  final String normalizedText;
  final bool cacheHit;

  int initializeCalls = 0;
  int synthesizeCalls = 0;
  int previewCalls = 0;
  int clearCacheCalls = 0;
  int disposeCalls = 0;
  final List<String> synthesizeVoiceIds = <String>[];
  final List<String> synthesizeTexts = <String>[];

  @override
  Future<List<VietnameseVoice>> initialize({
    required String assetsRoot,
    required String cacheRoot,
    String? ortPath,
    String? libraryPath,
  }) async {
    initializeCalls++;
    return voices;
  }

  @override
  Future<({String path, bool cacheHit})> synthesizeToWav({
    required String text,
    required String voiceId,
  }) async {
    synthesizeCalls++;
    synthesizeVoiceIds.add(voiceId);
    synthesizeTexts.add(text);
    return (path: wavPath, cacheHit: cacheHit);
  }

  @override
  Future<String> previewSpeechText(String text) async {
    previewCalls++;
    return normalizedText;
  }

  @override
  Future<void> clearCache() async {
    clearCacheCalls++;
  }

  @override
  Future<bool> clearCachedText({
    required String text,
    required String voiceId,
  }) async {
    return true;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}
