import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

final class _NativeTtsEngine extends Opaque {}

typedef _TtsCreateNative = Pointer<_NativeTtsEngine> Function(
  Pointer<Utf8> assetsRoot,
  Pointer<Utf8> cacheRoot,
  Pointer<Utf8> ortPath,
);

typedef _TtsCreateDart = Pointer<_NativeTtsEngine> Function(
  Pointer<Utf8> assetsRoot,
  Pointer<Utf8> cacheRoot,
  Pointer<Utf8> ortPath,
);

typedef _TtsDestroyNative = Void Function(Pointer<_NativeTtsEngine> engine);

typedef _TtsDestroyDart = void Function(Pointer<_NativeTtsEngine> engine);

typedef _TtsListVoicesNative = Pointer<Utf8> Function(
  Pointer<_NativeTtsEngine> engine,
);

typedef _TtsListVoicesDart = Pointer<Utf8> Function(
  Pointer<_NativeTtsEngine> engine,
);

typedef _TtsSynthesizeNative = Pointer<Utf8> Function(
  Pointer<_NativeTtsEngine> engine,
  Pointer<Utf8> text,
  Pointer<Utf8> voiceId,
);

typedef _TtsSynthesizeDart = Pointer<Utf8> Function(
  Pointer<_NativeTtsEngine> engine,
  Pointer<Utf8> text,
  Pointer<Utf8> voiceId,
);

typedef _TtsClearCacheNative = Int32 Function(Pointer<_NativeTtsEngine> engine);

typedef _TtsClearCacheDart = int Function(Pointer<_NativeTtsEngine> engine);

typedef _FreeStringNative = Void Function(Pointer<Utf8> ptr);

typedef _FreeStringDart = void Function(Pointer<Utf8> ptr);

typedef _TtsClearCachedTextNative = Int32 Function(
  Pointer<_NativeTtsEngine> engine,
  Pointer<Utf8> text,
  Pointer<Utf8> voiceId,
);

typedef _TtsClearCachedTextDart = int Function(
  Pointer<_NativeTtsEngine> engine,
  Pointer<Utf8> text,
  Pointer<Utf8> voiceId,
);

typedef _TtsLastErrorNative = Pointer<Utf8> Function();
typedef _TtsLastErrorDart = Pointer<Utf8> Function();

class VietnameseVoice {
  final String id;
  final String name;
  final String description;
  final String gender;
  final String accent;
  final String style;

  const VietnameseVoice({
    required this.id,
    required this.name,
    required this.description,
    required this.gender,
    required this.accent,
    required this.style,
  });

  factory VietnameseVoice.fromJson(Map<String, dynamic> json) {
    return VietnameseVoice(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String,
      gender: json['gender'] as String,
      accent: json['accent'] as String,
      style: json['style'] as String,
    );
  }
}

class VieNeuFfi {
  late final DynamicLibrary _library;
  late final _TtsCreateDart _create;
  late final _TtsDestroyDart _destroy;
  late final _TtsListVoicesDart _listVoices;
  late final _TtsSynthesizeDart _synthesize;
  late final _TtsClearCacheDart _clearCache;
  late final _FreeStringDart _freeString;
  late final _TtsClearCachedTextDart _clearCachedText;
  late final _TtsLastErrorDart _lastError;

  Pointer<_NativeTtsEngine>? _engine;

  VieNeuFfi({String? libraryPath}) {
    _library = _openLibrary(libraryPath);

    _create = _library.lookupFunction<_TtsCreateNative, _TtsCreateDart>(
      'vieneu_tts_create',
    );

    _destroy = _library.lookupFunction<_TtsDestroyNative, _TtsDestroyDart>(
      'vieneu_tts_destroy',
    );

    _listVoices = _library
        .lookupFunction<_TtsListVoicesNative, _TtsListVoicesDart>(
          'vieneu_tts_list_voices',
        );

    _synthesize = _library
        .lookupFunction<_TtsSynthesizeNative, _TtsSynthesizeDart>(
          'vieneu_tts_synthesize_to_wav',
        );

    _clearCache = _library
        .lookupFunction<_TtsClearCacheNative, _TtsClearCacheDart>(
          'vieneu_tts_clear_cache',
        );

    _clearCachedText = _library
        .lookupFunction<_TtsClearCachedTextNative, _TtsClearCachedTextDart>(
          'vieneu_tts_clear_cached_text',
        );

    _freeString = _library.lookupFunction<_FreeStringNative, _FreeStringDart>(
      'vieneu_free_string',
    );

    _lastError = _library
        .lookupFunction<_TtsLastErrorNative, _TtsLastErrorDart>(
          'vieneu_tts_last_error',
        );
  }

