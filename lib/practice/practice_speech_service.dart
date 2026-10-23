import 'package:flutter/services.dart';

class SpeechSegment {
  const SpeechSegment({
    required this.text,
    required this.startSeconds,
    required this.durationSeconds,
    this.confidence,
  });

  factory SpeechSegment.fromJson(Map<String, dynamic> json) {
    final text = json['text'];
    final start = json['start_seconds'];
    final duration = json['duration_seconds'];
    final confidence = json['confidence'];

    if (text is! String || text.trim().isEmpty) {
      throw const FormatException('Speech segment text is missing.');
    }

    if (start is! num || !start.isFinite || start < 0) {
      throw const FormatException('Speech segment start is invalid.');
    }

    if (duration is! num || !duration.isFinite || duration <= 0) {
      throw const FormatException('Speech segment duration is invalid.');
    }

    return SpeechSegment(
      text: text.trim(),
      startSeconds: start.toDouble(),
      durationSeconds: duration.toDouble(),
      confidence: confidence is num && confidence.isFinite
          ? confidence.toDouble()
          : null,
    );
  }

  final String text;
  final double startSeconds;
  final double durationSeconds;
  final double? confidence;
}

class SpeechTranscript {
  const SpeechTranscript({
    required this.text,
    this.segments = const <SpeechSegment>[],
    this.usedOnDevice = false,
  });

  factory SpeechTranscript.fromJson(Map<String, dynamic> json) {
    final text = json['text'];
    final rawSegments = json['segments'];
    final segments = <SpeechSegment>[];

    if (rawSegments is List) {
      for (final raw in rawSegments) {
        if (raw is! Map) {
          continue;
        }

        try {
          segments.add(SpeechSegment.fromJson(raw.cast<String, dynamic>()));
        } on FormatException {
          // Keep the rest of the transcript if one segment is malformed.
        }
      }
    }

    return SpeechTranscript(
      text: text is String ? text.trim() : '',
      segments: List<SpeechSegment>.unmodifiable(segments),
      usedOnDevice: json['on_device'] == true,
    );
  }

  final String text;
  final List<SpeechSegment> segments;
  final bool usedOnDevice;
}

class PitchFrame {
  const PitchFrame({required this.timeSeconds, required this.f0Hz});

  factory PitchFrame.fromJson(Map<String, dynamic> json) {
    final time = json['time_seconds'];
    final f0 = json['f0_hz'];

    if (time is! num || !time.isFinite || time < 0) {
      throw const FormatException('Pitch frame time is invalid.');
    }

    if (f0 is! num || !f0.isFinite || f0 <= 0) {
      throw const FormatException('Pitch frame frequency is invalid.');
    }

    return PitchFrame(timeSeconds: time.toDouble(), f0Hz: f0.toDouble());
  }

  final double timeSeconds;
  final double f0Hz;
}

class PracticeSpeechException implements Exception {
  const PracticeSpeechException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => message;
}

/// On-device transcription and pitch extraction for practice feedback.
abstract interface class PracticeSpeechService {
  Future<SpeechTranscript> transcribe(String path, {String locale = 'vi-VN'});

  Future<List<PitchFrame>> extractPitch(String path);
}

class PlatformPracticeSpeechService implements PracticeSpeechService {
  PlatformPracticeSpeechService({MethodChannel? channel})
    : _channel =
          channel ??
          const MethodChannel('vietnamese_shadowing/practice_assessment');

  static const String channelName = 'vietnamese_shadowing/practice_assessment';

  final MethodChannel _channel;

  @override
  Future<SpeechTranscript> transcribe(
    String path, {
    String locale = 'vi-VN',
  }) async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'transcribe',
        <String, dynamic>{'path': path, 'locale': locale},
      );

      if (result == null) {
        throw const PracticeSpeechException(
          'Speech recognition returned no result.',
        );
      }

      return SpeechTranscript.fromJson(result.cast<String, dynamic>());
    } on PlatformException catch (error) {
      throw PracticeSpeechException(
        error.message ?? 'Speech recognition failed.',
        code: error.code,
      );
    } on MissingPluginException {
      throw const PracticeSpeechException(
        'Speech recognition is only available in the iOS app.',
        code: 'missing_plugin',
      );
    }
  }

  @override
  Future<List<PitchFrame>> extractPitch(String path) async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'pitch',
        <String, dynamic>{'path': path},
      );

      if (result == null) {
        throw const PracticeSpeechException(
          'Pitch analysis returned no result.',
        );
      }

      final rawFrames = result['frames'];

      if (rawFrames is! List) {
        throw const PracticeSpeechException(
          'Pitch analysis returned an invalid result.',
        );
      }

      final frames = <PitchFrame>[];

      for (final raw in rawFrames) {
        if (raw is! Map) {
          continue;
        }

        try {
          frames.add(PitchFrame.fromJson(raw.cast<String, dynamic>()));
        } on FormatException {
          // Ignore one malformed frame instead of discarding the contour.
        }
      }

      return List<PitchFrame>.unmodifiable(frames);
    } on PlatformException catch (error) {
      throw PracticeSpeechException(
        error.message ?? 'Pitch analysis failed.',
        code: error.code,
      );
    } on MissingPluginException {
      throw const PracticeSpeechException(
        'Pitch analysis is only available in the iOS app.',
        code: 'missing_plugin',
      );
    }
  }
}
