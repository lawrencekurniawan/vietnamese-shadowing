import 'dart:math' as math;
import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_selector/file_selector.dart';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'native/vieneu_ffi.dart';

void main() {
  runApp(const VietnameseShadowingApp());
}

class VietnameseShadowingApp extends StatelessWidget {
  const VietnameseShadowingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vietnamese Shadowing',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        canvasColor: Colors.black,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const String _defaultVoicePreferenceKey = 'vieneu_default_voice';

  static const String _playbackSpeedPreferenceKey = 'vieneu_playback_speed';

  static const String _repeatCountPreferenceKey = 'vieneu_repeat_count';

  static const String _paddingSecondsPreferenceKey = 'vieneu_padding_seconds';

  static const String _pauseUsesAudioLengthPreferenceKey =
      'vieneu_pause_uses_audio_length';

  final TextEditingController _textController = TextEditingController(
    text: 'Hôm nay bạn khỏe không?',
  );

  final VieNeuFfi _tts = VieNeuFfi();

  final SharedPreferencesAsync _preferences = SharedPreferencesAsync();

  final AudioPlayer _audioPlayer = AudioPlayer();

  List<VietnameseVoice> _voices = const [];

  VietnameseVoice? _selectedVoice;

  String _status = 'Starting...';

  String? _generatedWavPath;

  bool _isInitializing = true;
  bool _isGenerating = false;
  bool _isPlaying = false;

  double _playbackSpeed = 1.0;
  int _repeatCount = 1;
  double _paddingSeconds = 0.5;
  bool _pauseUsesAudioLength = false;

