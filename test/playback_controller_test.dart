import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vietnamese_shadowing/playback/playback_controller.dart';
import 'package:vietnamese_shadowing/playback/playback_session.dart';

void main() {
  test('owns one playback session at a time', () async {
    final audio = FakePlaybackAudio();
    var audioFactoryCalls = 0;

    final controller = PlaybackController(
      wavDurationReader: (_) async => 0,
      audioFactory: () {
        audioFactoryCalls++;
        return audio;
      },
    );

    final firstPlay = audio.playEvents.firstWhere((count) => count == 1);

    final first = controller.play(
      wavPath: '/library/one.wav',
      playbackSpeed: 1,
      repeatCount: 1,
      paddingSeconds: 0,
      pauseUsesAudioLength: false,
    );

    await firstPlay;

    expect(controller.isPlaying, isTrue);
    expect(controller.currentPath, '/library/one.wav');

    final competing = await controller.play(
      wavPath: '/library/two.wav',
      playbackSpeed: 1,
      repeatCount: 1,
      paddingSeconds: 0,
      pauseUsesAudioLength: false,
    );

    expect(competing, isNull);
    expect(audioFactoryCalls, 1);
    expect(controller.currentPath, '/library/one.wav');

    audio.complete();
    expect(await first, PlaybackOutcome.completed);
    expect(controller.isPlaying, isFalse);
    expect(controller.currentPath, isNull);
  });

  test('stop interrupts the active session and clears ownership', () async {
    final audio = FakePlaybackAudio();
    final controller = PlaybackController(
      wavDurationReader: (_) async => 0,
      audioFactory: () => audio,
    );
    final firstPlay = audio.playEvents.firstWhere((count) => count == 1);

    final run = controller.play(
      wavPath: '/library/playing.wav',
      playbackSpeed: 1,
      repeatCount: 3,
      paddingSeconds: 0.2,
      pauseUsesAudioLength: false,
    );

    await firstPlay;
    await controller.stop();

    expect(
      await run.timeout(const Duration(seconds: 1)),
      PlaybackOutcome.stopped,
    );
    expect(audio.stopCount, 1);
    expect(controller.isPlaying, isFalse);
    expect(controller.currentPath, isNull);
  });

  test('dispose stops active audio', () async {
    final audio = FakePlaybackAudio();
    final controller = PlaybackController(
      wavDurationReader: (_) async => 0,
      audioFactory: () => audio,
    );
    final firstPlay = audio.playEvents.firstWhere((count) => count == 1);

    final run = controller.play(
      wavPath: '/library/dispose.wav',
      playbackSpeed: 1,
      repeatCount: 3,
      paddingSeconds: 0.2,
      pauseUsesAudioLength: false,
    );

    await firstPlay;
    await controller.dispose();

    expect(
      await run.timeout(const Duration(seconds: 1)),
      PlaybackOutcome.stopped,
    );
    expect(audio.stopCount, 1);
  });
}

class FakePlaybackAudio implements PlaybackAudio {
  final StreamController<void> _completionController =
      StreamController<void>.broadcast();
  final StreamController<int> _playController =
      StreamController<int>.broadcast();

  int playCount = 0;
  int stopCount = 0;
  int disposeCount = 0;

  Stream<int> get playEvents => _playController.stream;

  @override
  Stream<void> get onComplete => _completionController.stream;

  @override
  Future<void> play(String path) async {
    playCount++;
    _playController.add(playCount);
  }

  @override
  Future<void> setPlaybackRate(double rate) async {}

  @override
  Future<void> stop() async {
    stopCount++;
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
    await _completionController.close();
    await _playController.close();
  }

  void complete() {
    _completionController.add(null);
  }
}
