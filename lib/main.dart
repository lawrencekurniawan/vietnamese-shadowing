import 'package:share_plus/share_plus.dart' as share_plus;
import 'package:flutter/services.dart';

import 'app/home_page_environment.dart';
import 'app/preference_store.dart';
import 'documents/document_open_service.dart';
import 'native/synthesis_service.dart';
import 'native/vieneu_asset_stager.dart';

import 'dart:async';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'library/library_metadata.dart';
import 'library/library_repository.dart';
import 'library/vshadow_package.dart';
import 'library/wav_export_filename.dart';
import 'native/vieneu_ffi.dart';
import 'native/vieneu_synthesis_worker.dart';
import 'playback/playback_controller.dart';
import 'playback/playback_session.dart';
import 'ui/home_tab_scaffold.dart';
import 'ui/library_item_card.dart';
import 'voices/voice_identity.dart';
import 'voices/voice_preferences.dart';

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
  const HomePage({super.key, this.environment});

  final HomePageEnvironment? environment;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const String _defaultVoiceIdPreferenceKey = 'vieneu_default_voice_id';

  static const String _defaultVoicePreferenceKey = 'vieneu_default_voice';

  static const String _playbackSpeedPreferenceKey = 'vieneu_playback_speed';

  static const String _repeatCountPreferenceKey = 'vieneu_repeat_count';

  static const String _paddingSecondsPreferenceKey = 'vieneu_padding_seconds';

  static const String _pauseUsesAudioLengthPreferenceKey =
      'vieneu_pause_uses_audio_length';

  static const String _vshadowUniformTypeIdentifier =
      'com.example.vietnameseshadowing.vshadow';

  static const String _voicePreviewText = 'Xin chào, đây là giọng đọc mẫu.';

  final TextEditingController _textController = TextEditingController(
    text: 'Hôm nay bạn khỏe không?',
  );

  late final SynthesisService _tts;

  PreferenceStore? _preferenceStore;

  PreferenceStore get _preferences => _preferenceStore ??=
      widget.environment?.preferences ?? SharedPreferencesStore();

  late final DocumentOpenService _documentOpenService;

  String? _pendingExternalDocumentPath;

  List<VietnameseVoice> _voices = const [];

  VietnameseVoice? _selectedVoice;

  String _status = 'Starting...';

  String? _generatedWavPath;
  String? _previewedSpeechText;

  bool _isInitializing = true;
  bool _isGenerating = false;
  bool _isPlaying = false;

  int _selectedTab = 0;

  LibraryRepository? _libraryRepository;
  List<LibraryItemMetadata> _libraryItems = const [];
  bool _isLibraryLoading = false;
  String? _libraryError;

  double _playbackSpeed = 1.0;
  int _repeatCount = 1;
  double _paddingSeconds = 0.5;
  bool _pauseUsesAudioLength = false;

  late final PlaybackController _playbackController;

  @override
  void initState() {
    super.initState();

    _tts = widget.environment?.synthesisService ?? VieNeuSynthesisWorker();

    _playbackController = PlaybackController(
      wavDurationReader: _getWavDurationSeconds,
      audioFactory: widget.environment?.playbackAudioFactory,
    );

    _documentOpenService = DocumentOpenService();
    _documentOpenService.setHandler(_handleExternalDocument);
    unawaited(_initializeDocumentOpen());

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initialize();
    });
  }

  Future<void> _initialize() async {
    try {
      final bootstrap = widget.environment?.bootstrap;

      if (bootstrap != null) {
        debugPrint('VieNeu: applying injected startup state.');

        final data = await bootstrap();
        final voices = selectPreferredVoices(data.voices);

        VoiceCatalog.fromVoices(voices);

        final selectedVoice = data.selectedVoice;

        if (!voices.any((voice) => voice.stableId == selectedVoice.stableId)) {
          throw StateError('The selected voice is not in the catalog.');
        }

        if (!mounted) {
          return;
        }

        setState(() {
          _voices = List<VietnameseVoice>.unmodifiable(voices);
          _selectedVoice = selectedVoice;
          _generatedWavPath = null;

          _playbackSpeed = data.playbackSpeed;
          _repeatCount = data.repeatCount;
          _paddingSeconds = data.paddingSeconds;
          _pauseUsesAudioLength = data.pauseUsesAudioLength;

          _libraryRepository = data.libraryRepository;
          _libraryItems = List<LibraryItemMetadata>.unmodifiable(
            data.libraryItems,
          );
          _libraryError = data.libraryError;

          _selectedTab = data.initialTab;
          _isInitializing = false;
          _status = data.status;
        });

        await _drainPendingExternalDocument();
        return;
      }

      print('VieNeu: initializing background synthesis worker...');

      final String? ortPath;

      if (Platform.isIOS) {
        ortPath = null;
        print('VieNeu: iOS uses statically linked ONNX Runtime.');
      } else if (Platform.isMacOS) {
        final executable = File(Platform.resolvedExecutable);
        final contentsDirectory = executable.parent.parent;

        final frameworkDirectory = Directory(
          '${contentsDirectory.path}/Frameworks',
        );

        ortPath = '${frameworkDirectory.path}/libonnxruntime.1.24.4.dylib';
        print('VieNeu: ORT path = $ortPath');
      } else {
        throw UnsupportedError('VieNeu currently supports iOS and macOS only.');
      }

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

      print('VieNeu: BEFORE native engine create');

      final stagedAssetsRoot = await VieNeuAssetStager.stage();

      print('VieNeu: staged assets root = ${stagedAssetsRoot.path}');

      final nativeVoices = await _tts.initialize(
        assetsRoot: stagedAssetsRoot.path,
        cacheRoot: cacheRoot,
        ortPath: ortPath,
      );

      print('VieNeu: AFTER native engine create');

      final voices = selectPreferredVoices(nativeVoices);
      final voiceCatalog = VoiceCatalog.fromVoices(voices);

      print(
        'VieNeu: native catalog = ${nativeVoices.length} voices; '
        'using ${voices.length} preferred voices.',
      );

      final savedVoiceId = await _preferences.getString(
        _defaultVoiceIdPreferenceKey,
      );

      final legacySavedVoiceId = await _preferences.getString(
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

      final selectedVoice = resolvePreferredVoice(
        catalog: voiceCatalog,
        defaultVoice: defaultPreferredVoice(voices),
        savedStableId: savedVoiceId,
        legacySavedVoiceId: legacySavedVoiceId,
      );

      print(
        'VieNeu: saved default voice = '
        '${savedVoiceId ?? legacySavedVoiceId ?? '(none)'}',
      );

      print(
        'VieNeu: selected voice = ${selectedVoice.name} '
        '(${selectedVoice.stableId})',
      );

      LibraryRepository? libraryRepository;
      List<LibraryItemMetadata> libraryItems = const [];
      String? libraryError;

      try {
        libraryRepository = await LibraryRepository.open(
          applicationSupportDirectory: applicationSupportDirectory,
        );

        libraryItems = await libraryRepository.list();

        debugPrint('VieNeu: loaded ${libraryItems.length} library items.');
      } catch (error, stackTrace) {
        debugPrint('VieNeu: library initialization failed: $error');
        debugPrint('$stackTrace');
        libraryError = 'Library unavailable: $error';
      }

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

        _libraryRepository = libraryRepository;
        _libraryItems = libraryItems;
        _libraryError = libraryError;

        _isInitializing = false;
        _status = 'Native engine ready';
      });

      print('VieNeu: initialization complete.');

      await _drainPendingExternalDocument();
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

  Future<void> _initializeDocumentOpen() async {
    try {
      while (mounted) {
        final path = await _documentOpenService.takePendingDocument();

        if (path == null) {
          return;
        }

        await _handleExternalDocument(path);
      }
    } on MissingPluginException {
      // Widget tests and unsupported hosts do not register the native channel.
    } catch (error, stackTrace) {
      debugPrint('VieNeu: document-open initialization failed: $error');
      debugPrint('$stackTrace');
    }
  }

  Future<void> _handleExternalDocument(String path) async {
    if (!path.toLowerCase().endsWith('.vshadow')) {
      _showStatus('Unsupported document type.');
      return;
    }

    if (_libraryRepository == null) {
      _pendingExternalDocumentPath = path;
      return;
    }

    await _importVshadowFile(File(path), deleteAfterImport: true);
  }

  Future<void> _drainPendingExternalDocument() async {
    final path = _pendingExternalDocumentPath;

    if (path == null) {
      return;
    }

    _pendingExternalDocumentPath = null;
    await _handleExternalDocument(path);
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
      print('VieNeu: voice = ${voice.name} (${voice.stableId})');
      print('========================================');

      // Native synthesis continues to use the preset name as its lookup key.
      final result = await _tts.synthesizeToWav(text: text, voiceId: voice.id);

      final outputPath = result.path;
      final cacheHit = result.cacheHit;

      print('VieNeu: cache WAV = $outputPath');

      if (!mounted) {
        return;
      }

      setState(() {
        _generatedWavPath = outputPath;
        _isGenerating = false;
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
        _isGenerating = false;
        _status = 'Synthesis failed: $error';
      });
    } finally {
      if (mounted && _isGenerating) {
        setState(() {
          _isGenerating = false;
        });
      }
    }
  }

  Future<void> _previewSpeechText() async {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      setState(() {
        _previewedSpeechText = null;
        _status = 'Please enter some text to preview.';
      });
      return;
    }

    try {
      final normalized = await _tts.previewSpeechText(text);
      if (!mounted) return;
      setState(() {
        _previewedSpeechText = normalized;
        _status = 'Speech text preview ready.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _previewedSpeechText = null;
        _status = 'Speech text preview failed: $error';
      });
    }
  }

  Future<void> _previewSelectedVoice() async {
    final voice = _selectedVoice;

    if (voice == null || _isGenerating || _isPlaying) {
      return;
    }

    setState(() {
      _isGenerating = true;
      _status = 'Generating voice preview...';
    });

    try {
      final result = await _tts.synthesizeToWav(
        text: _voicePreviewText,
        voiceId: voice.id,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _isGenerating = false;
        _status = 'Voice preview ready.';
      });

      await _playWavPath(
        result.path,
        playbackSpeed: 1.0,
        repeatCount: 1,
        paddingSeconds: 0,
        pauseUsesAudioLength: false,
        playingStatus: 'Playing voice preview...',
      );
    } catch (error, stackTrace) {
      print('VieNeu: voice preview failed: $error');
      print(stackTrace);

      if (!mounted) {
        return;
      }

      setState(() {
        _isGenerating = false;
        _status = 'Voice preview failed: $error';
      });
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
      final removed = await _tts.clearCachedText(text: text, voiceId: voice.id);

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

      await _tts.clearCache();

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

    await _playWavPath(wavPath);
  }

  Future<void> _playWavPath(
    String wavPath, {
    double? playbackSpeed,
    int? repeatCount,
    double? paddingSeconds,
    bool? pauseUsesAudioLength,
    String? playingStatus,
  }) async {
    if (_isPlaying || _playbackController.isPlaying) {
      return;
    }

    final speed = playbackSpeed ?? _playbackSpeed;
    final repeats = repeatCount ?? _repeatCount;
    final padding = paddingSeconds ?? _paddingSeconds;
    final pauseByLength = pauseUsesAudioLength ?? _pauseUsesAudioLength;

    try {
      setState(() {
        _isPlaying = true;
        _status = playingStatus ?? 'Playing...';
      });

      print('VieNeu: playing $wavPath');
      print(
        'VieNeu: speed=${speed}x, '
        'repeats=$repeats, '
        'pause=${pauseByLength ? 'audio length' : '${padding}s'}',
      );

      final outcome = await _playbackController.play(
        wavPath: wavPath,
        playbackSpeed: speed,
        repeatCount: repeats,
        paddingSeconds: padding,
        pauseUsesAudioLength: pauseByLength,
      );

      if (!mounted || outcome == null) {
        return;
      }

      final stopped = outcome == PlaybackOutcome.stopped;

      setState(() {
        _status = stopped ? 'Playback stopped.' : 'Playback complete.';
      });

      print(
        stopped ? 'VieNeu: playback stopped.' : 'VieNeu: playback complete.',
      );
    } catch (error, stackTrace) {
      print('VieNeu: playback failed: $error');
      print(stackTrace);

      if (!mounted) {
        return;
      }

      final stopped = _playbackController.activeSession?.stopRequested ?? false;

      setState(() {
        _status = stopped ? 'Playback stopped.' : 'Playback failed: $error';
      });
    } finally {
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

    await _playbackController.stop();
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
      await _preferences.setString(
        _defaultVoiceIdPreferenceKey,
        voice.stableId,
      );
      await _preferences.setString(_defaultVoicePreferenceKey, voice.id);

      print(
        'VieNeu: saved default voice = '
        '${voice.name} (${voice.stableId} -> ${voice.id})',
      );
    } catch (error, stackTrace) {
      print('VieNeu: failed to save default voice: $error');
      print(stackTrace);
    }
  }

  Future<void> _downloadGeneratedAudio() async {
    final wavPath = _generatedWavPath;

    if (wavPath == null) {
      setState(() {
        _status = 'Generate audio first.';
      });
      return;
    }

    final sourceExists = await _exportWavFile(
      wavPath: wavPath,
      text: _textController.text,
      stableVoiceId: _selectedVoice?.stableId ?? wavVoiceComponentFallback,
    );

    if (!sourceExists && mounted) {
      setState(() {
        _generatedWavPath = null;
      });
    }
  }

  Future<void> _exportLibraryWav(LibraryItemMetadata item) async {
    final repository = _libraryRepository;

    if (repository == null) {
      _showStatus('Library is unavailable.');
      return;
    }

    final sourceExists = await _exportWavFile(
      wavPath: repository.audioFile(item.itemId).path,
      text: item.originalText,
      stableVoiceId: item.voice.stableId,
    );

    if (!sourceExists) {
      await _refreshLibrary();
    }
  }

  Future<bool> _exportWavFile({
    required String wavPath,
    required String text,
    required String stableVoiceId,
  }) async {
    final sourceFile = File(wavPath);

    if (!await sourceFile.exists()) {
      if (mounted) {
        setState(() {
          _status = 'WAV file no longer exists.';
        });
      }

      return false;
    }

    try {
      final suggestedName = buildWavExportFilename(
        text: text,
        stableVoiceId: stableVoiceId,
        exportedAt: DateTime.now(),
      );

      if (Platform.isIOS) {
        if (mounted) {
          setState(() {
            _status = 'Opening share sheet...';
          });
        }

        await share_plus.SharePlus.instance.share(
          share_plus.ShareParams(
            title: 'Vietnamese Shadowing Audio',
            files: [
              share_plus.XFile(
                wavPath,
                name: suggestedName,
                mimeType: 'audio/wav',
              ),
            ],
          ),
        );

        if (!mounted) {
          return true;
        }

        setState(() {
          _status = 'Share sheet closed.';
        });

        print('VieNeu: iOS share sheet closed.');
        return true;
      }

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
        return true;
      }

      if (mounted) {
        setState(() {
          _status = 'Saving audio...';
        });
      }

      await sourceFile.copy(saveLocation.path);

      if (!mounted) {
        return true;
      }

      setState(() {
        _status = 'Audio downloaded successfully.';
      });

      print('VieNeu: audio downloaded to ${saveLocation.path}');
      return true;
    } catch (error, stackTrace) {
      print('VieNeu: download failed: $error');
      print(stackTrace);

      if (!mounted) {
        return true;
      }

      setState(() {
        _status = 'Download failed: $error';
      });

      return true;
    }
  }

  Future<void> _importVshadowPackage() async {
    final repository = _libraryRepository;

    if (repository == null) {
      _showStatus('Library is unavailable.');
      return;
    }

    try {
      final selected = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'Vietnamese Shadowing package',
            extensions: ['vshadow'],
            mimeTypes: ['application/zip', 'application/octet-stream'],
            uniformTypeIdentifiers: [_vshadowUniformTypeIdentifier],
          ),
        ],
      );

      if (selected == null) {
        return;
      }

      if (await selected.length() > maxVshadowPackageBytes) {
        throw const FormatException('Package exceeds the 200 MiB limit.');
      }

      await _importVshadowBytes(repository, await selected.readAsBytes());
    } catch (error, stackTrace) {
      _reportVshadowImportFailure(error, stackTrace);
    }
  }

  Future<void> _importVshadowFile(
    File file, {
    bool deleteAfterImport = false,
  }) async {
    final repository = _libraryRepository;

    if (repository == null) {
      _showStatus('Library is unavailable.');
      return;
    }

    try {
      if (!await file.exists()) {
        throw StateError('The opened package no longer exists.');
      }

      if (await file.length() > maxVshadowPackageBytes) {
        throw const FormatException('Package exceeds the 200 MiB limit.');
      }

      await _importVshadowBytes(repository, await file.readAsBytes());
    } catch (error, stackTrace) {
      _reportVshadowImportFailure(error, stackTrace);
    } finally {
      if (deleteAfterImport) {
        try {
          await file.delete();
        } catch (_) {
          // The package may already have been removed by the system.
        }
      }
    }
  }

  Future<void> _importVshadowBytes(
    LibraryRepository repository,
    Uint8List bytes,
  ) async {
    if (bytes.length > maxVshadowPackageBytes) {
      throw const FormatException('Package exceeds the 200 MiB limit.');
    }

    final service = VshadowPackageService(repository: repository);
    final imported = await service.importBytes(bytes);

    await _refreshLibrary();

    if (!mounted) {
      return;
    }

    setState(() {
      _status = 'Imported: ${imported.title}';
      _selectedTab = 1;
    });
  }

  void _reportVshadowImportFailure(Object error, StackTrace stackTrace) {
    debugPrint('VieNeu: .vshadow import failed: $error');
    debugPrint('$stackTrace');

    if (!mounted) {
      return;
    }

    setState(() {
      _status = '.vshadow import failed: $error';
    });
  }

  Future<void> _exportVshadowPackage(LibraryItemMetadata item) async {
    final repository = _libraryRepository;

    if (repository == null) {
      _showStatus('Library is unavailable.');
      return;
    }

    try {
      final service = VshadowPackageService(repository: repository);
      final bytes = await service.exportItem(item);
      final suggestedName = buildVshadowExportFilename(
        text: item.originalText,
        stableVoiceId: item.voice.stableId,
        exportedAt: DateTime.now(),
      );

      if (Platform.isIOS) {
        final temporaryDirectory = await getTemporaryDirectory();
        final temporaryFile = File('${temporaryDirectory.path}/$suggestedName');

        await temporaryFile.writeAsBytes(bytes, flush: true);

        if (mounted) {
          setState(() {
            _status = 'Opening share sheet...';
          });
        }

        await share_plus.SharePlus.instance.share(
          share_plus.ShareParams(
            title: 'Vietnamese Shadowing Package',
            files: [
              share_plus.XFile(
                temporaryFile.path,
                name: suggestedName,
                mimeType: 'application/zip',
              ),
            ],
          ),
        );

        if (mounted) {
          setState(() {
            _status = '.vshadow share sheet closed.';
          });
        }

        return;
      }

      final saveLocation = await getSaveLocation(
        suggestedName: suggestedName,
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'Vietnamese Shadowing package',
            extensions: ['vshadow'],
            mimeTypes: ['application/zip', 'application/octet-stream'],
            uniformTypeIdentifiers: [_vshadowUniformTypeIdentifier],
          ),
        ],
      );

      if (saveLocation == null) {
        return;
      }

      await File(saveLocation.path).writeAsBytes(bytes, flush: true);

      if (mounted) {
        setState(() {
          _status = '.vshadow exported successfully.';
        });
      }
    } catch (error, stackTrace) {
      debugPrint('VieNeu: .vshadow export failed: $error');
      debugPrint('$stackTrace');

      if (!mounted) {
        return;
      }

      setState(() {
        _status = '.vshadow export failed: $error';
      });
    }
  }

  Future<void> _refreshLibrary() async {
    final repository = _libraryRepository;

    if (repository == null) {
      return;
    }

    if (mounted) {
      setState(() {
        _isLibraryLoading = true;
      });
    }

    try {
      final items = await repository.list();

      if (!mounted) {
        return;
      }

      setState(() {
        _libraryItems = items;
        _libraryError = null;
        _isLibraryLoading = false;
      });
    } catch (error, stackTrace) {
      debugPrint('VieNeu: library refresh failed: $error');
      debugPrint('$stackTrace');

      if (!mounted) {
        return;
      }

      setState(() {
        _libraryError = 'Library refresh failed: $error';
        _isLibraryLoading = false;
      });
    }
  }

  Future<void> _saveGeneratedToLibrary() async {
    final repository = _libraryRepository;
    final voice = _selectedVoice;
    final wavPath = _generatedWavPath;
    final text = _textController.text.trim();

    if (repository == null) {
      _showStatus('Library is unavailable.');
      return;
    }

    if (voice == null) {
      _showStatus('Please select a voice.');
      return;
    }

    if (wavPath == null) {
      _showStatus('Generate audio before saving it.');
      return;
    }

    if (text.isEmpty) {
      _showStatus('Please enter some Vietnamese text.');
      return;
    }

    if (_isGenerating) {
      return;
    }

    final title = await _promptForTitle(
      initialTitle: _defaultLibraryTitle(text),
      dialogTitle: 'Save to Library',
    );

    if (title == null) {
      return;
    }

    try {
      final normalizedText =
          _previewedSpeechText ?? await _tts.previewSpeechText(text);

      final item = await repository.saveFromWavFile(
        title: title,
        originalText: text,
        normalizedText: normalizedText,
        voice: VoiceMetadata.fromVoice(voice),
        sourceWavPath: wavPath,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'Saved to Library: ${item.title}';
        _selectedTab = 1;
      });

      await _refreshLibrary();
    } catch (error, stackTrace) {
      debugPrint('VieNeu: save to library failed: $error');
      debugPrint('$stackTrace');

      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'Save to Library failed: $error';
      });
    }
  }

  Future<void> _playLibraryItem(LibraryItemMetadata item) async {
    final repository = _libraryRepository;

    if (repository == null) {
      _showStatus('Library is unavailable.');
      return;
    }

    final wavPath = repository.audioFile(item.itemId).path;

    if (!await File(wavPath).exists()) {
      if (mounted) {
        setState(() {
          _status = 'Library audio is missing.';
        });
      }

      await _refreshLibrary();
      return;
    }

    await _playWavPath(wavPath);
  }

  Future<void> _renameLibraryItem(LibraryItemMetadata item) async {
    final repository = _libraryRepository;

    if (repository == null) {
      _showStatus('Library is unavailable.');
      return;
    }

    final title = await _promptForTitle(
      initialTitle: item.title,
      dialogTitle: 'Rename Library Item',
    );

    if (title == null || title == item.title) {
      return;
    }

    try {
      await repository.rename(item.itemId, title);
      await _refreshLibrary();

      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'Renamed library item.';
      });
    } catch (error, stackTrace) {
      debugPrint('VieNeu: rename failed: $error');
      debugPrint('$stackTrace');

      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'Rename failed: $error';
      });
    }
  }

  Future<void> _deleteLibraryItem(LibraryItemMetadata item) async {
    final repository = _libraryRepository;

    if (repository == null) {
      _showStatus('Library is unavailable.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Delete Library Item'),
          content: Text(
            'Delete "${item.title}" and its saved audio? '
            'This cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    try {
      final audioPath = repository.audioFile(item.itemId).path;

      if (_playbackController.currentPath == audioPath) {
        await _stopPlayback();
      }

      await repository.delete(item.itemId);
      await _refreshLibrary();

      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'Deleted library item.';
      });
    } catch (error, stackTrace) {
      debugPrint('VieNeu: delete failed: $error');
      debugPrint('$stackTrace');

      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'Delete failed: $error';
      });
    }
  }

  Future<String?> _promptForTitle({
    required String initialTitle,
    required String dialogTitle,
  }) {
    return showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return _TitleDialog(
          initialTitle: initialTitle,
          dialogTitle: dialogTitle,
        );
      },
    );
  }

  String _defaultLibraryTitle(String text) {
    final lines = text.split(RegExp(r'\r?\n'));
    final firstLine = lines
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => text.trim());

    if (firstLine.isEmpty) {
      return 'Saved audio';
    }

    const maximumLength = 80;

    if (firstLine.length <= maximumLength) {
      return firstLine;
    }

    return '${firstLine.substring(0, maximumLength - 3).trimRight()}...';
  }

  void _showStatus(String message) {
    if (!mounted) {
      return;
    }

    setState(() {
      _status = message;
    });
  }

  Widget _buildLibraryTab(BuildContext context) {
    final repository = _libraryRepository;

    if (repository == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            _libraryError ?? 'Library is unavailable.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _refreshLibrary,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(20),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Saved audio',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              if (_isLibraryLoading)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(_status, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: const ValueKey<String>('import-vshadow-button'),
                onPressed: _isLibraryLoading ? null : _importVshadowPackage,
                icon: const Icon(Icons.upload_file, size: 18),
                label: const Text('Import .vshadow'),
              ),
            ],
          ),
          if (_libraryError != null) ...[
            const SizedBox(height: 12),
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _libraryError!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          if (!_isLibraryLoading && _libraryItems.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    const Icon(Icons.library_music_outlined, size: 36),
                    const SizedBox(height: 8),
                    const Text('No saved audio yet.'),
                    const SizedBox(height: 4),
                    Text(
                      'Generate audio, then choose Save to Library.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          for (final item in _libraryItems) ...[
            LibraryItemCard(
              item: item,
              isCurrent:
                  _playbackController.currentPath ==
                  repository.audioFile(item.itemId).path,
              isPlaying: _isPlaying,
              onPlay: () => _playLibraryItem(item),
              onStop: _stopPlayback,
              onRename: () => _renameLibraryItem(item),
              onDelete: () => _deleteLibraryItem(item),
              onExportWav: () => _exportLibraryWav(item),
              onExportVshadow: () => _exportVshadowPackage(item),
            ),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }

  @override
  void dispose() {
    _documentOpenService.dispose();
    unawaited(_playbackController.dispose());
    _textController.dispose();
    unawaited(_tts.dispose());

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final engineReady = !_isInitializing && _voices.isNotEmpty;

    return HomeTabScaffold(
      selectedTab: _selectedTab,
      onTabSelected: (index) {
        setState(() {
          _selectedTab = index;
        });
      },
      generateTab: SingleChildScrollView(
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
                            if (_generatedWavPath != null ||
                                _previewedSpeechText != null) {
                              setState(() {
                                _generatedWavPath = null;
                                _previewedSpeechText = null;
                                _status = 'Text changed — preview and generate again.';
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

                OutlinedButton.icon(
                  onPressed: !engineReady || _isGenerating
                      ? null
                      : _previewSpeechText,
                  icon: const Icon(Icons.visibility_outlined),
                  label: const Text('Preview speech text'),
                ),
                if (_previewedSpeechText != null) ...[
                  const SizedBox(height: 8),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Text that will be spoken',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 6),
                          SelectableText(_previewedSpeechText!),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                // Action buttons
                Wrap(
                  alignment: WrapAlignment.start,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      key: const ValueKey<String>('generate-button'),
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
                      key: const ValueKey<String>('play-generated-button'),
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
                      key: const ValueKey<String>('stop-generated-button'),
                      onPressed: _isPlaying ? _stopPlayback : null,
                      icon: const Icon(Icons.stop, size: 18),
                      label: const Text('Stop'),
                    ),

                    OutlinedButton.icon(
                      key: const ValueKey<String>('download-button'),
                      onPressed:
                          _generatedWavPath == null ||
                              _isGenerating ||
                              _isPlaying
                          ? null
                          : _downloadGeneratedAudio,
                      icon: const Icon(Icons.download, size: 18),
                      label: const Text('Download'),
                    ),

                    FilledButton.tonalIcon(
                      key: const ValueKey<String>('save-library-button'),
                      onPressed:
                          _generatedWavPath == null ||
                              _isGenerating ||
                              _libraryRepository == null
                          ? null
                          : _saveGeneratedToLibrary,
                      icon: const Icon(Icons.library_add_outlined, size: 18),
                      label: const Text('Save to Library'),
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

                        Row(
                          children: [
                            Expanded(
                              child: DropdownButton<VietnameseVoice>(
                                key: const ValueKey<String>('voice-dropdown'),
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
                                onChanged:
                                    !engineReady || _isGenerating || _isPlaying
                                    ? null
                                    : (voice) {
                                        if (voice != null) {
                                          _selectVoice(voice);
                                        }
                                      },
                              ),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton.icon(
                              key: const ValueKey<String>(
                                'voice-preview-button',
                              ),
                              onPressed:
                                  !engineReady || _isGenerating || _isPlaying
                                  ? null
                                  : _previewSelectedVoice,
                              icon: const Icon(
                                Icons.volume_up_outlined,
                                size: 18,
                              ),
                              label: const Text('Preview'),
                            ),
                          ],
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
      libraryTab: _buildLibraryTab(context),
      isPlaying: _isPlaying,
      onStopPlayback: _stopPlayback,
    );
  }
}

class _TitleDialog extends StatefulWidget {
  const _TitleDialog({required this.initialTitle, required this.dialogTitle});

  final String initialTitle;
  final String dialogTitle;

  @override
  State<_TitleDialog> createState() => _TitleDialogState();
}

class _TitleDialogState extends State<_TitleDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialTitle,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.dialogTitle),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 120,
        decoration: const InputDecoration(
          labelText: 'Title',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final title = _controller.text.trim();

            if (title.isNotEmpty) {
              Navigator.of(context).pop(title);
            }
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
