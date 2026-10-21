import 'dart:async';

import 'package:vietnamese_shadowing/playback/playback_session.dart';

class FakePlaybackAudio implements PlaybackAudio {
  final StreamController<void> _completionController =
      StreamController<void>.broadcast();

  int playCount = 0;
  int stopCount = 0;
  int disposeCount = 0;

  @override
  Stream<void> get onComplete => _completionController.stream;

  @override
  Future<void> play(String path) async {
    playCount++;
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
  }

  void complete() {
    _completionController.add(null);
  }
}
