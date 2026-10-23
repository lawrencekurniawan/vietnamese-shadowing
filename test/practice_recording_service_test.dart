import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vietnamese_shadowing/practice/practice_recording_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(PlatformPracticeRecorder.channelName);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('starts and stops a recording', () async {
    final calls = <MethodCall>[];

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);

          if (call.method == 'start') {
            return <String, dynamic>{'path': '/tmp/recording.wav'};
          }

          if (call.method == 'stop') {
            return <String, dynamic>{
              'path': '/tmp/recording.wav',
              'duration_seconds': 1.75,
            };
          }

          return null;
        });

    final recorder = PlatformPracticeRecorder();

    expect(recorder.isRecording, isFalse);

    await recorder.start();

    expect(recorder.isRecording, isTrue);

    final result = await recorder.stop();

    expect(recorder.isRecording, isFalse);
    expect(result?.path, '/tmp/recording.wav');
    expect(result?.durationSeconds, 1.75);
    expect(calls.map((call) => call.method), ['start', 'stop']);
  });

  test('returns null when no recording is active', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);

    final recorder = PlatformPracticeRecorder();

    expect(await recorder.stop(), isNull);
  });

  test('requests permission and cancels', () async {
    final calls = <String>[];

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);

          if (call.method == 'requestPermission') {
            return true;
          }

          return null;
        });

    final recorder = PlatformPracticeRecorder();

    expect(await recorder.requestPermission(), isTrue);

    await recorder.cancel();

    expect(calls, ['requestPermission', 'cancel']);
  });

  test('does not mark recording when start fails', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: 'microphone_permission_denied');
        });

    final recorder = PlatformPracticeRecorder();

    await expectLater(recorder.start(), throwsA(isA<PlatformException>()));
    expect(recorder.isRecording, isFalse);
  });

  test('clears recording state when stop fails', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'start') {
            return <String, dynamic>{'path': '/tmp/recording.wav'};
          }

          throw PlatformException(code: 'stop_failed');
        });

    final recorder = PlatformPracticeRecorder();

    await recorder.start();
    expect(recorder.isRecording, isTrue);

    await expectLater(recorder.stop(), throwsA(isA<PlatformException>()));
    expect(recorder.isRecording, isFalse);
  });
}
