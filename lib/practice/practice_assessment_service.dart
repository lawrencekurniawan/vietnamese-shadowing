// ignore_for_file: prefer_initializing_formals

import '../library/wav_info.dart';
import 'practice_analyzer.dart';
import 'practice_feedback.dart';
import 'practice_speech_service.dart';

class PracticeAssessmentException implements Exception {
  const PracticeAssessmentException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Runs on-device transcription and pitch extraction, then compares the take
/// with the generated reference.
class PracticeAssessmentService {
  PracticeAssessmentService({
    required PracticeSpeechService speechService,
    PracticeAnalyzer analyzer = const PracticeAnalyzer(),
  }) : _speechService = speechService,
       _analyzer = analyzer;

  final PracticeSpeechService _speechService;
  final PracticeAnalyzer _analyzer;

  final Map<String, SpeechTranscript> _transcriptCache =
      <String, SpeechTranscript>{};
  final Map<String, List<PitchFrame>> _pitchCache =
      <String, List<PitchFrame>>{};

  Future<PracticeFeedback> assess({
    required String referenceText,
    required String referenceAudioPath,
    required String userAudioPath,
  }) async {
    final referenceFile = await WavInfo.readFile(referenceAudioPath);
    final userFile = await WavInfo.readFile(userAudioPath);

    if (referenceText.trim().isEmpty) {
      throw const PracticeAssessmentException('The reference text is missing.');
    }

    SpeechTranscript referenceTranscript;

    try {
      referenceTranscript = await _transcribe(referenceAudioPath);
    } on PracticeSpeechException {
      // Word matching can still use the written reference. Only timing and
      // tone guidance lose their reference anchors.
      referenceTranscript = SpeechTranscript(text: referenceText);
    }

    final userTranscript = await _transcribe(userAudioPath);
    final referencePitch = await _pitchOrEmpty(referenceAudioPath);
    final userPitch = await _pitchOrEmpty(userAudioPath);

    return _analyzer.analyze(
      referenceText: referenceText,
      referenceAudioPath: referenceAudioPath,
      userAudioPath: userAudioPath,
      referenceTranscript: referenceTranscript,
      userTranscript: userTranscript,
      referencePitch: referencePitch,
      userPitch: userPitch,
      referenceDurationSeconds: referenceFile.durationSeconds,
      userDurationSeconds: userFile.durationSeconds,
    );
  }

  Future<SpeechTranscript> _transcribe(String path) async {
    final cached = _transcriptCache[path];

    if (cached != null) {
      return cached;
    }

    final transcript = await _speechService.transcribe(path);

    if (_transcriptCache.length >= 16) {
      _transcriptCache.remove(_transcriptCache.keys.first);
    }

    _transcriptCache[path] = transcript;
    return transcript;
  }

  Future<List<PitchFrame>> _pitchOrEmpty(String path) async {
    final cached = _pitchCache[path];

    if (cached != null) {
      return cached;
    }

    try {
      final frames = await _speechService.extractPitch(path);

      if (_pitchCache.length >= 16) {
        _pitchCache.remove(_pitchCache.keys.first);
      }

      _pitchCache[path] = frames;
      return frames;
    } on PracticeSpeechException {
      return const <PitchFrame>[];
    }
  }
}
