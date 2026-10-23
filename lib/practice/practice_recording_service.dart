import 'package:flutter/services.dart';

class PracticeRecordingResult {
  const PracticeRecordingResult({
    required this.path,
    required this.durationSeconds,
  });

  factory PracticeRecordingResult.fromJson(Map<String, dynamic> json) {
    final path = json['path'];
    final duration = json['duration_seconds'];

    if (path is! String || path.isEmpty) {
      throw const FormatException('Recording path is missing.');
    }

    if (duration is! num || !duration.isFinite || duration < 0) {
      throw const FormatException('Recording duration is invalid.');
    }

    return PracticeRecordingResult(
      path: path,
      durationSeconds: duration.toDouble(),
    );
  }

  final String path;
  final double durationSeconds;
}

/// Records one practice take at a time.
abstract interface class PracticeRecorder {
  bool get isRecording;

  Future<bool> requestPermission();

  Future<void> start();

  Future<PracticeRecordingResult?> stop();

  Future<void> cancel();
}

class PlatformPracticeRecorder implements PracticeRecorder {
  PlatformPracticeRecorder({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('vietnamese_shadowing/recording');

  static const String channelName = 'vietnamese_shadowing/recording';

  final MethodChannel _channel;

  bool _isRecording = false;

  @override
  bool get isRecording => _isRecording;

  @override
  Future<bool> requestPermission() async {
    return await _channel.invokeMethod<bool>('requestPermission') ?? false;
  }

  @override
  Future<void> start() async {
    if (_isRecording) {
      throw StateError('A practice recording is already in progress.');
    }

    await _channel.invokeMethod<Map<dynamic, dynamic>>('start');
    _isRecording = true;
  }

  @override
  Future<PracticeRecordingResult?> stop() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('stop');

      if (result == null) {
        return null;
      }

      return PracticeRecordingResult.fromJson(result.cast<String, dynamic>());
    } finally {
      _isRecording = false;
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _channel.invokeMethod<void>('cancel');
    } finally {
      _isRecording = false;
    }
  }
}
