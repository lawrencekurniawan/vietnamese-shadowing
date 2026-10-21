import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'synthesis_service.dart';
import 'vieneu_ffi.dart';

/// Owns a long-lived synthesis isolate and a single native engine.
///
/// The native engine pointer never leaves the worker isolate. Requests and
/// results cross the isolate boundary as plain values only.
class VieNeuSynthesisWorker implements SynthesisService {
  VieNeuSynthesisWorker({
    void Function(SendPort)? isolateEntryPoint,
    this.initializationTimeout = const Duration(seconds: 30),
    this.disposalTimeout = const Duration(seconds: 5),
  }) : _isolateEntryPoint = isolateEntryPoint ?? _vieneuSynthesisWorkerMain;

  final void Function(SendPort) _isolateEntryPoint;
  final Duration initializationTimeout;
  final Duration disposalTimeout;

  final ReceivePort _messages = ReceivePort();
  final ReceivePort _exits = ReceivePort();
  final ReceivePort _errors = ReceivePort();
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};

  Isolate? _isolate;
  SendPort? _commands;
  Completer<void>? _ready;
  bool _disposed = false;
  int _nextRequestId = 1;

  bool get isDisposed => _disposed;

  /// Starts the worker, creates its native engine, and returns its voice list.
  @override
  Future<List<VietnameseVoice>> initialize({
    required String assetsRoot,
    required String cacheRoot,
    String? ortPath,
    String? libraryPath,
  }) async {
    if (_disposed) {
      throw StateError('The synthesis worker has been disposed.');
    }

    if (_isolate != null) {
      throw StateError('The synthesis worker is already initialized.');
    }

    _messages.listen(_handleMessage);
    _exits.listen(_handleExit);
    _errors.listen(_handleIsolateError);

    _ready = Completer<void>();

    try {
      _isolate = await Isolate.spawn(
        _isolateEntryPoint,
        _messages.sendPort,
        onExit: _exits.sendPort,
        onError: _errors.sendPort,
        errorsAreFatal: true,
        debugName: 'vieneu-synthesis',
      );

      await _ready!.future.timeout(initializationTimeout);

      final result = await _request('initialize', <String, Object?>{
        'assetsRoot': assetsRoot,
        'cacheRoot': cacheRoot,
        'ortPath': ortPath,
        'libraryPath': libraryPath,
      }, timeout: initializationTimeout);

      if (result is! String) {
        throw StateError('Synthesis worker returned an invalid voice list.');
      }

      final decoded = jsonDecode(result);

      if (decoded is! List) {
        throw StateError('Synthesis worker returned an invalid voice list.');
      }

      return decoded
          .map(
            (item) =>
                VietnameseVoice.fromJson((item as Map).cast<String, dynamic>()),
          )
          .toList(growable: false);
    } catch (_) {
      await _shutdownAfterFailure();
      rethrow;
    }
  }

  @override
  Future<({String path, bool cacheHit})> synthesizeToWav({
    required String text,
    required String voiceId,
  }) async {
    final result = await _request('synthesize', <String, Object?>{
      'text': text,
      'voiceId': voiceId,
    });

    if (result is! String) {
      throw StateError('Synthesis worker returned an invalid result.');
    }

    final decoded = jsonDecode(result);

    if (decoded is! Map) {
      throw StateError('Synthesis worker returned an invalid result.');
    }

    final path = decoded['path'];
    final cacheHit = decoded['cache_hit'];

    if (path is! String || cacheHit is! bool) {
      throw StateError('Synthesis worker returned an invalid result.');
    }

    return (path: path, cacheHit: cacheHit);
  }

  @override
  Future<String> previewSpeechText(String text) async {
    final result = await _request('preview', <String, Object?>{'text': text});

    if (result is! String) {
      throw StateError('Synthesis worker returned an invalid preview.');
    }

    return result;
  }

  @override
  Future<void> clearCache() async {
    await _request('clearCache', const <String, Object?>{});
  }

  @override
  Future<bool> clearCachedText({
    required String text,
    required String voiceId,
  }) async {
    final result = await _request('clearCachedText', <String, Object?>{
      'text': text,
      'voiceId': voiceId,
    });

    if (result is! bool) {
      throw StateError('Synthesis worker returned an invalid cache result.');
    }

    return result;
  }

  /// Stops the worker and asks it to destroy its native engine.
  ///
  /// If the worker is busy in non-cancellable native inference, it is killed
  /// after [disposalTimeout]. The process is exiting in that case.
  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }

    _disposed = true;

    final commands = _commands;

    if (commands != null) {
      final id = _nextRequestId++;
      final completer = Completer<Object?>();
      _pending[id] = completer;
      commands.send(<String, Object?>{'id': id, 'command': 'dispose'});

      try {
        await completer.future.timeout(disposalTimeout);
      } catch (_) {
        // The worker may still be inside non-cancellable native inference.
      }
    }

    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _commands = null;

    _failPending(StateError('The synthesis worker was disposed.'));
    _completeReadyError(StateError('The synthesis worker was disposed.'));

    _messages.close();
    _exits.close();
    _errors.close();
  }

  Future<Object?> _request(
    String command,
    Map<String, Object?> arguments, {
    Duration? timeout,
  }) {
    if (_disposed) {
      return Future<Object?>.error(
        StateError('The synthesis worker has been disposed.'),
      );
    }

    final commands = _commands;

    if (commands == null) {
      return Future<Object?>.error(
        StateError('The synthesis worker has not been initialized.'),
      );
    }

    final id = _nextRequestId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;

    commands.send(<String, Object?>{
      'id': id,
      'command': command,
      ...arguments,
    });

    if (timeout == null) {
      return completer.future;
    }

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException(
          'Synthesis worker request "$command" timed out.',
          timeout,
        );
      },
    );
  }

  void _handleMessage(Object? message) {
    if (message is! Map) {
      return;
    }

    if (message['type'] == 'ready') {
      final sendPort = message['sendPort'];

      if (sendPort is SendPort) {
        _commands = sendPort;
        final ready = _ready;

        if (ready != null && !ready.isCompleted) {
          ready.complete();
        }
      }

      return;
    }

    final id = message['id'];

    if (id is! int) {
      return;
    }

    final completer = _pending.remove(id);

    if (completer == null || completer.isCompleted) {
      return;
    }

    if (message['ok'] == true) {
      completer.complete(message['result']);
      return;
    }

    completer.completeError(
      StateError(message['error'] as String? ?? 'Synthesis worker failed.'),
    );
  }

  void _handleIsolateError(Object? message) {
    if (message is! List || message.isEmpty) {
      return;
    }

    final error = message.first;
    final stackTrace = message.length > 1 && message[1] is StackTrace
        ? message[1] as StackTrace
        : StackTrace.empty;

    _handlePortError(error, stackTrace);
  }

  void _handlePortError(Object error, StackTrace stackTrace) {
    if (_disposed) {
      return;
    }

    final wrapped = StateError('Synthesis worker failed: $error');
    _completeReadyError(wrapped);
    _failPending(wrapped);
  }

  void _handleExit(Object? _) {
    if (_disposed) {
      return;
    }

    final error = StateError('Synthesis worker exited unexpectedly.');
    _commands = null;
    _isolate = null;
    _completeReadyError(error);
    _failPending(error);
  }

  void _completeReadyError(Object error) {
    final ready = _ready;

    if (ready != null && !ready.isCompleted) {
      ready.completeError(error);
    }
  }

  void _failPending(Object error) {
    final pending = _pending.values.toList(growable: false);
    _pending.clear();

    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }
  }

  Future<void> _shutdownAfterFailure() async {
    _disposed = true;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _commands = null;

    _failPending(StateError('The synthesis worker failed to initialize.'));
    _completeReadyError(
      StateError('The synthesis worker failed to initialize.'),
    );

    _messages.close();
    _exits.close();
    _errors.close();
  }
}

