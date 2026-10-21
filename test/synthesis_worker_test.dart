import 'dart:convert';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:vietnamese_shadowing/native/vieneu_synthesis_worker.dart';

void main() {
  final workers = <VieNeuSynthesisWorker>[];

  VieNeuSynthesisWorker createWorker() {
    final worker = VieNeuSynthesisWorker(
      isolateEntryPoint: fakeSynthesisWorker,
      initializationTimeout: const Duration(seconds: 2),
      disposalTimeout: const Duration(seconds: 1),
    );
    workers.add(worker);
    return worker;
  }

  tearDown(() async {
    for (final worker in workers) {
      await worker.dispose();
    }
    workers.clear();
  });

  test('initializes the worker and returns its voices', () async {
    final worker = createWorker();

    final voices = await worker.initialize(
      assetsRoot: '/assets',
      cacheRoot: '/cache',
    );

    expect(voices, hasLength(1));
    expect(voices.single.name, 'Adam');
    expect(voices.single.accent, 'Nam');
  });

  test('propagates initialization errors', () async {
    final worker = createWorker();

    await expectLater(
      worker.initialize(assetsRoot: 'fail', cacheRoot: '/cache'),
      throwsA(isA<StateError>()),
    );
  });

  test('rejects requests before initialization and after disposal', () async {
    final worker = createWorker();

    await expectLater(
      worker.synthesizeToWav(text: 'xin chào', voiceId: 'Adam'),
      throwsA(isA<StateError>()),
    );

    await worker.initialize(assetsRoot: '/assets', cacheRoot: '/cache');
    await worker.dispose();

    await expectLater(
      worker.previewSpeechText('xin chào'),
      throwsA(isA<StateError>()),
    );
  });

  test('returns synthesis results and propagates synthesis errors', () async {
    final worker = createWorker();
    await worker.initialize(assetsRoot: '/assets', cacheRoot: '/cache');

    final result = await worker.synthesizeToWav(
      text: 'xin chào',
      voiceId: 'Adam',
    );

    expect(result.path, '/tmp/xin chào.wav');
    expect(result.cacheHit, isFalse);

    await expectLater(
      worker.synthesizeToWav(text: 'fail', voiceId: 'Adam'),
      throwsA(isA<StateError>()),
    );
  });

  test('supports repeated requests without mixing results', () async {
    final worker = createWorker();
    await worker.initialize(assetsRoot: '/assets', cacheRoot: '/cache');

    final results = await Future.wait([
      worker.synthesizeToWav(text: 'first', voiceId: 'Adam'),
      worker.synthesizeToWav(text: 'second', voiceId: 'Adam'),
      worker.synthesizeToWav(text: 'third', voiceId: 'Adam'),
    ]);

    expect(results.map((result) => result.path), [
      '/tmp/first.wav',
      '/tmp/second.wav',
      '/tmp/third.wav',
    ]);
  });

  test('keeps the main isolate responsive during a slow request', () async {
    final worker = createWorker();
    await worker.initialize(assetsRoot: '/assets', cacheRoot: '/cache');

    var mainIsolateTicked = false;
    final synthesis = worker.synthesizeToWav(text: 'slow', voiceId: 'Adam');

    await Future<void>.delayed(const Duration(milliseconds: 20));
    mainIsolateTicked = true;

    expect(mainIsolateTicked, isTrue);

    final result = await synthesis;
    expect(result.path, '/tmp/slow.wav');
  });

  test('supports preview and cache operations', () async {
    final worker = createWorker();
    await worker.initialize(assetsRoot: '/assets', cacheRoot: '/cache');

    expect(await worker.previewSpeechText('xin chào'), 'PREVIEW:xin chào');
    expect(
      await worker.clearCachedText(text: 'xin chào', voiceId: 'Adam'),
      isTrue,
    );

    await worker.clearCache();
  });

  test('fails pending requests when the worker exits unexpectedly', () async {
    final worker = createWorker();
    await worker.initialize(assetsRoot: '/assets', cacheRoot: '/cache');

    await expectLater(
      worker.synthesizeToWav(text: 'exit', voiceId: 'Adam'),
      throwsA(isA<StateError>()),
    );
  });

  test('disposes the worker and is safe to dispose twice', () async {
    final worker = createWorker();
    await worker.initialize(assetsRoot: '/assets', cacheRoot: '/cache');

    await worker.dispose();
    await worker.dispose();

    expect(worker.isDisposed, isTrue);
  });
}

/// A pure-Dart worker used to test the isolate protocol without loading the
/// native library in the host test runner.
Future<void> fakeSynthesisWorker(SendPort mainSendPort) async {
  final receivePort = ReceivePort();

  mainSendPort.send(<String, Object?>{
    'type': 'ready',
    'sendPort': receivePort.sendPort,
  });

  var initialized = false;

  await for (final rawMessage in receivePort) {
    final message = rawMessage as Map;
    final id = message['id'] as int;
    final command = message['command'] as String;

    try {
      switch (command) {
        case 'initialize':
          if (message['assetsRoot'] == 'fail') {
            throw StateError('fake initialization failed');
          }

          initialized = true;

          mainSendPort.send(<String, Object?>{
            'id': id,
            'ok': true,
            'result': jsonEncode([
              <String, Object?>{
                'id': 'Adam',
                'name': 'Adam',
                'description': 'Nam · Nam · Giọng đọc tự nhiên',
                'gender': 'male',
                'accent': 'Nam',
                'style': 'tu_nhien',
              },
            ]),
          });

        case 'synthesize':
          if (!initialized) {
            throw StateError('fake worker is not initialized');
          }

          final text = message['text'] as String;

          if (text == 'fail') {
            throw StateError('fake synthesis failed');
          }

          if (text == 'exit') {
            Isolate.exit();
          }

          if (text == 'slow') {
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }

          mainSendPort.send(<String, Object?>{
            'id': id,
            'ok': true,
            'result': jsonEncode(<String, Object?>{
              'path': '/tmp/$text.wav',
              'cache_hit': false,
            }),
          });

        case 'preview':
          mainSendPort.send(<String, Object?>{
            'id': id,
            'ok': true,
            'result': 'PREVIEW:${message['text']}',
          });

        case 'clearCache':
          mainSendPort.send(<String, Object?>{'id': id, 'ok': true});

        case 'clearCachedText':
          mainSendPort.send(<String, Object?>{
            'id': id,
            'ok': true,
            'result': true,
          });

        case 'dispose':
          mainSendPort.send(<String, Object?>{'id': id, 'ok': true});
          receivePort.close();
          return;

        default:
          throw StateError('Unknown fake command: $command');
      }
    } catch (error) {
      mainSendPort.send(<String, Object?>{
        'id': id,
        'ok': false,
        'error': error.toString(),
      });
    }
  }
}