  bool _stopPlaybackRequested = false;
  Completer<void>? _stopPlaybackCompleter;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initialize();
    });
  }

  Future<String> _prepareAndroidAssets() async {
    final applicationSupportDirectory =
        await getApplicationSupportDirectory();

    final assetsRootDirectory = Directory(
      p.join(applicationSupportDirectory.path, 'vieneu', 'assets'),
    );

    await assetsRootDirectory.create(recursive: true);

    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);

    final assetKeys = manifest.listAssets().where((key) {
      if (key.startsWith('assets/vieneu/model/') ||
          key.startsWith('assets/vieneu/codec/') ||
          key.startsWith('assets/sea-g2p/') ||
          key.startsWith('assets/native/')) {
        return !key.split('/').last.startsWith('.');
      }

      return key == 'assets/vieneu/voices_v3_turbo.json';
    });

    for (final assetKey in assetKeys) {
      final relativePath = assetKey.substring('assets/'.length);
      final destination = File(
        p.join(assetsRootDirectory.path, relativePath),
      );

      await destination.parent.create(recursive: true);

      if (await destination.exists()) {
        continue;
      }

      final data = await rootBundle.load(assetKey);
      await destination.writeAsBytes(
        data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        ),
        flush: false,
      );
    }

    return assetsRootDirectory.path;
  }

  Future<void> _initialize() async {
    try {
      print('VieNeu: initializing directly on main isolate...');

      late final String assetsRoot;
      late final String ortPath;

      if (Platform.isMacOS) {
        final executable = File(Platform.resolvedExecutable);
        final contentsDirectory = executable.parent.parent;

        final frameworkDirectory = Directory(
          '${contentsDirectory.path}/Frameworks',
        );

        final appFrameworkDirectory = Directory(
          '${frameworkDirectory.path}/App.framework',
        );

        final flutterAssetsDirectory = Directory(
          '${appFrameworkDirectory.path}/Versions/A/Resources/flutter_assets',
        );

        assetsRoot = '${flutterAssetsDirectory.path}/assets';
        ortPath = '${frameworkDirectory.path}/libonnxruntime.1.24.4.dylib';
      } else if (Platform.isAndroid) {
        assetsRoot = await _prepareAndroidAssets();

        ortPath = p.join(
          assetsRoot,
          'native',
          'libonnxruntime.so',
        );
      } else {
        throw UnsupportedError(
          'VieNeu is currently supported on macOS and Android only.',
        );
      }

      print('VieNeu: assets root = $assetsRoot');
      print('VieNeu: ORT path = $ortPath');

      final applicationSupportDirectory =
          await getApplicationSupportDirectory();

      final cacheDirectory = Directory(
        '${applicationSupportDirectory.path}/vieneu/tts-cache',
      );

      await cacheDirectory.create(recursive: true);

      final cacheRoot = cacheDirectory.path;

      print('VieNeu: cache root = $cacheRoot');

      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'Loading VieNeu models...';
      });

      _tts.create(
        assetsRoot: assetsRoot,
        cacheRoot: cacheRoot,
        ortPath: ortPath,
      );

      print('VieNeu: native engine created.');

      final voices = _tts.listVoices();

      voices.sort((a, b) {
        final accentComparison = a.accent.toLowerCase().compareTo(
          b.accent.toLowerCase(),
        );

        if (accentComparison != 0) {
          return accentComparison;
        }

        final genderComparison = a.gender.toLowerCase().compareTo(
          b.gender.toLowerCase(),
        );

        if (genderComparison != 0) {
          return genderComparison;
        }

        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

      print('VieNeu: loaded ${voices.length} voices.');

      if (voices.isEmpty) {
        throw StateError('No voices loaded.');
      }

      final savedVoiceId = await _preferences.getString(
        _defaultVoicePreferenceKey,
      );

      final savedPlaybackSpeed = await _preferences.getDouble(
        _playbackSpeedPreferenceKey,
      );

      final savedRepeatCount = await _preferences.getInt(
        _repeatCountPreferenceKey,
      );

      final savedPaddingSeconds = await _preferences.getDouble(
        _paddingSecondsPreferenceKey,
      );

      final savedPauseUsesAudioLength = await _preferences.getBool(
        _pauseUsesAudioLengthPreferenceKey,
      );

      final pauseUsesAudioLength = savedPauseUsesAudioLength ?? false;

      final playbackSpeed = savedPlaybackSpeed ?? 1.0;

      final repeatCount = savedRepeatCount ?? 1;

      final paddingSeconds = savedPaddingSeconds ?? 0.5;

      print(
        'VieNeu: saved playback settings: '
        'speed=${playbackSpeed}x, '
        'repeat=$repeatCount, '
        'pause=${pauseUsesAudioLength ? 'audio length' : '${paddingSeconds}s'}',
      );

      VietnameseVoice selectedVoice = voices.first;

      if (savedVoiceId != null) {
        for (final voice in voices) {
          if (voice.id == savedVoiceId) {
            selectedVoice = voice;
            break;
          }
        }
      }

      print(
        'VieNeu: saved default voice = '
        '${savedVoiceId ?? '(none)'}',
      );

      print('VieNeu: selected voice = ${selectedVoice.name}');

      if (!mounted) {
        return;
      }

      setState(() {
        _voices = voices;
        _selectedVoice = selectedVoice;
        _generatedWavPath = null;

        _playbackSpeed = playbackSpeed;
        _repeatCount = repeatCount;
        _paddingSeconds = paddingSeconds;
        _pauseUsesAudioLength = pauseUsesAudioLength;

        _isInitializing = false;
        _status = 'Native engine ready';
      });

      print('VieNeu: initialization complete.');
    } catch (e, stackTrace) {
      print('');
      print('========================================');
      print('VieNeu INITIALIZATION FAILED');
      print('========================================');
      print('Error: $e');
      print('');
      print('Stack trace:');
      print(stackTrace);
      print('========================================');

      if (!mounted) {
        return;
      }

      setState(() {
        _isInitializing = false;
        _status =
            'Initialization failed.\n'
            'See Terminal for details.';
      });
    }
  }

  Future<void> _generateTestAudio() async {
    final voice = _selectedVoice;

    if (voice == null) {
      setState(() {
        _status = 'Please select a voice.';
      });
      return;
    }

    final text = _textController.text.trim();

    if (text.isEmpty) {
      setState(() {
        _status = 'Please enter some Vietnamese text.';
      });
      return;
    }

    if (_isGenerating) {
      return;
    }

    setState(() {
      _isGenerating = true;
      _status = 'Generating audio...';
    });

    try {
      print('');
      print('========================================');
      print('VieNeu: starting synthesis');
      print('VieNeu: text = $text');
      print('VieNeu: voice = ${voice.name}');
      print('========================================');

      final result = _tts.synthesizeToWav(text: text, voiceId: voice.id);

      final outputPath = result.path;
      final cacheHit = result.cacheHit;

      print('VieNeu: cache WAV = $outputPath');

      if (!mounted) {
        return;
      }

      setState(() {
        _generatedWavPath = outputPath;
        _status = cacheHit
            ? 'Synthesis complete — cache HIT'
            : 'Synthesis complete — cache MISS';
      });

      print('VieNeu: ${cacheHit ? 'cache HIT' : 'cache MISS'}');
      print('VieNeu: synthesis complete.');

      final wavFile = File(outputPath);

      if (await wavFile.exists()) {
        print('VieNeu: WAV size = ${await wavFile.length()} bytes');
      } else {
        print(
          'VieNeu: WARNING — cache WAV does not exist: '
          '$outputPath',
        );
      }
    } catch (error, stackTrace) {
      print('VieNeu: synthesis failed: $error');
      print(stackTrace);

      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'Synthesis failed: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isGenerating = false;
        });
      }
    }
  }

  Future<void> _clearCurrentCache() async {
    final voice = _selectedVoice;

    if (voice == null) {
      return;
    }

    final text = _textController.text.trim();

    if (text.isEmpty) {
      setState(() {
        _status = 'Please enter some Vietnamese text.';
      });
      return;
    }

    print('VieNeu: clearing cache for "$text" / ${voice.name}');

    try {
      final removed = _tts.clearCachedText(text: text, voiceId: voice.id);

      if (!mounted) {
        return;
      }

      if (removed) {
        print(
          'VieNeu FFI: cache entry removed for '
          '"$text" / "${voice.name}".',
        );

        setState(() {
          _generatedWavPath = null;
          _status = 'Cache cleared';
        });
      } else {
        setState(() {
          _status = 'No cache entry found';
        });
      }
    } catch (error, stackTrace) {
      print('VieNeu: failed to clear cache: $error');
      print(stackTrace);

      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'Failed to clear cache: $error';
      });
    }
  }

  Future<void> _clearAllCache() async {
    if (_isGenerating || _isPlaying) {
      return;
    }

    try {
      print('VieNeu: clearing entire TTS cache.');

      _tts.clearCache();

      if (!mounted) {
        return;
      }

      setState(() {
        _generatedWavPath = null;
        _status = 'All cached audio cleared';
      });

      print('VieNeu: entire TTS cache cleared.');
    } catch (error, stackTrace) {
      print('VieNeu: failed to clear all cache: $error');
      print(stackTrace);

      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'Failed to clear cache: $error';
      });
    }
  }

  Future<void> _playGeneratedAudio() async {
    final wavPath = _generatedWavPath;

    if (wavPath == null) {
      if (!mounted) return;

      setState(() {
        _status = 'No generated audio available.';
      });

      return;
    }

    final wavFile = File(wavPath);

    if (!await wavFile.exists()) {
      if (!mounted) return;

      setState(() {
        _generatedWavPath = null;
        _status = 'Generated WAV file no longer exists.';
      });

      return;
    }

    if (_isPlaying) {
      return;
    }

    _stopPlaybackRequested = false;
    _stopPlaybackCompleter = Completer<void>();

    setState(() {
      _isPlaying = true;
      _status = 'Playing...';
    });

    try {
      print('VieNeu: playing $wavPath');
      print(
        'VieNeu: speed=${_playbackSpeed}x, '
        'repeats=$_repeatCount, '
        'pause=${_pauseUsesAudioLength ? 'audio length' : '${_paddingSeconds}s'}',
      );

      final originalBytes = await wavFile.readAsBytes();
      final playbackBytes = _trimLeadingSilence(originalBytes);

      if (playbackBytes.length != originalBytes.length) {
        print(
          'VieNeu: trimmed leading silence '
          '(${originalBytes.length - playbackBytes.length} bytes)',
        );
      }

      final playbackDuration = _getWavDurationFromBytes(playbackBytes);

      print(
        'VieNeu: playback WAV duration = '
        '${playbackDuration.inMilliseconds / 1000.0}s',
      );

      final source = BytesSource(
        playbackBytes,
        mimeType: 'audio/wav',
      );

      for (var i = 0; i < _repeatCount; i++) {
        if (_stopPlaybackRequested) {
          break;
        }

        await _audioPlayer.setPlaybackRate(_playbackSpeed);

        final completion = Completer<void>();

        late final StreamSubscription<void> completionSubscription;

        completionSubscription = _audioPlayer.onPlayerComplete.listen((_) {
          if (!completion.isCompleted) {
            completion.complete();
          }
        });

        try {
          await _audioPlayer.play(source);

          await Future.any([
            completion.future,
            _stopPlaybackCompleter!.future,
          ]);
        } finally {
          await completionSubscription.cancel();
        }

        if (_stopPlaybackRequested) {
          break;
        }

        if (i < _repeatCount - 1 && !_stopPlaybackRequested) {
          final pauseSeconds = _pauseUsesAudioLength
              ? playbackDuration.inMilliseconds / 1000.0
              : _paddingSeconds;

          if (pauseSeconds > 0) {
            await Future.any([
              Future.delayed(
                Duration(
                  milliseconds: (pauseSeconds * 1000).round(),
                ),
              ),
              _stopPlaybackCompleter!.future,
            ]);
          }
        }
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _status = _stopPlaybackRequested
            ? 'Playback stopped.'
            : 'Playback complete.';
      });

      print(
        _stopPlaybackRequested
            ? 'VieNeu: playback stopped.'
            : 'VieNeu: playback complete.',
      );
    } catch (error, stackTrace) {
      print('VieNeu: playback failed: $error');
      print(stackTrace);

      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'Playback failed: $error';
      });
    } finally {
      await _audioPlayer.stop();

      _stopPlaybackRequested = false;
      _stopPlaybackCompleter = null;

      if (mounted) {
        setState(() {
          _isPlaying = false;
        });
      }
    }
  }
  

  Future<void> _stopPlayback() async {
    if (!_isPlaying) {
      return;
    }

    _stopPlaybackRequested = true;

    final stopCompleter = _stopPlaybackCompleter;

    if (stopCompleter != null && !stopCompleter.isCompleted) {
      stopCompleter.complete();
    }

    await _audioPlayer.stop();
  }

  Uint8List _trimLeadingSilence(Uint8List bytes) {
    if (bytes.length < 44) {
      return bytes;
    }

    final data = ByteData.sublistView(bytes);

    final riff = String.fromCharCodes(bytes.sublist(0, 4));
    final wave = String.fromCharCodes(bytes.sublist(8, 12));

    if (riff != 'RIFF' || wave != 'WAVE') {
      return bytes;
    }

    var offset = 12;

    int? audioFormat;
    int? channels;
    int? sampleRate;
    int? blockAlign;
    int? bitsPerSample;

    int? dataChunkHeaderOffset;
    int? dataOffset;
    int? dataSize;

    while (offset + 8 <= bytes.length) {
      final chunkId = String.fromCharCodes(
        bytes.sublist(offset, offset + 4),
      );

      final chunkSize = data.getUint32(
        offset + 4,
        Endian.little,
      );

      final chunkDataStart = offset + 8;

      if (chunkDataStart + chunkSize > bytes.length) {
        return bytes;
      }

      if (chunkId == 'fmt ') {
        if (chunkSize < 16) {
          return bytes;
        }

        audioFormat = data.getUint16(
          chunkDataStart,
          Endian.little,
        );

        channels = data.getUint16(
          chunkDataStart + 2,
          Endian.little,
        );

        sampleRate = data.getUint32(
          chunkDataStart + 4,
          Endian.little,
        );

        blockAlign = data.getUint16(
          chunkDataStart + 12,
          Endian.little,
        );

        bitsPerSample = data.getUint16(
          chunkDataStart + 14,
          Endian.little,
        );
      } else if (chunkId == 'data') {
        dataChunkHeaderOffset = offset;
        dataOffset = chunkDataStart;
        dataSize = chunkSize;
        break;
      }

      offset = chunkDataStart + chunkSize;

      if (offset.isOdd) {
        offset++;
      }
    }

    if (audioFormat != 1 ||
        channels == null ||
        sampleRate == null ||
        blockAlign == null ||
        bitsPerSample != 16 ||
        dataChunkHeaderOffset == null ||
        dataOffset == null ||
        dataSize == null) {
      return bytes;
    }

    if (channels <= 0 ||
        sampleRate <= 0 ||
        blockAlign <= 0 ||
        dataSize <= 0) {
      return bytes;
    }

    final dataEnd = dataOffset + dataSize;

    if (dataEnd > bytes.length) {
      return bytes;
    }

    final totalFrames = dataSize ~/ blockAlign;

    // Analyze 10 ms windows.
    final windowFrames = math.max(
      1,
      (sampleRate / 100).round(),
    );

    // About -40 dBFS.
    const silenceRmsThreshold = 0.01;

    var firstSpeechFrame = 0;
    var consecutiveSpeechWindows = 0;

    for (var windowStart = 0;
        windowStart < totalFrames;
        windowStart += windowFrames) {
      final windowEnd = math.min(
        windowStart + windowFrames,
        totalFrames,
      );

      var sumSquares = 0.0;
      var sampleCount = 0;

      for (var frame = windowStart; frame < windowEnd; frame++) {
        final frameOffset = dataOffset + frame * blockAlign;

        for (var channel = 0; channel < channels; channel++) {
          final sampleOffset = frameOffset + channel * 2;

          if (sampleOffset + 2 > dataEnd) {
            break;
          }

          final sample = data.getInt16(
            sampleOffset,
            Endian.little,
          );

          final normalized = sample / 32768.0;

          sumSquares += normalized * normalized;
          sampleCount++;
        }
      }

      if (sampleCount == 0) {
        return bytes;
      }

      final rms = math.sqrt(
        sumSquares / sampleCount,
      );

      if (rms >= silenceRmsThreshold) {
        consecutiveSpeechWindows++;

        // Require 20 ms of non-silence before deciding
        // that actual speech has started.
        if (consecutiveSpeechWindows >= 2) {
          firstSpeechFrame = math.max(
            0,
            windowStart - windowFrames,
          );

          break;
        }
      } else {
        consecutiveSpeechWindows = 0;
      }
    }

    if (firstSpeechFrame <= 0) {
      return bytes;
    }

    // Keep 20 ms of natural lead-in.
    final paddingFrames = (sampleRate * 0.02).round();

    final trimFrames = math.max(
      0,
      firstSpeechFrame - paddingFrames,
    );

    if (trimFrames <= 0) {
      return bytes;
    }

    final trimBytes = trimFrames * blockAlign;

    if (trimBytes >= dataSize) {
      return bytes;
    }

    final newDataSize = dataSize - trimBytes;

    // Preserve everything before the data chunk, then copy the
    // shortened audio data, then preserve everything after it.
    final newBytes = Uint8List(
      bytes.length - trimBytes,
    );

    newBytes.setRange(
      0,
      dataOffset,
      bytes,
      0,
    );

    newBytes.setRange(
      dataOffset,
      dataOffset + newDataSize,
      bytes,
      dataOffset + trimBytes,
    );

    newBytes.setRange(
      dataOffset + newDataSize,
      newBytes.length,
      bytes,
      dataEnd,
    );

    final newData = ByteData.sublistView(newBytes);

    // Update the "data" chunk size.
    newData.setUint32(
      dataChunkHeaderOffset + 4,
      newDataSize,
      Endian.little,
    );

    // Update RIFF chunk size.
    //
    // RIFF size = total file size - 8.
    newData.setUint32(
      4,
      newBytes.length - 8,
      Endian.little,
    );

    return newBytes;
  }

  Duration _getWavDurationFromBytes(Uint8List bytes) {
    if (bytes.length < 44) {
      throw StateError('WAV file is too small to contain a valid header.');
    }

    final data = ByteData.sublistView(bytes);

    final riff = String.fromCharCodes(bytes.sublist(0, 4));
    final wave = String.fromCharCodes(bytes.sublist(8, 12));

    if (riff != 'RIFF' || wave != 'WAVE') {
      throw StateError('Not a valid RIFF/WAVE file.');
    }

    var offset = 12;

    int? byteRate;
    int? dataSize;

    while (offset + 8 <= bytes.length) {
      final chunkId = String.fromCharCodes(
        bytes.sublist(offset, offset + 4),
      );

      final chunkSize = data.getUint32(
        offset + 4,
        Endian.little,
      );

      final chunkDataStart = offset + 8;

      if (chunkDataStart + chunkSize > bytes.length) {
        break;
      }

      if (chunkId == 'fmt ') {
        if (chunkSize < 16) {
          throw StateError('Invalid WAV fmt chunk.');
        }

        byteRate = data.getUint32(
          chunkDataStart + 8,
          Endian.little,
        );
      } else if (chunkId == 'data') {
        dataSize = chunkSize;
        break;
      }

      offset = chunkDataStart + chunkSize;

      if (offset.isOdd) {
        offset++;
      }
    }

    if (byteRate == null || dataSize == null) {
      throw StateError('Could not determine WAV duration.');
    }

    if (byteRate <= 0 || dataSize <= 0) {
      throw StateError('Invalid WAV audio format.');
    }

    return Duration(
      microseconds: (dataSize * 1000000 / byteRate).round(),
    );
  }

  Future<double> _getWavDurationSeconds(String path) async {
    final bytes = await File(path).readAsBytes();

    if (bytes.length < 44) {
      throw StateError('WAV file is too small to contain a valid header.');
    }

    final data = ByteData.sublistView(bytes);

    final riff = String.fromCharCodes(bytes.sublist(0, 4));

    final wave = String.fromCharCodes(bytes.sublist(8, 12));

    if (riff != 'RIFF' || wave != 'WAVE') {
      throw StateError('Not a valid RIFF/WAVE file.');
    }

    var offset = 12;

    int? sampleRate;
    int? byteRate;
    int? dataSize;

    while (offset + 8 <= bytes.length) {
      final chunkId = String.fromCharCodes(bytes.sublist(offset, offset + 4));

      final chunkSize = data.getUint32(offset + 4, Endian.little);

      final chunkDataStart = offset + 8;

      if (chunkDataStart + chunkSize > bytes.length) {
        break;
      }

      if (chunkId == 'fmt ') {
        if (chunkSize < 16) {
          throw StateError('Invalid WAV fmt chunk.');
        }

        sampleRate = data.getUint32(chunkDataStart + 4, Endian.little);

        byteRate = data.getUint32(chunkDataStart + 8, Endian.little);
      } else if (chunkId == 'data') {
        dataSize = chunkSize;
        break;
      }

      offset = chunkDataStart + chunkSize;

      if (offset.isOdd) {
        offset++;
      }
    }

    if (sampleRate == null || byteRate == null || dataSize == null) {
      throw StateError('Could not determine WAV duration.');
    }

    if (sampleRate <= 0 || byteRate <= 0 || dataSize <= 0) {
      throw StateError('Invalid WAV audio format.');
    }

    return dataSize / byteRate;
  }

  Future<void> _selectVoice(VietnameseVoice voice) async {
    setState(() {
      _selectedVoice = voice;
      _generatedWavPath = null;
      _status = 'Voice selected: ${voice.name}';
    });

    try {
      await _preferences.setString(_defaultVoicePreferenceKey, voice.id);

      print(
        'VieNeu: saved default voice = '
        '${voice.name} (${voice.id})',
      );
    } catch (error, stackTrace) {
      print('VieNeu: failed to save default voice: $error');
      print(stackTrace);
    }
  }

  Future<void> _downloadGeneratedAudio() async {
    final wavPath = _generatedWavPath;

    if (wavPath == null) {
      if (!mounted) return;

      setState(() {
        _status = 'Generate audio first.';
      });

      return;
    }

    final sourceFile = File(wavPath);

    if (!await sourceFile.exists()) {
      if (!mounted) return;

      setState(() {
        _status = 'Generated WAV file no longer exists.';
        _generatedWavPath = null;
      });

      return;
    }

    try {
      final originalBytes = await sourceFile.readAsBytes();
      final trimmedBytes = _trimLeadingSilence(originalBytes);

      if (trimmedBytes.length != originalBytes.length) {
        print(
          'VieNeu: trimmed leading silence for download '
          '(${originalBytes.length - trimmedBytes.length} bytes)',
        );
      } else {
        print('VieNeu: no leading silence detected for download.');
      }

      final suggestedName = p.basename(wavPath);

      String? destinationPath;

      if (Platform.isAndroid) {
        final directoryPath = await getDirectoryPath(
          confirmButtonText: 'Select',
          canCreateDirectories: true,
        );

        if (directoryPath == null) {
          return;
        }

        destinationPath = p.join(
          directoryPath,
          suggestedName,
        );
      } else if (Platform.isMacOS) {
        final saveLocation = await getSaveLocation(
          suggestedName: suggestedName,
          acceptedTypeGroups: const [
            XTypeGroup(
              label: 'WAV audio',
              extensions: ['wav'],
              mimeTypes: ['audio/wav'],
            ),
          ],
        );

        if (saveLocation == null) {
          return;
        }

        destinationPath = saveLocation.path;
      } else {
        throw UnsupportedError(
          'Download is currently supported on Android and macOS only.',
        );
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'Saving audio...';
      });

      await File(destinationPath).writeAsBytes(
        trimmedBytes,
        flush: true,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'Audio downloaded successfully.';
      });

      print('VieNeu: trimmed audio downloaded to $destinationPath');
    } catch (error, stackTrace) {
      print('VieNeu: download failed: $error');
      print(stackTrace);

      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'Download failed: $error';
      });
    }
  }

  @override
  void dispose() {
    _stopPlaybackRequested = true;

    final stopCompleter = _stopPlaybackCompleter;

    if (stopCompleter != null && !stopCompleter.isCompleted) {
      stopCompleter.complete();
    }

    _audioPlayer.stop();

    _textController.dispose();
    _tts.dispose();
    _audioPlayer.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final engineReady = !_isInitializing && _voices.isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('Vietnamese Shadowing')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Status
                Text(_status, style: Theme.of(context).textTheme.bodyMedium),

                const SizedBox(height: 12),

                // Vietnamese text
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Vietnamese text',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),

                        const SizedBox(height: 8),

                        TextField(
                          controller: _textController,
                          enabled: !_isGenerating,
                          minLines: 3,
                          maxLines: 6,
                          textInputAction: TextInputAction.newline,
                          onChanged: (_) {
                            if (_generatedWavPath != null) {
                              setState(() {
                                _generatedWavPath = null;
                                _status = 'Text changed — generate new audio.';
                              });
                            }
                          },
                          decoration: const InputDecoration(
                            hintText: 'Enter Vietnamese text...',
                            border: OutlineInputBorder(),
                            alignLabelWithHint: true,
                            contentPadding: EdgeInsets.all(12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                // Action buttons
                Wrap(
                  alignment: WrapAlignment.start,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: !engineReady || _isGenerating
                          ? null
                          : _generateTestAudio,
                      icon: _isGenerating
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.record_voice_over, size: 18),
                      label: Text(_isGenerating ? 'Generating...' : 'Generate'),
                    ),

                    OutlinedButton.icon(
                      onPressed: _generatedWavPath == null || _isPlaying
                          ? null
                          : _playGeneratedAudio,
                      icon: _isPlaying
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.play_arrow, size: 18),
                      label: Text(_isPlaying ? 'Playing...' : 'Play'),
                    ),

                    OutlinedButton.icon(
                      onPressed: _isPlaying ? _stopPlayback : null,
                      icon: const Icon(Icons.stop, size: 18),
                      label: const Text('Stop'),
                    ),

                    OutlinedButton.icon(
                      onPressed:
                          _generatedWavPath == null ||
                              _isGenerating ||
                              _isPlaying
                          ? null
                          : _downloadGeneratedAudio,
                      icon: const Icon(Icons.download, size: 18),
                      label: const Text('Download'),
                    ),

                    MenuAnchor(
                      builder: (context, controller, child) {
                        return OutlinedButton.icon(
                          onPressed: !engineReady || _isGenerating || _isPlaying
                              ? null
                              : () {
                                  if (controller.isOpen) {
                                    controller.close();
                                  } else {
                                    controller.open();
                                  }
                                },
                          icon: const Icon(Icons.cached, size: 18),
                          label: const Text('Cache'),
                        );
                      },
                      menuChildren: [
                        MenuItemButton(
                          onPressed: () {
                            _clearCurrentCache();
                          },
                          child: const Text('Clear This Audio'),
                        ),
                        MenuItemButton(
                          onPressed: () {
                            _clearAllCache();
                          },
                          child: const Text('Clear All Cache'),
                        ),
                      ],
                    ),
                  ],
                ),

                const SizedBox(height: 12),

                // Settings
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Settings',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),

                        const SizedBox(height: 12),

                        // Voice
                        Text(
                          'Voice',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),

                        const SizedBox(height: 4),

                        DropdownButton<VietnameseVoice>(
                          value: _selectedVoice,
                          isExpanded: true,
                          items: _voices.map((voice) {
                            return DropdownMenuItem<VietnameseVoice>(
                              value: voice,
                              child: Text(
                                '${voice.accent} · '
                                '${voice.gender} · '
                                '${voice.name}',
                              ),
                            );
                          }).toList(),
                          onChanged: !engineReady || _isGenerating || _isPlaying
                              ? null
                              : (voice) {
                                  if (voice != null) {
                                    _selectVoice(voice);
                                  }
                                },
                        ),

                        const SizedBox(height: 8),

                        // Repeat
                        Row(
                          children: [
                            SizedBox(
                              width: 72,
                              child: Text(
                                'Repeat',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ),

                            DropdownButton<int>(
                              value: _repeatCount,
                              items: const [
                                DropdownMenuItem(
                                  value: 1,
                                  child: Text('1 time'),
                                ),
                                DropdownMenuItem(
                                  value: 2,
                                  child: Text('2 times'),
                                ),
                                DropdownMenuItem(
                                  value: 3,
                                  child: Text('3 times'),
                                ),
                                DropdownMenuItem(
                                  value: 5,
                                  child: Text('5 times'),
                                ),
                                DropdownMenuItem(
                                  value: 10,
                                  child: Text('10 times'),
                                ),
                              ],
                              onChanged: _isPlaying
                                  ? null
                                  : (value) async {
                                      if (value == null) {
                                        return;
                                      }

                                      setState(() {
                                        _repeatCount = value;
                                      });

                                      await _preferences.setInt(
                                        _repeatCountPreferenceKey,
                                        value,
                                      );
                                    },
                            ),
                          ],
                        ),

                        const SizedBox(height: 4),

                        // Speed
                        Row(
                          children: [
                            SizedBox(
                              width: 72,
                              child: Text(
                                'Speed',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ),

                            Expanded(
                              child: Slider(
                                value: _playbackSpeed,
                                min: 0.5,
                                max: 2.0,
                                divisions: 6,
                                label: '${_playbackSpeed.toStringAsFixed(1)}×',
                                onChanged: _isPlaying
                                    ? null
                                    : (value) {
                                        setState(() {
                                          _playbackSpeed = value;
                                        });
                                      },
                                onChangeEnd: _isPlaying
                                    ? null
                                    : (value) async {
                                        await _preferences.setDouble(
                                          _playbackSpeedPreferenceKey,
                                          value,
                                        );
                                      },
                              ),
                            ),

                            SizedBox(
                              width: 48,
                              child: Text(
                                '${_playbackSpeed.toStringAsFixed(1)}×',
                                textAlign: TextAlign.end,
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 4),

                        // Padding
                        Row(
                          children: [
                            SizedBox(
                              width: 72,
                              child: Text(
                                'Pause',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ),

                            DropdownButton<String>(
                              value: _pauseUsesAudioLength
                                  ? 'audio_length'
                                  : _paddingSeconds.toString(),
                              items: [
                                const DropdownMenuItem(
                                  value: '0.0',
                                  child: Text('0.00 s'),
                                ),
                                const DropdownMenuItem(
                                  value: '0.25',
                                  child: Text('0.25 s'),
                                ),
                                const DropdownMenuItem(
                                  value: '0.5',
                                  child: Text('0.50 s'),
                                ),
                                const DropdownMenuItem(
                                  value: '0.75',
                                  child: Text('0.75 s'),
                                ),
                                const DropdownMenuItem(
                                  value: '1.0',
                                  child: Text('1.00 s'),
                                ),
                                const DropdownMenuItem(
                                  value: '1.5',
                                  child: Text('1.50 s'),
                                ),
                                const DropdownMenuItem(
                                  value: '2.0',
                                  child: Text('2.00 s'),
                                ),
                                const DropdownMenuItem(
                                  value: 'audio_length',
                                  child: Text('Audio length'),
                                ),
                              ],
                              onChanged: _isPlaying
                                  ? null
                                  : (value) async {
                                      if (value == null) {
                                        return;
                                      }

                                      if (value == 'audio_length') {
                                        setState(() {
                                          _pauseUsesAudioLength = true;
                                        });

                                        await _preferences.setBool(
                                          _pauseUsesAudioLengthPreferenceKey,
                                          true,
                                        );
                                      } else {
                                        final seconds = double.parse(value);

                                        setState(() {
                                          _pauseUsesAudioLength = false;
                                          _paddingSeconds = seconds;
                                        });

                                        await _preferences.setBool(
                                          _pauseUsesAudioLengthPreferenceKey,
                                          false,
                                        );

                                        await _preferences.setDouble(
                                          _paddingSecondsPreferenceKey,
                                          seconds,
                                        );
                                      }
                                    },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