  bool clearCachedText({required String text, required String voiceId}) {
    final engine = _requireEngine();

    final textPtr = text.toNativeUtf8();

    final voicePtr = voiceId.toNativeUtf8();

    try {
      final result = _clearCachedText(engine, textPtr, voicePtr);

      if (result == 0) {
        print(
          'VieNeu FFI: no cached entry found '
          'for "$text" / "$voiceId".',
        );

        return false;
      }

      return true;
    } finally {
      malloc.free(textPtr);

      malloc.free(voicePtr);
    }
  }

  static DynamicLibrary _openLibrary(String? explicitPath) {
    if (Platform.isIOS) {
      if (explicitPath != null) {
        throw UnsupportedError(
          'Explicit native library paths are not supported on iOS.',
        );
      }

      return DynamicLibrary.process();
    }

    if (!Platform.isMacOS) {
      throw UnsupportedError(
        'VieNeuFfi currently supports macOS and iOS only.',
      );
    }

    // Explicit path is useful for development/testing.
    if (explicitPath != null) {
      final file = File(explicitPath);

      if (!file.existsSync()) {
        throw StateError('VieNeu native library not found: $explicitPath');
      }

      return DynamicLibrary.open(explicitPath);
    }

    final executablePath = Platform.resolvedExecutable;
    final executable = File(executablePath);
    final contentsDirectory = executable.parent.parent;

    final libraryPath =
        '${contentsDirectory.path}/Frameworks/libvieneu_core.dylib';

    final libraryFile = File(libraryPath);
    if (!libraryFile.existsSync()) {
      throw StateError('Bundled VieNeu native library not found: $libraryPath');
    }

    return DynamicLibrary.open(libraryPath);
  }

  void create({
    required String assetsRoot,
    required String cacheRoot,
    String? ortPath,
  }) {
    if (_engine != null) {
      return;
    }

    final assetsPtr = assetsRoot.toNativeUtf8();
    final cachePtr = cacheRoot.toNativeUtf8();
    final ortPtr = ortPath?.toNativeUtf8() ?? nullptr;

    try {
      final engine = _create(assetsPtr, cachePtr, ortPtr);

      if (engine == nullptr) {
        final errorPtr = _lastError();
        String message = 'vieneu_tts_create() failed.';

        if (errorPtr != nullptr) {
          message = errorPtr.toDartString();
          _freeString(errorPtr);
        }

        throw StateError(message);
      }

      _engine = engine;
    } finally {
      malloc.free(assetsPtr);
      malloc.free(cachePtr);

      if (ortPtr != nullptr) {
        malloc.free(ortPtr);
      }
    }
  }

  List<VietnameseVoice> listVoices() {
    final engine = _requireEngine();

    final ptr = _listVoices(engine);

    if (ptr == nullptr) {
      throw StateError('vieneu_tts_list_voices() failed.');
    }

    try {
      final jsonString = ptr.toDartString();

      final decoded = jsonDecode(jsonString) as List<dynamic>;

      return decoded
          .map((item) => VietnameseVoice.fromJson(item as Map<String, dynamic>))
          .toList();
    } finally {
      _freeString(ptr);
    }
  }

  ({String path, bool cacheHit}) synthesizeToWav({
    required String text,
    required String voiceId,
  }) {
    final engine = _requireEngine();

    final textPtr = text.toNativeUtf8();
    final voicePtr = voiceId.toNativeUtf8();

    try {
      final ptr = _synthesize(engine, textPtr, voicePtr);

      if (ptr == nullptr) {
        final errorPtr = _lastError();

        var message = 'vieneu_tts_synthesize_to_wav() failed.';

        if (errorPtr != nullptr) {
          message = errorPtr.toDartString();
          _freeString(errorPtr);
        }

        throw StateError(message);
      }

      try {
        final jsonString = ptr.toDartString();

        final decoded = jsonDecode(jsonString) as Map<String, dynamic>;

        final path = decoded['path'] as String;
        final cacheHit = decoded['cache_hit'] as bool;

        return (path: path, cacheHit: cacheHit);
      } finally {
        _freeString(ptr);
      }
    } finally {
      malloc.free(textPtr);
      malloc.free(voicePtr);
    }
  }

  void clearCache() {
    final engine = _requireEngine();

    final result = _clearCache(engine);

    if (result != 1) {
      throw StateError('vieneu_tts_clear_cache() failed.');
    }
  }

  void dispose() {
    final engine = _engine;

    if (engine == null) {
      return;
    }

    _destroy(engine);

    _engine = null;
  }

  Pointer<_NativeTtsEngine> _requireEngine() {
    final engine = _engine;

    if (engine == null) {
      throw StateError('VieNeuFfi.create() must be called first.');
    }

    return engine;
  }
}
