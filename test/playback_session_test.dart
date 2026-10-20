import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vietnamese_shadowing/playback/playback_session.dart';

void main() {
  const wavPath = '/tmp/test.wav';

  PlaybackSession createSession(
    FakePlaybackAudio audio, {
    int repeatCount = 1,
    double paddingSeconds = 0,
    double playbackSpeed = 1.0,
    bool pauseUsesAudioLength = false,
    WavDurationReader? wavDurationReader,
  }) {
    return PlaybackSession(
      wavPath: wavPath,
      playbackSpeed: playbackSpeed,
      repeatCount: repeatCount,
      paddingSeconds: paddingSeconds,
      pauseUsesAudioLength: pauseUsesAudioLength,
      wavDurationReader: wavDurationReader ?? (_) async => 0,
      audio: audio,
    );
  }

  test(
    'natural completion disposes the player and reports completion',
    () async {
      final audio = FakePlaybackAudio();
      final session = createSession(audio);
      final firstPlay = audio.playEvents.firstWhere((count) => count == 1);

      final run = session.run();
      await firstPlay;
      audio.complete();

      expect(await run, PlaybackOutcome.completed);
      expect(audio.playCount, 1);
      expect(audio.stopCount, 0);
      expect(audio.disposeCount, 1);
    },
  );

  test('stop during the first clip interrupts it promptly', () async {
    final audio = FakePlaybackAudio();
    final session = createSession(audio, repeatCount: 3, paddingSeconds: 0.05);
    final firstPlay = audio.playEvents.firstWhere((count) => count == 1);

    final run = session.run();
    await firstPlay;

    final stopwatch = Stopwatch()..start();
    await session.stop();
    final outcome = await run.timeout(const Duration(seconds: 1));
    stopwatch.stop();

    expect(outcome, PlaybackOutcome.stopped);
    expect(session.stopRequested, isTrue);
    expect(audio.stopCount, 1);
    expect(audio.playCount, 1);
    expect(audio.disposeCount, 1);
    expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 500)));
  });

  test('stop during the pause prevents the next repeat', () async {
    final audio = FakePlaybackAudio();
    final session = createSession(audio, repeatCount: 2, paddingSeconds: 0.3);
    final firstPlay = audio.playEvents.firstWhere((count) => count == 1);

    final run = session.run();
    await firstPlay;
    audio.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final stopwatch = Stopwatch()..start();
    await session.stop();
    final outcome = await run.timeout(const Duration(seconds: 1));
    stopwatch.stop();

    expect(outcome, PlaybackOutcome.stopped);
    expect(audio.playCount, 1);
    expect(audio.stopCount, 1);
    expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 500)));
  });

  test('stop during a later repeat interrupts that clip', () async {
    final audio = FakePlaybackAudio();
    final session = createSession(audio, repeatCount: 3);
    final firstPlay = audio.playEvents.firstWhere((count) => count == 1);
    final secondPlay = audio.playEvents.firstWhere((count) => count == 2);

    final run = session.run();
    await firstPlay;
    audio.complete();
    await secondPlay;

    await session.stop();
    final outcome = await run.timeout(const Duration(seconds: 1));

    expect(outcome, PlaybackOutcome.stopped);
    expect(audio.playCount, 2);
    expect(audio.stopCount, 1);
    expect(audio.disposeCount, 1);
  });

  test(
    'natural playback preserves repeat count, rate, and padding pause',
    () async {
      final audio = FakePlaybackAudio();
      final session = createSession(
        audio,
        repeatCount: 3,
        paddingSeconds: 0.1,
        playbackSpeed: 1.25,
      );
      final firstPlay = audio.playEvents.firstWhere((count) => count == 1);
      final secondPlay = audio.playEvents.firstWhere((count) => count == 2);
      final thirdPlay = audio.playEvents.firstWhere((count) => count == 3);

      final run = session.run();
      await firstPlay;
      audio.complete();

      final pauseWatch = Stopwatch()..start();
      await secondPlay;
      pauseWatch.stop();
      expect(
        pauseWatch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 80)),
      );

      audio.complete();
      await thirdPlay;
      audio.complete();

      expect(await run, PlaybackOutcome.completed);
      expect(audio.playCount, 3);
      expect(audio.playbackRates, [1.25, 1.25, 1.25]);
      expect(audio.stopCount, 0);
      expect(audio.disposeCount, 1);
    },
  );

  test(
    'pause can use the WAV duration instead of the padding setting',
    () async {
      final audio = FakePlaybackAudio();
      var durationReads = 0;
      final session = createSession(
        audio,
        repeatCount: 2,
        pauseUsesAudioLength: true,
        wavDurationReader: (path) async {
          expect(path, wavPath);
          durationReads++;
          return 0.02;
        },
      );
      final firstPlay = audio.playEvents.firstWhere((count) => count == 1);
      final secondPlay = audio.playEvents.firstWhere((count) => count == 2);

      final run = session.run();
      await firstPlay;
      audio.complete();
      await secondPlay;
      audio.complete();

      expect(await run, PlaybackOutcome.completed);
      expect(durationReads, 1);
      expect(audio.playCount, 2);
    },
  );

  test('a stopped session does not affect a newer playback session', () async {
    final firstAudio = FakePlaybackAudio();
    final firstSession = createSession(firstAudio, repeatCount: 2);
    final firstPlay = firstAudio.playEvents.firstWhere((count) => count == 1);

    final firstRun = firstSession.run();
    await firstPlay;
    await firstSession.stop();
    expect(await firstRun, PlaybackOutcome.stopped);

    final secondAudio = FakePlaybackAudio();
    final secondSession = createSession(secondAudio, repeatCount: 2);
    final secondPlay = secondAudio.playEvents.firstWhere((count) => count == 1);

    final secondRun = secondSession.run();
    await secondPlay;

    await firstSession.stop();
    expect(firstAudio.stopCount, 1);
    expect(secondAudio.stopCount, 0);

    await secondSession.stop();
    expect(await secondRun, PlaybackOutcome.stopped);
    expect(secondAudio.stopCount, 1);
  });

  test('stop before run starts prevents any audio from playing', () async {
    final audio = FakePlaybackAudio();
    final session = createSession(audio, repeatCount: 3);

    await session.stop();
    final outcome = await session.run().timeout(const Duration(seconds: 1));

    expect(outcome, PlaybackOutcome.stopped);
    expect(audio.stopCount, 1);
    expect(audio.playCount, 0);
    expect(audio.disposeCount, 1);
  });

  test('playback errors still dispose the player', () async {
    final audio = FakePlaybackAudio()..failPlay = true;
    final session = createSession(audio);
    final firstPlay = audio.playEvents.firstWhere((count) => count == 1);

    final run = session.run();
    await firstPlay;

    await expectLater(run, throwsA(isA<StateError>()));
    expect(audio.disposeCount, 1);
  });
}

class FakePlaybackAudio implements PlaybackAudio {
  final StreamController<void> _completionController =
      StreamController<void>.broadcast();
  final StreamController<int> _playController =
      StreamController<int>.broadcast();

  final List<double> playbackRates = [];

  int playCount = 0;
  int stopCount = 0;
  int disposeCount = 0;
  bool failPlay = false;

  Stream<int> get playEvents => _playController.stream;

  @override
  Stream<void> get onComplete => _completionController.stream;

  @override
  Future<void> play(String path) async {
    playCount++;
    _playController.add(playCount);

    if (failPlay) {
      throw StateError('play failed');
    }
  }

  @override
  Future<void> setPlaybackRate(double rate) async {
    playbackRates.add(rate);
  }

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
