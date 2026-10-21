import 'playback_session.dart';

/// Owns the single active playback session shared by the Generate and Library
/// tabs.
class PlaybackController {
  PlaybackController({
    required WavDurationReader wavDurationReader,
    PlaybackAudio Function()? audioFactory,
  }) : this._(wavDurationReader, audioFactory);

  PlaybackController._(this._wavDurationReader, this._audioFactory);

  final WavDurationReader _wavDurationReader;
  final PlaybackAudio Function()? _audioFactory;

  PlaybackSession? _session;
  String? _currentPath;
  bool _isPlaying = false;

  bool get isPlaying => _isPlaying;

  String? get currentPath => _currentPath;

  PlaybackSession? get activeSession => _session;

  /// Starts playback unless another session is already active.
  ///
  /// Returns `null` when a session is already playing. There is deliberately
  /// only one owner so switching tabs cannot create competing players.
  Future<PlaybackOutcome?> play({
    required String wavPath,
    required double playbackSpeed,
    required int repeatCount,
    required double paddingSeconds,
    required bool pauseUsesAudioLength,
  }) async {
    if (_isPlaying) {
      return null;
    }

    final session = PlaybackSession(
      wavPath: wavPath,
      playbackSpeed: playbackSpeed,
      repeatCount: repeatCount,
      paddingSeconds: paddingSeconds,
      pauseUsesAudioLength: pauseUsesAudioLength,
      wavDurationReader: _wavDurationReader,
      audio: _audioFactory?.call(),
    );

    _session = session;
    _currentPath = wavPath;
    _isPlaying = true;

    try {
      return await session.run();
    } finally {
      if (identical(_session, session)) {
        _session = null;
        _currentPath = null;
        _isPlaying = false;
      }
    }
  }

  Future<void> stop() async {
    final session = _session;

    if (session != null) {
      await session.stop();
    }
  }

  Future<void> dispose() async {
    await stop();
  }
}