/// Worker entrypoint. It must remain a top-level function so it can be spawned
/// in a separate isolate.
Future<void> _vieneuSynthesisWorkerMain(SendPort mainSendPort) async {
  final receivePort = ReceivePort();

  mainSendPort.send(<String, Object?>{
    'type': 'ready',
    'sendPort': receivePort.sendPort,
  });

  VieNeuFfi? tts;

  await for (final message in receivePort) {
    if (message is! Map) {
      continue;
    }

    final id = message['id'];
    final command = message['command'];

    if (command is! String) {
      if (id is int) {
        mainSendPort.send(<String, Object?>{
          'id': id,
          'ok': false,
          'error': 'Missing synthesis worker command.',
        });
      }

      continue;
    }

    try {
      if (command == 'dispose') {
        tts?.dispose();
        tts = null;

        if (id is int) {
          mainSendPort.send(<String, Object?>{'id': id, 'ok': true});
        }

        receivePort.close();
        return;
      }

      switch (command) {
        case 'initialize':
          final assetsRoot = message['assetsRoot'];
          final cacheRoot = message['cacheRoot'];
          final ortPath = message['ortPath'];
          final libraryPath = message['libraryPath'];

          if (assetsRoot is! String || cacheRoot is! String) {
            throw ArgumentError('Invalid synthesis worker paths.');
          }

          tts?.dispose();
          tts = VieNeuFfi(
            libraryPath: libraryPath is String ? libraryPath : null,
          );

          tts.create(
            assetsRoot: assetsRoot,
            cacheRoot: cacheRoot,
            ortPath: ortPath is String ? ortPath : null,
          );

          final voices = tts.listVoices();

          mainSendPort.send(<String, Object?>{
            'id': id,
            'ok': true,
            'result': jsonEncode(
              voices
                  .map(
                    (voice) => <String, Object?>{
                      'id': voice.id,
                      'name': voice.name,
                      'description': voice.description,
                      'gender': voice.gender,
                      'accent': voice.accent,
                      'style': voice.style,
                    },
                  )
                  .toList(growable: false),
            ),
          });

        case 'synthesize':
          final text = message['text'];
          final voiceId = message['voiceId'];

          if (text is! String || voiceId is! String) {
            throw ArgumentError('Invalid synthesis request.');
          }

          final engine = tts;

          if (engine == null) {
            throw StateError('The synthesis worker is not initialized.');
          }

          final result = engine.synthesizeToWav(text: text, voiceId: voiceId);

          mainSendPort.send(<String, Object?>{
            'id': id,
            'ok': true,
            'result': jsonEncode(<String, Object?>{
              'path': result.path,
              'cache_hit': result.cacheHit,
            }),
          });

        case 'preview':
          final text = message['text'];

          if (text is! String) {
            throw ArgumentError('Invalid preview request.');
          }

          final engine = tts;

          if (engine == null) {
            throw StateError('The synthesis worker is not initialized.');
          }

          mainSendPort.send(<String, Object?>{
            'id': id,
            'ok': true,
            'result': engine.previewSpeechText(text),
          });

        case 'clearCache':
          final engine = tts;

          if (engine == null) {
            throw StateError('The synthesis worker is not initialized.');
          }

          engine.clearCache();
          mainSendPort.send(<String, Object?>{'id': id, 'ok': true});

        case 'clearCachedText':
          final text = message['text'];
          final voiceId = message['voiceId'];

          if (text is! String || voiceId is! String) {
            throw ArgumentError('Invalid cache request.');
          }

          final engine = tts;

          if (engine == null) {
            throw StateError('The synthesis worker is not initialized.');
          }

          mainSendPort.send(<String, Object?>{
            'id': id,
            'ok': true,
            'result': engine.clearCachedText(text: text, voiceId: voiceId),
          });

        default:
          throw ArgumentError('Unknown synthesis worker command: $command');
      }
    } catch (error) {
      if (command == 'initialize') {
        tts?.dispose();
        tts = null;
      }

      if (id is int) {
        mainSendPort.send(<String, Object?>{
          'id': id,
          'ok': false,
          'error': error.toString(),
        });
      }
    }
  }
}
