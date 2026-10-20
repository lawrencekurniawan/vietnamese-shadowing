import 'dart:async';

import 'package:audioplayers/audioplayers.dart';

enum PlaybackOutcome { completed, stopped }

abstract interface class PlaybackAudio {
  Stream<void> get onComplete;

  Future<void> play(String path);

  Future<void> setPlaybackRate(double rate);

  Future<void> stop();

  Future<void> dispose();
}

class AudioplayersPlaybackAudio implements PlaybackAudio {
  AudioplayersPlaybackAudio() : _player = AudioPlayer();

  final AudioPlayer _player;

  @override
  Stream<void> get onComplete => _player.onPlayerComplete;

  @override
  Future<void> play(String path) => _player.play(DeviceFileSource(path));

  @override
  Future<void> setPlaybackRate(double rate) => _player.setPlaybackRate(rate);

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> dispose() => _player.dispose();
}

typedef WavDurationReader = Future<double> Function(String path);

class PlaybackSession {
  PlaybackSession({
    required this.wavPath,
    required this.playbackSpeed,
    required this.repeatCount,
    required this.paddingSeconds,
    required this.pauseUsesAudioLength,
    required this.wavDurationReader,
    PlaybackAudio? audio,
  }) : _audio = audio ?? AudioplayersPlaybackAudio();

  final String wavPath;
  final double playbackSpeed;
  final int repeatCount;
  final double paddingSeconds;
  final bool pauseUsesAudioLength;
  final WavDurationReader wavDurationReader;
  final PlaybackAudio _audio;

  final Completer<void> _stopCompleter = Completer<void>();

  bool _stopRequested = false;
  bool _disposed = false;
  Future<void>? _stopInFlight;

  bool get stopRequested => _stopRequested;

  Future<PlaybackOutcome> run() async {
    if (_disposed) {
      throw StateError('Playback session has already completed.');
    }

    try {
      for (var i = 0; i < repeatCount; i++) {
        if (_stopRequested) {
          return PlaybackOutcome.stopped;
        }

        final completion = _PlaybackCompletion(_audio.onComplete);

        try {
          await _audio.play(wavPath);
          await _audio.setPlaybackRate(playbackSpeed);

          if (_stopRequested) {
            return PlaybackOutcome.stopped;
          }

          await Future.any<void>([completion.future, _stopCompleter.future]);

          if (_stopRequested) {
            return PlaybackOutcome.stopped;
          }
        } finally {
          await completion.cancel();
        }

        if (i < repeatCount - 1) {
          final pauseSeconds = pauseUsesAudioLength
              ? await wavDurationReader(wavPath)
              : paddingSeconds;

          if (pauseSeconds > 0) {
            await Future.any<void>([
              Future<void>.delayed(
                Duration(milliseconds: (pauseSeconds * 1000).round()),
              ),
              _stopCompleter.future,
            ]);

            if (_stopRequested) {
              return PlaybackOutcome.stopped;
            }
          }
        }
      }

      return _stopRequested
          ? PlaybackOutcome.stopped
          : PlaybackOutcome.completed;
    } finally {
      _disposed = true;

      final stopInFlight = _stopInFlight;
      if (stopInFlight != null) {
        await stopInFlight;
      }

      await _audio.dispose();

      if (!_stopCompleter.isCompleted) {
        _stopCompleter.complete();
      }
    }
  }

  Future<void> stop() {
    if (_disposed) {
      return Future<void>.value();
    }

    if (!_stopRequested) {
      _stopRequested = true;

      if (!_stopCompleter.isCompleted) {
        _stopCompleter.complete();
      }

      _stopInFlight = _stopAudio();
    }

    return _stopInFlight ?? Future<void>.value();
  }

  Future<void> _stopAudio() async {
    try {
      await _audio.stop();
    } catch (_) {
      // The player may already have completed and been disposed. The run()
      // cleanup still releases the native player.
    }
  }
}

class _PlaybackCompletion {
  _PlaybackCompletion(Stream<void> stream) {
    _subscription = stream.listen(
      (_) {
        if (!_completer.isCompleted) {
          _completer.complete();
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!_completer.isCompleted) {
          _completer.completeError(error, stackTrace);
        }
      },
    );
  }

  final Completer<void> _completer = Completer<void>();
  late final StreamSubscription<void> _subscription;

  Future<void> get future => _completer.future;

  Future<void> cancel() => _subscription.cancel();
}
