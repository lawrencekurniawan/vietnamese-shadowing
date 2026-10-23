import 'package:share_plus/share_plus.dart' as share_plus;
import 'package:flutter/services.dart';

import 'app/home_page_environment.dart';
import 'app/preference_store.dart';
import 'backup/auto_backup_service.dart';
import 'backup/backup_folder_service.dart';
import 'conversation/conversation_line.dart';
import 'conversation/conversation_service.dart';
import 'conversation/open_subtitles_source.dart';
import 'conversation/subdl_source.dart';
import 'documents/document_open_service.dart';
import 'native/synthesis_service.dart';
import 'native/vieneu_asset_stager.dart';

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'library/library_metadata.dart';
import 'library/library_repository.dart';
import 'library/vshadow_backup.dart';
import 'library/vshadow_package.dart';
import 'library/wav_export_filename.dart';
import 'native/vieneu_ffi.dart';
import 'native/vieneu_synthesis_worker.dart';
import 'playback/playback_controller.dart';
import 'playback/playback_session.dart';
import 'practice/practice_assessment_service.dart';
import 'practice/practice_feedback.dart';
import 'practice/practice_recording_service.dart';
import 'practice/practice_repository.dart';
import 'practice/practice_speech_service.dart';
import 'practice/practice_take_metadata.dart';
import 'practice/vietnamese_tone.dart';
import 'practice/wav_segment_extractor.dart';
import 'ui/home_tab_scaffold.dart';
import 'ui/library_item_card.dart';
import 'ui/practice_feedback_card.dart';
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

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  static const String _defaultVoiceIdPreferenceKey = 'vieneu_default_voice_id';

  static const String _defaultVoicePreferenceKey = 'vieneu_default_voice';

  static const String _playbackSpeedPreferenceKey = 'vieneu_playback_speed';

  static const String _repeatCountPreferenceKey = 'vieneu_repeat_count';

  static const String _paddingSecondsPreferenceKey = 'vieneu_padding_seconds';

  static const String _pauseUsesAudioLengthPreferenceKey =
      'vieneu_pause_uses_audio_length';

  static const String _autoBackupEnabledPreferenceKey =
      'vshadow_auto_backup_enabled';

  static const String _autoBackupFolderNamePreferenceKey =
      'vshadow_auto_backup_folder_name';

  static const String _autoBackupLastSuccessPreferenceKey =
      'vshadow_auto_backup_last_success_utc';

  static const String _openSubtitlesApiKeyPreferenceKey =
      'vshadow_opensubtitles_api_key';
  static const String _subdlApiKeyPreferenceKey = 'vshadow_subdl_api_key';
  static const String _subdlFilmNamePreferenceKey = 'vshadow_subdl_film_name';

  static const String _vshadowUniformTypeIdentifier =
      'com.example.vietnameseshadowing.vshadow';

  static const String _vshadowBackupUniformTypeIdentifier =
      'com.example.vietnameseshadowing.vshadowbackup';

  static const String _voicePreviewText = 'Xin chào, đây là giọng đọc mẫu.';

  final TextEditingController _textController = TextEditingController(
    text: 'Hôm nay bạn khỏe không?',
  );

  final TextEditingController _openSubtitlesApiKeyController =
      TextEditingController();
  final TextEditingController _subdlApiKeyController = TextEditingController();
  final TextEditingController _subdlFilmNameController =
      TextEditingController();

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
  bool _isBackupBusy = false;
  String? _libraryError;

  late final BackupFolderService _backupFolderService;
  Timer? _autoBackupTimer;
  bool _autoBackupAvailable = true;
  bool _autoBackupEnabled = false;
  bool _autoBackupBusy = false;
  bool _autoBackupPending = false;
  String? _autoBackupFolderName;
  String? _autoBackupMessage;
  DateTime? _autoBackupLastSuccessUtc;

  late final PracticeRecorder _practiceRecorder;
  PracticeRepository? _practiceRepository;
  List<PracticeTakeMetadata> _practiceTakes = const [];
  String? _selectedPracticeItemId;
  bool _isPracticeLoading = false;
  bool _isRecording = false;
  bool _isSavingTake = false;
  String? _practiceError;
  String _practiceStatus = 'Ready to practice.';

  late ConversationService _conversationService;
  List<ConversationLine> _conversationLines = const <ConversationLine>[];
  ConversationLine? _selectedConversationLine;
  bool _isConversationLoading = false;
  bool _isConversationPreparing = false;
  bool _conversationIsOnline = false;
  bool _conversationIsLocal = false;
  bool _showOpenSubtitlesApiKey = false;
  ConversationOnlineProvider _onlineProvider =
      ConversationOnlineProvider.openSubtitles;
  String? _conversationError;
  String? _conversationInfo;
  String _conversationSourceLabel = 'Offline conversation pack';

  PracticeAssessmentService? _assessmentService;
  final Map<String, PracticeFeedback> _feedbackByTakeId =
      <String, PracticeFeedback>{};
  final Set<String> _assessingTakeIds = <String>{};
  String? _assessmentError;

  double _playbackSpeed = 1.0;
  int _repeatCount = 1;
  double _paddingSeconds = 0.5;
  bool _pauseUsesAudioLength = false;

  late final PlaybackController _playbackController;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    _tts = widget.environment?.synthesisService ?? VieNeuSynthesisWorker();

    _playbackController = PlaybackController(
      wavDurationReader: _getWavDurationSeconds,
      audioFactory: widget.environment?.playbackAudioFactory,
    );

    _backupFolderService =
        widget.environment?.backupFolderService ??
        PlatformBackupFolderService();

    _practiceRecorder =
        widget.environment?.practiceRecorder ?? PlatformPracticeRecorder();

    _conversationService =
        widget.environment?.conversationService ?? ConversationService();
    _conversationLines = _conversationService.builtinLines;
    _selectedConversationLine = _conversationLines.isEmpty
        ? null
        : _conversationLines.first;

    final injectedSpeechService = widget.environment?.speechService;

    if (injectedSpeechService != null) {
      _assessmentService = PracticeAssessmentService(
        speechService: injectedSpeechService,
      );
    } else if (Platform.isIOS) {
      _assessmentService = PracticeAssessmentService(
        speechService: PlatformPracticeSpeechService(),
      );
    }

    _documentOpenService = DocumentOpenService();
    _documentOpenService.setHandler(_handleExternalDocument);
    unawaited(_initializeDocumentOpen());

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initialize();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final leavingForeground =
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden;

    if (leavingForeground && _isRecording && !_isSavingTake) {
      unawaited(_stopPracticeRecording());
    }
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

          _practiceRepository = data.practiceRepository;
          _practiceTakes = List<PracticeTakeMetadata>.unmodifiable(
            data.practiceTakes,
          );
          _practiceError = data.practiceError;
          _selectedPracticeItemId = data.libraryItems.isEmpty
              ? null
              : data.libraryItems.first.itemId;

          _selectedTab = data.initialTab;
          _isInitializing = false;
          _status = data.status;
        });

        await _drainPendingExternalDocument();
        await _loadAutoBackupSettings();
        await _loadConversationSettings();
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

      if (widget.environment?.conversationService == null) {
        final conversationCache = Directory(
          '${applicationSupportDirectory.path}/vieneu/conversations',
        );
        _conversationService = ConversationService(
          openSubtitles: OpenSubtitlesSource(cacheDirectory: conversationCache),
          subdl: SubDLSource(cacheDirectory: conversationCache),
        );
      }

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

      PracticeRepository? practiceRepository;
      List<PracticeTakeMetadata> practiceTakes = const [];
      String? practiceError;

      try {
        practiceRepository = await PracticeRepository.open(
          applicationSupportDirectory: applicationSupportDirectory,
        );

        practiceTakes = await practiceRepository.list();

        debugPrint('VieNeu: loaded ${practiceTakes.length} practice takes.');
      } catch (error, stackTrace) {
        debugPrint('VieNeu: practice initialization failed: $error');
        debugPrint('$stackTrace');
        practiceError = 'Practice storage unavailable: $error';
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

        _practiceRepository = practiceRepository;
        _practiceTakes = List<PracticeTakeMetadata>.unmodifiable(practiceTakes);
        _practiceError = practiceError;
        _selectedPracticeItemId = libraryItems.isEmpty
            ? null
            : libraryItems.first.itemId;

        _isInitializing = false;
        _status = 'Native engine ready';
      });

      print('VieNeu: initialization complete.');

      await _drainPendingExternalDocument();
      await _loadAutoBackupSettings();
      await _loadConversationSettings();
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

    _scheduleAutoBackup();
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
    _scheduleAutoBackup();

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

  VshadowBackupSettings _currentBackupSettings() {
    final voice = _selectedVoice;

    return VshadowBackupSettings(
      defaultVoiceStableId: voice?.stableId,
      defaultVoicePresetName: voice?.name,
      playbackSpeed: _playbackSpeed,
      repeatCount: _repeatCount,
      paddingSeconds: _paddingSeconds,
      pauseUsesAudioLength: _pauseUsesAudioLength,
    );
  }

  Future<void> _loadAutoBackupSettings() async {
    var enabled = false;
    String? folderName;
    DateTime? lastSuccess;

    try {
      enabled =
          await _preferences.getBool(_autoBackupEnabledPreferenceKey) ?? false;
      folderName = await _preferences.getString(
        _autoBackupFolderNamePreferenceKey,
      );

      final lastSuccessRaw = await _preferences.getString(
        _autoBackupLastSuccessPreferenceKey,
      );

      lastSuccess = lastSuccessRaw == null
          ? null
          : DateTime.tryParse(lastSuccessRaw)?.toUtc();
    } catch (error, stackTrace) {
      debugPrint('VieNeu: failed to load automatic backup settings: $error');
      debugPrint('$stackTrace');
    }

    var available = true;
    var folderLookupFailed = false;
    String? message;
    BackupFolderInfo? folder;

    try {
      folder = await _backupFolderService.getFolder();
    } on MissingPluginException {
      available = false;
      folderLookupFailed = true;
      message =
          'Automatic backup folder access is only available on iOS. '
          'Use Back Up on other platforms.';
    } catch (error, stackTrace) {
      folderLookupFailed = true;
      debugPrint('VieNeu: failed to resolve backup folder: $error');
      debugPrint('$stackTrace');
      message = 'Backup folder unavailable: $error';
    }

    if (folder != null) {
      folderName = folder.name;

      try {
        await _preferences.setString(
          _autoBackupFolderNamePreferenceKey,
          folder.name,
        );
      } catch (_) {
        // The folder itself is still usable for this session.
      }
    } else if (!folderLookupFailed) {
      folderName = null;

      if (enabled && available) {
        message = 'Automatic backup needs a folder. Choose one again.';
      }
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _autoBackupAvailable = available;
      _autoBackupEnabled = enabled;
      _autoBackupFolderName = folderName;
      _autoBackupLastSuccessUtc = lastSuccess;
      _autoBackupMessage = message;
    });

    if (enabled && folder != null) {
      _scheduleAutoBackup(immediate: true);
    }
  }

  Future<void> _loadConversationSettings() async {
    try {
      final openSubtitlesKey = await _preferences.getString(
        _openSubtitlesApiKeyPreferenceKey,
      );
      final subdlKey = await _preferences.getString(_subdlApiKeyPreferenceKey);
      final subdlFilmName = await _preferences.getString(
        _subdlFilmNamePreferenceKey,
      );

      if (!mounted) {
        return;
      }

      if (openSubtitlesKey != null && openSubtitlesKey.isNotEmpty) {
        _openSubtitlesApiKeyController.text = openSubtitlesKey;
      }

      if (subdlKey != null && subdlKey.isNotEmpty) {
        _subdlApiKeyController.text = subdlKey;
      }

      if (subdlFilmName != null && subdlFilmName.isNotEmpty) {
        _subdlFilmNameController.text = subdlFilmName;
      }
    } catch (error, stackTrace) {
      debugPrint('VieNeu: failed to load online subtitle settings: $error');
      debugPrint('$stackTrace');
    }
  }

  Future<void> _toggleAutoBackup(bool enabled) async {
    if (!_autoBackupAvailable) {
      _showStatus('Automatic backup is unavailable on this platform.');
      return;
    }

    if (enabled && _autoBackupFolderName == null) {
      final selected = await _chooseAutoBackupFolder();

      if (!selected) {
        return;
      }
    }

    if (mounted) {
      setState(() {
        _autoBackupEnabled = enabled;
        _autoBackupMessage = enabled
            ? 'Automatic backup is on.'
            : 'Automatic backup is off.';
      });
    }

    try {
      await _preferences.setBool(_autoBackupEnabledPreferenceKey, enabled);
    } catch (error, stackTrace) {
      debugPrint('VieNeu: failed to save automatic backup setting: $error');
      debugPrint('$stackTrace');
    }

    if (enabled) {
      _scheduleAutoBackup(immediate: true);
    } else {
      _autoBackupTimer?.cancel();
      _autoBackupTimer = null;
    }
  }

  Future<bool> _chooseAutoBackupFolder() async {
    try {
      final folder = await _backupFolderService.chooseFolder();

      if (folder == null) {
        if (mounted) {
          setState(() {
            _autoBackupMessage = 'No backup folder selected.';
          });
        }
        return false;
      }

      try {
        await _preferences.setString(
          _autoBackupFolderNamePreferenceKey,
          folder.name,
        );
      } catch (error, stackTrace) {
        debugPrint('VieNeu: failed to save backup folder name: $error');
        debugPrint('$stackTrace');
      }

      if (!mounted) {
        return true;
      }

      setState(() {
        _autoBackupAvailable = true;
        _autoBackupFolderName = folder.name;
        _autoBackupMessage =
            'Automatic backups will be saved in ${folder.name}.';
      });

      if (_autoBackupEnabled) {
        _scheduleAutoBackup(immediate: true);
      }

      return true;
    } on MissingPluginException {
      if (mounted) {
        setState(() {
          _autoBackupAvailable = false;
          _autoBackupMessage =
              'Automatic backup folder access is only available on iOS.';
        });
      }
      return false;
    } catch (error, stackTrace) {
      debugPrint('VieNeu: failed to choose backup folder: $error');
      debugPrint('$stackTrace');

      if (mounted) {
        setState(() {
          _autoBackupMessage = 'Could not choose backup folder: $error';
        });
      }

      return false;
    }
  }

  void _scheduleAutoBackup({bool immediate = false}) {
    if (!_autoBackupEnabled || !_autoBackupAvailable) {
      return;
    }

    if (_autoBackupBusy) {
      _autoBackupPending = true;
      return;
    }

    _autoBackupTimer?.cancel();
    _autoBackupTimer = Timer(
      immediate ? Duration.zero : const Duration(seconds: 3),
      () {
        _autoBackupTimer = null;
        unawaited(_runAutoBackup());
      },
    );
  }

  Future<void> _runAutoBackup() async {
    if (!_autoBackupEnabled || !_autoBackupAvailable) {
      return;
    }

    if (_autoBackupBusy) {
      _autoBackupPending = true;
      return;
    }

    final repository = _libraryRepository;

    if (repository == null) {
      return;
    }

    if (_autoBackupFolderName == null) {
      if (mounted) {
        setState(() {
          _autoBackupMessage = 'Automatic backup needs a folder.';
        });
      }
      return;
    }

    setState(() {
      _autoBackupBusy = true;
      _autoBackupMessage = 'Saving automatic backup...';
    });

    try {
      final service = AutoBackupService(
        repository: repository,
        practiceRepository: _practiceRepository,
        folderService: _backupFolderService,
      );
      final result = await service.run(
        items: _libraryItems,
        settings: _currentBackupSettings(),
        takes: _practiceTakes,
      );

      try {
        await _preferences.setString(
          _autoBackupLastSuccessPreferenceKey,
          result.completedAtUtc.toIso8601String(),
        );
      } catch (error, stackTrace) {
        debugPrint('VieNeu: failed to save automatic backup timestamp: $error');
        debugPrint('$stackTrace');
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _autoBackupLastSuccessUtc = result.completedAtUtc;
        _autoBackupMessage = 'Automatic backup saved as ${result.fileName}.';
      });
    } on MissingPluginException {
      if (mounted) {
        setState(() {
          _autoBackupAvailable = false;
          _autoBackupMessage =
              'Automatic backup folder access is only available on iOS.';
        });
      }
    } catch (error, stackTrace) {
      debugPrint('VieNeu: automatic backup failed: $error');
      debugPrint('$stackTrace');

      if (mounted) {
        setState(() {
          _autoBackupMessage = 'Automatic backup failed: $error';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _autoBackupBusy = false;
        });
      }

      if (_autoBackupPending) {
        _autoBackupPending = false;
        _scheduleAutoBackup();
      }
    }
  }

  Future<void> _exportLibraryBackup() async {
    final repository = _libraryRepository;

    if (repository == null) {
      _showStatus('Library is unavailable.');
      return;
    }

    if (_isBackupBusy || _isLibraryLoading) {
      return;
    }

    setState(() {
      _isBackupBusy = true;
      _status = 'Preparing backup...';
    });

    try {
      final settings = _currentBackupSettings();
      final service = VshadowBackupService(
        repository: repository,
        practiceRepository: _practiceRepository,
      );
      final bytes = await service.exportBackup(
        items: _libraryItems,
        settings: settings,
        takes: _practiceTakes,
      );
      final suggestedName = buildVshadowBackupFilename(
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
            title: 'Vietnamese Shadowing Backup',
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
            _status = 'Backup share sheet closed.';
          });
        }

        return;
      }

      final saveLocation = await getSaveLocation(
        suggestedName: suggestedName,
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'Vietnamese Shadowing backup',
            extensions: ['vshadowbackup'],
            mimeTypes: ['application/zip', 'application/octet-stream'],
            uniformTypeIdentifiers: [_vshadowBackupUniformTypeIdentifier],
          ),
        ],
      );

      if (saveLocation == null) {
        if (mounted) {
          setState(() {
            _status = 'Backup canceled.';
          });
        }
        return;
      }

      await File(saveLocation.path).writeAsBytes(bytes, flush: true);

      if (mounted) {
        setState(() {
          _status = 'Backup saved.';
        });
      }
    } catch (error, stackTrace) {
      _reportBackupFailure(error, stackTrace);
    } finally {
      if (mounted) {
        setState(() {
          _isBackupBusy = false;
        });
      }
    }
  }

  Future<void> _importLibraryBackup() async {
    final repository = _libraryRepository;

    if (repository == null) {
      _showStatus('Library is unavailable.');
      return;
    }

    if (_isBackupBusy || _isLibraryLoading) {
      return;
    }

    setState(() {
      _isBackupBusy = true;
      _status = 'Choose a backup file...';
    });

    try {
      final selected = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'Vietnamese Shadowing backup',
            extensions: ['vshadowbackup'],
            mimeTypes: ['application/zip', 'application/octet-stream'],
            uniformTypeIdentifiers: [_vshadowBackupUniformTypeIdentifier],
          ),
        ],
      );

      if (selected == null) {
        if (mounted) {
          setState(() {
            _status = 'Backup restore canceled.';
          });
        }
        return;
      }

      if (await selected.length() > maxVshadowBackupBytes) {
        throw const FormatException('Backup exceeds the 512 MiB limit.');
      }

      await _importLibraryBackupBytes(repository, await selected.readAsBytes());
    } catch (error, stackTrace) {
      _reportBackupFailure(error, stackTrace);
    } finally {
      if (mounted) {
        setState(() {
          _isBackupBusy = false;
        });
      }
    }
  }

  Future<void> _importLibraryBackupBytes(
    LibraryRepository repository,
    Uint8List bytes,
  ) async {
    if (bytes.length > maxVshadowBackupBytes) {
      throw const FormatException('Backup exceeds the 512 MiB limit.');
    }

    if (mounted) {
      setState(() {
        _status = 'Restoring backup...';
      });
    }

    final service = VshadowBackupService(
      repository: repository,
      practiceRepository: _practiceRepository,
    );
    final result = await service.importBackup(bytes);

    await _refreshLibrary();
    await _refreshPracticeTakes();
    await _applyBackupSettings(result.manifest.settings);

    if (!mounted) {
      return;
    }

    final restoredCount = result.importedCount + result.skippedCount;
    final restoredTakeCount =
        result.importedTakeCount + result.skippedTakeCount;

    setState(() {
      if (restoredCount == 0 && restoredTakeCount == 0) {
        _status =
            'Backup restored. This backup has no saved audio or practice '
            'takes.';
      } else {
        _status =
            'Backup restored: ${result.importedCount} audio imported, '
            '${result.skippedCount} audio already present, '
            '${result.importedTakeCount} takes imported, '
            '${result.skippedTakeCount} takes already present.';
      }
      _selectedTab = 1;
    });
  }

  Future<void> _applyBackupSettings(VshadowBackupSettings settings) async {
    VietnameseVoice? restoredVoice;

    if (_voices.isNotEmpty &&
        (settings.defaultVoiceStableId != null ||
            settings.defaultVoicePresetName != null)) {
      restoredVoice = resolvePreferredVoice(
        catalog: VoiceCatalog.fromVoices(_voices),
        defaultVoice: defaultPreferredVoice(_voices),
        savedStableId: settings.defaultVoiceStableId,
        legacySavedVoiceId: settings.defaultVoicePresetName,
      );
    }

    if (mounted) {
      setState(() {
        _playbackSpeed = settings.playbackSpeed;
        _repeatCount = settings.repeatCount;
        _paddingSeconds = settings.paddingSeconds;
        _pauseUsesAudioLength = settings.pauseUsesAudioLength;

        if (restoredVoice != null) {
          _selectedVoice = restoredVoice;
          _generatedWavPath = null;
        }
      });
    }

    try {
      await _preferences.setDouble(
        _playbackSpeedPreferenceKey,
        settings.playbackSpeed,
      );
      await _preferences.setInt(
        _repeatCountPreferenceKey,
        settings.repeatCount,
      );
      await _preferences.setDouble(
        _paddingSecondsPreferenceKey,
        settings.paddingSeconds,
      );
      await _preferences.setBool(
        _pauseUsesAudioLengthPreferenceKey,
        settings.pauseUsesAudioLength,
      );

      if (restoredVoice != null) {
        await _preferences.setString(
          _defaultVoiceIdPreferenceKey,
          restoredVoice.stableId,
        );
        await _preferences.setString(
          _defaultVoicePreferenceKey,
          restoredVoice.id,
        );
      }
    } catch (error, stackTrace) {
      debugPrint('VieNeu: failed to persist restored backup settings: $error');
      debugPrint('$stackTrace');
    }

    _scheduleAutoBackup();
  }

  void _reportBackupFailure(Object error, StackTrace stackTrace) {
    debugPrint('VieNeu: backup operation failed: $error');
    debugPrint('$stackTrace');

    if (!mounted) {
      return;
    }

    setState(() {
      _status = 'Backup operation failed: $error';
    });
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

        final selectedPracticeItemId = _selectedPracticeItemId;

        if (selectedPracticeItemId == null ||
            !items.any((item) => item.itemId == selectedPracticeItemId)) {
          _selectedPracticeItemId = items.isEmpty ? null : items.first.itemId;
        }
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
      _scheduleAutoBackup();
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
      _scheduleAutoBackup();

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
      _scheduleAutoBackup();

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

  LibraryItemMetadata? get _selectedPracticeItem {
    final selectedId = _selectedPracticeItemId;

    if (selectedId == null) {
      return null;
    }

    for (final item in _libraryItems) {
      if (item.itemId == selectedId) {
        return item;
      }
    }

    return null;
  }

  Future<void> _loadOnlineConversationLines({bool forceRefresh = false}) async {
    if (_isConversationLoading) {
      return;
    }

    final provider = _onlineProvider;
    final isOpenSubtitles =
        provider == ConversationOnlineProvider.openSubtitles;
    final apiKey = isOpenSubtitles
        ? _openSubtitlesApiKeyController.text.trim()
        : _subdlApiKeyController.text.trim();
    final filmName = isOpenSubtitles
        ? null
        : _subdlFilmNameController.text.trim();

    setState(() {
      _isConversationLoading = true;
      _conversationError = null;
      _conversationInfo = null;
    });

    try {
      await _preferences.setString(provider.preferenceKey, apiKey);
    } catch (error, stackTrace) {
      debugPrint('VieNeu: failed to save ${provider.label} key: $error');
      debugPrint('$stackTrace');
    }

    if (!isOpenSubtitles) {
      try {
        await _preferences.setString(
          _subdlFilmNamePreferenceKey,
          filmName ?? '',
        );
      } catch (error, stackTrace) {
        debugPrint('VieNeu: failed to save SubDL film name: $error');
        debugPrint('$stackTrace');
      }
    }

    try {
      final result = await _conversationService.loadOnline(
        provider: provider,
        apiKey: apiKey,
        filmName: filmName,
        forceRefresh: forceRefresh,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _isConversationLoading = false;
        _conversationLines = result.lines;
        _selectedConversationLine = result.lines.isEmpty
            ? null
            : result.lines.first;
        _conversationIsOnline = result.isOnline;
        _conversationIsLocal = result.isLocal;
        _conversationSourceLabel = result.sourceLabel;

        if (result.isOnline) {
          _conversationInfo = result.warning;
          _conversationError = null;
        } else if (apiKey.isNotEmpty) {
          _conversationInfo = null;
          _conversationError = result.warning;
        } else {
          _conversationInfo = result.warning;
          _conversationError = null;
        }
      });
    } catch (error, stackTrace) {
      debugPrint('VieNeu: online conversation fetch failed: $error');
      debugPrint('$stackTrace');

      if (!mounted) {
        return;
      }

      setState(() {
        _isConversationLoading = false;
        _conversationError = '${provider.label} discovery failed: $error';
      });
    }
  }

  Future<void> _importConversationSubtitle() async {
    if (_isConversationLoading) {
      return;
    }

    XFile? file;

    try {
      file = await openFile(
        acceptedTypeGroups: const <XTypeGroup>[
          XTypeGroup(
            label: 'Subtitle files',
            extensions: <String>['srt', 'vtt', 'ass', 'ssa', 'zip'],
            mimeTypes: <String>['text/plain', 'text/vtt', 'application/zip'],
            uniformTypeIdentifiers: <String>['public.text', 'public.data'],
          ),
        ],
      );
    } catch (error, stackTrace) {
      debugPrint('VieNeu: subtitle picker failed: $error');
      debugPrint('$stackTrace');

      if (mounted) {
        setState(() {
          _conversationError = 'Could not open the subtitle picker: $error';
        });
      }
      return;
    }

    if (file == null) {
      return;
    }

    final selectedFile = file;

    if (!mounted) {
      return;
    }

    setState(() {
      _isConversationLoading = true;
      _conversationError = null;
      _conversationInfo = 'Reading ${selectedFile.name}...';
    });

    try {
      const maximumSubtitleBytes = 20 * 1024 * 1024;
      final length = await selectedFile.length();

      if (length > maximumSubtitleBytes) {
        throw const ConversationImportException(
          'The subtitle file is larger than 20 MB.',
        );
      }

      final bytes = await selectedFile.readAsBytes();

      if (bytes.length > maximumSubtitleBytes) {
        throw const ConversationImportException(
          'The subtitle file is larger than 20 MB.',
        );
      }

      final result = _conversationService.loadLocalSubtitle(
        fileName: selectedFile.name,
        bytes: bytes,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _isConversationLoading = false;
        _conversationLines = result.lines;
        _selectedConversationLine = result.lines.isEmpty
            ? null
            : result.lines.first;
        _conversationIsOnline = false;
        _conversationIsLocal = true;
        _conversationSourceLabel = result.sourceLabel;
        _conversationInfo = result.warning;
        _conversationError = null;
      });
    } catch (error, stackTrace) {
      debugPrint('VieNeu: subtitle import failed: $error');
      debugPrint('$stackTrace');

      if (!mounted) {
        return;
      }

      setState(() {
        _isConversationLoading = false;
        _conversationInfo = null;
        _conversationError = 'Could not import that subtitle: $error';
      });
    }
  }

  void _selectConversationLine(String? lineId) {
    if (lineId == null) {
      return;
    }

    for (final line in _conversationLines) {
      if (line.id == lineId) {
        setState(() {
          _selectedConversationLine = line;
        });
        return;
      }
    }
  }

  void _randomConversationLine() {
    final lines = _conversationLines;

    if (lines.isEmpty) {
      return;
    }

    final index = math.Random().nextInt(lines.length);

    setState(() {
      _selectedConversationLine = lines[index];
      _conversationInfo =
          'Picked a random line. Press “Hear reference” '
          'or “Save & Practice”.';
    });
  }

  Future<void> _previewConversationReference() async {
    final line = _selectedConversationLine;
    final voice = _selectedVoice;

    if (line == null) {
      setState(() {
        _conversationError = 'Choose a conversation line first.';
      });
      return;
    }

    if (voice == null) {
      setState(() {
        _conversationError = 'Select a voice before generating speech.';
      });
      return;
    }

    if (_isConversationPreparing || _isConversationLoading) {
      return;
    }

    if (_isRecording) {
      setState(() {
        _conversationError =
            'Stop the current recording before playing a reference.';
      });
      return;
    }

    if (_isPlaying) {
      await _stopPlayback();
    }

    setState(() {
      _isConversationPreparing = true;
      _conversationError = null;
      _conversationInfo = 'Generating the reference with ${voice.name}...';
    });

    try {
      final result = await _tts.synthesizeToWav(
        text: line.textForSpeech,
        voiceId: voice.id,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _isConversationPreparing = false;
        _conversationInfo = 'Reference ready. Listen, then shadow it.';
      });

      await _playWavPath(
        result.path,
        playbackSpeed: 1.0,
        repeatCount: 1,
        paddingSeconds: 0,
        pauseUsesAudioLength: false,
        playingStatus: 'Playing conversation reference...',
      );
    } catch (error, stackTrace) {
      debugPrint('VieNeu: conversation preview failed: $error');
      debugPrint('$stackTrace');

      if (!mounted) {
        return;
      }

      setState(() {
        _isConversationPreparing = false;
        _conversationError = 'Could not generate the reference: $error';
      });
    }
  }

  Future<void> _saveConversationToLibrary() async {
    final line = _selectedConversationLine;
    final voice = _selectedVoice;
    final repository = _libraryRepository;

    if (line == null) {
      setState(() {
        _conversationError = 'Choose a conversation line first.';
      });
      return;
    }

    if (voice == null) {
      setState(() {
        _conversationError = 'Select a voice before generating speech.';
      });
      return;
    }

    if (repository == null) {
      setState(() {
        _conversationError = 'The Library is unavailable.';
      });
      return;
    }

    if (_isConversationPreparing || _isConversationLoading) {
      return;
    }

    if (_isRecording) {
      setState(() {
        _conversationError =
            'Stop the current recording before saving a reference.';
      });
      return;
    }

    if (_isPlaying) {
      await _stopPlayback();
    }

    setState(() {
      _isConversationPreparing = true;
      _conversationError = null;
      _conversationInfo = 'Generating speech and saving to the Library...';
      _practiceStatus = 'Preparing conversation reference...';
    });

    try {
      String normalizedText;

      try {
        normalizedText = await _tts.previewSpeechText(line.textForSpeech);
      } catch (_) {
        normalizedText = line.textForSpeech;
      }

      final result = await _tts.synthesizeToWav(
        text: line.textForSpeech,
        voiceId: voice.id,
      );
      final item = await repository.saveFromWavFile(
        title: line.suggestedLibraryTitle,
        originalText: line.displayText,
        normalizedText: normalizedText,
        voice: VoiceMetadata.fromVoice(voice),
        sourceWavPath: result.path,
      );

      await _refreshLibrary();

      if (!mounted) {
        return;
      }

      setState(() {
        _isConversationPreparing = false;
        _selectedPracticeItemId = item.itemId;
        _selectedTab = 2;
        _practiceStatus =
            'Reference ready for ${item.title}. Listen, then record.';
        _conversationInfo =
            'Saved to the Library. The reference is ready in Practice.';
      });

      _scheduleAutoBackup();
    } catch (error, stackTrace) {
      debugPrint('VieNeu: conversation save failed: $error');
      debugPrint('$stackTrace');

      if (!mounted) {
        return;
      }

      setState(() {
        _isConversationPreparing = false;
        _conversationError = 'Could not save this line: $error';
        _practiceStatus = 'Conversation preparation failed.';
      });
    }
  }

  Future<void> _playToneGuideItem(
    PracticeFeedback feedback,
    ToneGuideItem item,
  ) async {
    if (!item.canPlay || _isPlaying || _isRecording) {
      return;
    }

    File? temporaryFile;

    try {
      final bytes = await File(feedback.referenceAudioPath).readAsBytes();
      final segment = WavSegmentExtractor.extract(
        bytes: bytes,
        startSeconds: item.startSeconds!,
        durationSeconds: item.durationSeconds!,
      );
      temporaryFile = File(
        '${Directory.systemTemp.path}/vshadow-tone-'
        '${DateTime.now().microsecondsSinceEpoch}.wav',
      );
      await temporaryFile.writeAsBytes(segment, flush: true);

      await _playWavPath(
        temporaryFile.path,
        playbackSpeed: 1.0,
        repeatCount: 1,
        paddingSeconds: 0,
        pauseUsesAudioLength: false,
        playingStatus: 'Playing ${item.text} · ${item.tone.label}...',
      );
    } catch (error, stackTrace) {
      debugPrint('VieNeu: tone segment playback failed: $error');
      debugPrint('$stackTrace');

      if (mounted) {
        setState(() {
          _practiceStatus = 'Could not play that word: $error';
        });
      }
    } finally {
      if (temporaryFile != null) {
        try {
          await temporaryFile.delete();
        } on FileSystemException {
          // The temporary file may already have been removed.
        }
      }
    }
  }

  Future<void> _assessPracticeTake(
    PracticeTakeMetadata take, {
    LibraryItemMetadata? item,
    bool automatic = false,
  }) async {
    if (!mounted) {
      return;
    }

    final service = _assessmentService;

    if (service == null) {
      if (mounted) {
        setState(() {
          _practiceStatus = 'Speech feedback is only available in the iOS app.';
        });
      }
      return;
    }

    if (_assessingTakeIds.contains(take.takeId)) {
      return;
    }

    final libraryRepository = _libraryRepository;
    final practiceRepository = _practiceRepository;
    final libraryItem = item ?? _findLibraryItem(take.libraryItemId);

    if (libraryRepository == null ||
        practiceRepository == null ||
        libraryItem == null) {
      if (mounted) {
        setState(() {
          _assessmentError =
              'The library item for this take is no longer available, so '
              'word feedback cannot be checked. The take is still playable.';
        });
      }
      return;
    }

    final referencePath = libraryRepository.audioFile(libraryItem.itemId).path;
    final userPath = practiceRepository.audioFile(take.takeId).path;

    if (!File(referencePath).existsSync() || !File(userPath).existsSync()) {
      if (mounted) {
        setState(() {
          _assessmentError =
              'The reference or take audio is missing, so feedback cannot '
              'be checked.';
        });
      }
      return;
    }

    setState(() {
      _assessingTakeIds.add(take.takeId);
      _assessmentError = null;
      _practiceStatus = automatic
          ? 'Listening back and comparing your take...'
          : 'Assessing ${take.itemTitle}...';
    });

    try {
      final referenceText = libraryItem.normalizedText.trim().isNotEmpty
          ? libraryItem.normalizedText
          : libraryItem.originalText;

      final feedback = await service.assess(
        referenceText: referenceText,
        referenceAudioPath: referencePath,
        userAudioPath: userPath,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _feedbackByTakeId[take.takeId] = feedback;
        _assessingTakeIds.remove(take.takeId);
        _practiceStatus = 'Feedback ready for ${take.itemTitle}.';
      });
    } catch (error, stackTrace) {
      debugPrint('VieNeu: practice assessment failed: $error');
      debugPrint('$stackTrace');

      if (!mounted) {
        return;
      }

      setState(() {
        _assessingTakeIds.remove(take.takeId);
        _assessmentError = 'Feedback unavailable: $error';
        _practiceStatus = 'The take was saved, but feedback failed.';
      });
    }
  }

  LibraryItemMetadata? _findLibraryItem(String itemId) {
    for (final item in _libraryItems) {
      if (item.itemId == itemId) {
        return item;
      }
    }

    return null;
  }

  Future<void> _refreshPracticeTakes() async {
    final repository = _practiceRepository;

    if (repository == null) {
      return;
    }

    setState(() {
      _isPracticeLoading = true;
    });

    try {
      final takes = await repository.list();

      if (!mounted) {
        return;
      }

      setState(() {
        _practiceTakes = takes;
        _practiceError = null;
        _isPracticeLoading = false;
      });
    } catch (error, stackTrace) {
      debugPrint('VieNeu: practice refresh failed: $error');
      debugPrint('$stackTrace');

      if (!mounted) {
        return;
      }

      setState(() {
        _practiceError = 'Practice refresh failed: $error';
        _isPracticeLoading = false;
      });
    }
  }

  Future<void> _playPracticeOriginal() async {
    final repository = _libraryRepository;
    final item = _selectedPracticeItem;

    if (repository == null || item == null) {
      setState(() {
        _practiceStatus = 'Choose a saved library item first.';
      });
      return;
    }

    final path = repository.audioFile(item.itemId).path;

    if (!await File(path).exists()) {
      if (mounted) {
        setState(() {
          _practiceStatus = 'The original audio is missing.';
        });
      }
      return;
    }

    await _playWavPath(path, playingStatus: 'Playing original...');
  }

  Future<void> _playPracticeTake(PracticeTakeMetadata take) async {
    final repository = _practiceRepository;

    if (repository == null) {
      return;
    }

    final path = repository.audioFile(take.takeId).path;

    if (!await File(path).exists()) {
      if (mounted) {
        setState(() {
          _practiceStatus = 'That take audio is missing.';
        });
      }
      return;
    }

    await _playWavPath(
      path,
      playbackSpeed: 1.0,
      repeatCount: 1,
      paddingSeconds: 0,
      pauseUsesAudioLength: false,
      playingStatus: 'Playing your take...',
    );
  }

  Future<void> _togglePracticeRecording() async {
    if (_isSavingTake) {
      return;
    }

    if (_isRecording) {
      await _stopPracticeRecording();
    } else {
      await _startPracticeRecording();
    }
  }

  Future<void> _startPracticeRecording() async {
    final item = _selectedPracticeItem;

    if (item == null) {
      setState(() {
        _practiceStatus = 'Choose a saved library item first.';
      });
      return;
    }

    if (_isPlaying) {
      await _stopPlayback();
    }

    setState(() {
      _isSavingTake = true;
      _practiceStatus = 'Requesting microphone...';
    });

    try {
      await _practiceRecorder.start();

      if (!mounted) {
        await _practiceRecorder.cancel();
        return;
      }

      setState(() {
        _isRecording = true;
        _isSavingTake = false;
        _practiceStatus = 'Recording. Tap Stop & Save when finished.';
      });
    } catch (error, stackTrace) {
      debugPrint('VieNeu: practice recording failed to start: $error');
      debugPrint('$stackTrace');

      if (!mounted) {
        return;
      }

      setState(() {
        _isRecording = false;
        _isSavingTake = false;
        _practiceStatus = 'Recording failed: $error';
      });
    }
  }

  Future<void> _stopPracticeRecording() async {
    final repository = _practiceRepository;
    final item = _selectedPracticeItem;

    if (repository == null || item == null) {
      await _practiceRecorder.cancel();
      if (mounted) {
        setState(() {
          _isRecording = false;
          _isSavingTake = false;
          _practiceStatus = 'Practice storage is unavailable.';
        });
      }
      return;
    }

    setState(() {
      _isSavingTake = true;
      _practiceStatus = 'Saving your take...';
    });

    PracticeRecordingResult? result;

    try {
      result = await _practiceRecorder.stop();
    } catch (error, stackTrace) {
      debugPrint('VieNeu: practice recording failed to stop: $error');
      debugPrint('$stackTrace');

      if (mounted) {
        setState(() {
          _isRecording = false;
          _isSavingTake = false;
          _practiceStatus = 'Could not stop recording: $error';
        });
      }
      return;
    }

    if (result == null) {
      if (mounted) {
        setState(() {
          _isRecording = false;
          _isSavingTake = false;
          _practiceStatus = 'No recording was captured.';
        });
      }
      return;
    }

    try {
      final savedTake = await repository.saveFromWavFile(
        libraryItemId: item.itemId,
        itemTitle: item.title,
        sourceWavPath: result.path,
      );

      await _refreshPracticeTakes();
      _scheduleAutoBackup();

      if (mounted) {
        setState(() {
          _isRecording = false;
          _isSavingTake = false;
          _practiceStatus = 'Saved a take for ${item.title}.';
        });
      }

      if (mounted && _assessmentService != null) {
        unawaited(_assessPracticeTake(savedTake, item: item, automatic: true));
      }
    } catch (error, stackTrace) {
      debugPrint('VieNeu: saving practice take failed: $error');
      debugPrint('$stackTrace');

      if (mounted) {
        setState(() {
          _isRecording = false;
          _isSavingTake = false;
          _practiceStatus = 'Could not save take: $error';
        });
      }
    } finally {
      unawaited(_deletePracticeRecordingFile(result.path));
    }
  }

  Future<void> _deletePracticeRecordingFile(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException {
      // The temporary recording may already have been removed.
    }
  }

  Future<void> _deletePracticeTake(PracticeTakeMetadata take) async {
    final repository = _practiceRepository;

    if (repository == null) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Delete Practice Take'),
          content: Text(
            'Delete this take from "${take.itemTitle}"? '
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
      if (_playbackController.currentPath ==
          repository.audioFile(take.takeId).path) {
        await _stopPlayback();
      }

      await repository.delete(take.takeId);
      _feedbackByTakeId.remove(take.takeId);
      _assessingTakeIds.remove(take.takeId);
      await _refreshPracticeTakes();
      _scheduleAutoBackup();

      if (mounted) {
        setState(() {
          _practiceStatus = 'Deleted practice take.';
        });
      }
    } catch (error, stackTrace) {
      debugPrint('VieNeu: delete practice take failed: $error');
      debugPrint('$stackTrace');

      if (mounted) {
        setState(() {
          _practiceStatus = 'Delete failed: $error';
        });
      }
    }
  }

  String _formatLocalDateTime(DateTime value) {
    final local = value.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');

    return '${local.year}-$month-$day $hour:$minute';
  }

  String _formatPracticeDuration(PracticeTakeMetadata take) {
    final duration = take.audio.durationSeconds;

    if (duration == null) {
      return '';
    }

    return '${duration.toStringAsFixed(1)} s';
  }

  Widget _buildConversationPracticeCard(BuildContext context) {
    final selected = _selectedConversationLine;
    final engineReady = !_isInitializing && _selectedVoice != null;
    final busy = _isConversationLoading || _isConversationPreparing;
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      key: const ValueKey<String>('conversation-practice-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.theater_comedy_outlined, color: colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Conversation practice',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: _conversationIsOnline
                        ? colorScheme.primaryContainer
                        : colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _conversationIsOnline
                        ? 'online'
                        : _conversationIsLocal
                        ? 'local file'
                        : 'offline pack',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Pick a natural exchange, hear the generated reference, then '
              'record your shadowing take. High-download subtitles are '
              'filtered for clean, non-AI Vietnamese lines.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              'Source: $_conversationSourceLabel',
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            if (_conversationLines.isEmpty)
              Text(
                'No conversation lines are available.',
                style: Theme.of(context).textTheme.bodyMedium,
              )
            else ...[
              DropdownButtonFormField<String>(
                key: ValueKey<String>(
                  'conversation-line-dropdown-${selected?.id}',
                ),
                initialValue: selected?.id,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Conversation line',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final line in _conversationLines)
                    DropdownMenuItem<String>(
                      value: line.id,
                      child: Text(
                        line.suggestedLibraryTitle,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: busy ? null : _selectConversationLine,
              ),
              if (selected != null) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    selected.displayText,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${selected.sourceTitle} · ${selected.sourceDetail}',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      key: const ValueKey<String>('conversation-random'),
                      onPressed: busy ? null : _randomConversationLine,
                      icon: const Icon(Icons.casino_outlined, size: 18),
                      label: const Text('Random line'),
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey<String>('conversation-import-file'),
                      onPressed: busy ? null : _importConversationSubtitle,
                      icon: const Icon(Icons.file_open_outlined, size: 18),
                      label: const Text('Import subtitle'),
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey<String>('conversation-preview'),
                      onPressed: engineReady && !busy && !_isPlaying
                          ? _previewConversationReference
                          : null,
                      icon: const Icon(Icons.volume_up_outlined, size: 18),
                      label: const Text('Hear reference'),
                    ),
                    FilledButton.icon(
                      key: const ValueKey<String>('conversation-save-practice'),
                      onPressed: engineReady && !busy
                          ? _saveConversationToLibrary
                          : null,
                      icon: const Icon(Icons.mic_none, size: 18),
                      label: const Text('Save & Practice'),
                    ),
                  ],
                ),
              ],
            ],
            if (busy) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
            if (_conversationInfo != null) ...[
              const SizedBox(height: 10),
              Text(
                _conversationInfo!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (_conversationError != null) ...[
              const SizedBox(height: 10),
              Text(
                _conversationError!,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colorScheme.error),
              ),
            ],
            const SizedBox(height: 6),
            ExpansionTile(
              key: const ValueKey<String>('conversation-online-section'),
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 4),
              title: const Text('Online subtitle source'),
              subtitle: Text(
                'Optional. Search high-download Vietnamese movie subtitles. '
                'If one provider is blocked, switch to the other.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              children: [
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<ConversationOnlineProvider>(
                    key: const ValueKey<String>('conversation-provider'),
                    segments: const <ButtonSegment<ConversationOnlineProvider>>[
                      ButtonSegment<ConversationOnlineProvider>(
                        value: ConversationOnlineProvider.openSubtitles,
                        label: Text('OpenSubtitles'),
                      ),
                      ButtonSegment<ConversationOnlineProvider>(
                        value: ConversationOnlineProvider.subdl,
                        label: Text('SubDL'),
                      ),
                    ],
                    selected: <ConversationOnlineProvider>{_onlineProvider},
                    onSelectionChanged: _isConversationLoading
                        ? null
                        : (selection) {
                            final provider = selection.first;
                            setState(() {
                              _onlineProvider = provider;
                              _conversationError = null;
                              _conversationInfo =
                                  '${provider.label} selected. Add its API key '
                                  'and fetch lines.';
                            });
                          },
                  ),
                ),
                const SizedBox(height: 10),
                if (_onlineProvider == ConversationOnlineProvider.openSubtitles)
                  TextField(
                    key: const ValueKey<String>('conversation-api-key-open'),
                    controller: _openSubtitlesApiKeyController,
                    enabled: !_isConversationLoading,
                    obscureText: !_showOpenSubtitlesApiKey,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: 'OpenSubtitles API key',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        tooltip: _showOpenSubtitlesApiKey
                            ? 'Hide API key'
                            : 'Show API key',
                        onPressed: () {
                          setState(() {
                            _showOpenSubtitlesApiKey =
                                !_showOpenSubtitlesApiKey;
                          });
                        },
                        icon: Icon(
                          _showOpenSubtitlesApiKey
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                        ),
                      ),
                    ),
                  )
                else ...[
                  TextField(
                    key: const ValueKey<String>('conversation-api-key-subdl'),
                    controller: _subdlApiKeyController,
                    enabled: !_isConversationLoading,
                    obscureText: !_showOpenSubtitlesApiKey,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: 'SubDL API key',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        tooltip: _showOpenSubtitlesApiKey
                            ? 'Hide API key'
                            : 'Show API key',
                        onPressed: () {
                          setState(() {
                            _showOpenSubtitlesApiKey =
                                !_showOpenSubtitlesApiKey;
                          });
                        },
                        icon: Icon(
                          _showOpenSubtitlesApiKey
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const ValueKey<String>('conversation-subdl-film'),
                    controller: _subdlFilmNameController,
                    enabled: !_isConversationLoading,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Film name (optional)',
                      hintText: 'e.g. Inception, Mắt biếc',
                      helperText:
                          'Leave blank to pick a well-known film at random.',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      key: const ValueKey<String>('conversation-find-online'),
                      onPressed: _isConversationLoading
                          ? null
                          : () => _loadOnlineConversationLines(),
                      icon: const Icon(Icons.cloud_download_outlined, size: 18),
                      label: Text('Find ${_onlineProvider.label} lines'),
                    ),
                    if (_conversationIsOnline)
                      OutlinedButton.icon(
                        key: const ValueKey<String>(
                          'conversation-download-new',
                        ),
                        onPressed: _isConversationLoading
                            ? null
                            : () => _loadOnlineConversationLines(
                                forceRefresh: true,
                              ),
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('Download new'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Online downloads are subject to each provider\'s quota. '
                  'Subtitles remain the property of their creators; use them '
                  'for personal study only. You can also import a subtitle '
                  'file from this device. Without an API key, the offline '
                  'conversation pack is always available.',
                  style: Theme.of(context).textTheme.labelSmall
                      ?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPracticeTab(BuildContext context) {
    final repository = _practiceRepository;

    if (repository == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            _practiceError ?? 'Practice storage is unavailable.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
      );
    }

    final selectedItem = _selectedPracticeItem;
    final canRecord =
        selectedItem != null &&
        !_isSavingTake &&
        !_isPracticeLoading &&
        _assessingTakeIds.isEmpty;

    return RefreshIndicator(
      onRefresh: _refreshPracticeTakes,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(20),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Practice',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              if (_isPracticeLoading)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(_practiceStatus, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 12),
          _buildConversationPracticeCard(context),
          const SizedBox(height: 12),
          if (_libraryItems.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    const Icon(Icons.library_music_outlined, size: 36),
                    const SizedBox(height: 8),
                    const Text('No library audio to practice yet.'),
                    const SizedBox(height: 4),
                    Text(
                      'Generate audio and save it to the Library first.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            )
          else ...[
            KeyedSubtree(
              key: ValueKey<String>(
                'practice-item-dropdown-state-${selectedItem?.itemId}',
              ),
              child: DropdownButtonFormField<String>(
                key: const ValueKey<String>('practice-item-dropdown'),
                initialValue: selectedItem?.itemId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Practice this item',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final item in _libraryItems)
                    DropdownMenuItem<String>(
                      value: item.itemId,
                      child: Text(item.title, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (value) {
                  setState(() {
                    _selectedPracticeItemId = value;
                    _practiceStatus = 'Ready to practice.';
                  });
                },
              ),
            ),
            if (selectedItem != null) ...[
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        selectedItem.title,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        selectedItem.originalText,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            key: const ValueKey<String>(
                              'practice-play-original',
                            ),
                            onPressed: _isPlaying || _isRecording
                                ? null
                                : _playPracticeOriginal,
                            icon: const Icon(Icons.play_arrow, size: 18),
                            label: const Text('Play Original'),
                          ),
                          FilledButton.icon(
                            key: const ValueKey<String>(
                              'practice-record-button',
                            ),
                            onPressed: canRecord
                                ? _togglePracticeRecording
                                : null,
                            icon: Icon(
                              _isRecording ? Icons.stop : Icons.mic,
                              size: 18,
                            ),
                            label: Text(
                              _isRecording ? 'Stop & Save' : 'Record',
                            ),
                          ),
                        ],
                      ),
                      if (_isRecording) ...[
                        const SizedBox(height: 10),
                        Text(
                          'Recording…',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                      if (_isSavingTake) ...[
                        const SizedBox(height: 12),
                        const LinearProgressIndicator(),
                      ],
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Text('Your takes', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (_practiceTakes.isEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      const Icon(Icons.mic_none, size: 36),
                      const SizedBox(height: 8),
                      const Text('No practice takes yet.'),
                      const SizedBox(height: 4),
                      Text(
                        'Choose an item, record yourself, and compare with '
                        'the original.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            for (final take in _practiceTakes) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        take.itemTitle,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${_formatLocalDateTime(take.createdAtUtc)}'
                        '${_formatPracticeDuration(take).isEmpty ? '' : ' · ${_formatPracticeDuration(take)}'}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            key: ValueKey<String>(
                              'practice-play-take-${take.takeId}',
                            ),
                            onPressed: _isPlaying || _isRecording
                                ? null
                                : () => _playPracticeTake(take),
                            icon: const Icon(Icons.play_arrow, size: 18),
                            label: const Text('Play Take'),
                          ),
                          OutlinedButton.icon(
                            key: ValueKey<String>(
                              'practice-assess-take-${take.takeId}',
                            ),
                            onPressed:
                                _isPlaying ||
                                    _isRecording ||
                                    _assessingTakeIds.isNotEmpty
                                ? null
                                : () => _assessPracticeTake(take),
                            icon: const Icon(Icons.insights_outlined, size: 18),
                            label: const Text('Assess'),
                          ),
                          TextButton.icon(
                            key: ValueKey<String>(
                              'practice-delete-take-${take.takeId}',
                            ),
                            onPressed: _isPlaying || _isRecording
                                ? null
                                : () => _deletePracticeTake(take),
                            icon: const Icon(Icons.delete_outline, size: 18),
                            label: const Text('Delete'),
                          ),
                        ],
                      ),
                      if (_assessingTakeIds.contains(take.takeId)) ...[
                        const SizedBox(height: 8),
                        const LinearProgressIndicator(),
                      ],
                      if (_feedbackByTakeId[take.takeId] != null) ...[
                        const SizedBox(height: 8),
                        PracticeFeedbackCard(
                          feedback: _feedbackByTakeId[take.takeId]!,
                          isPlaying: _isPlaying,
                          enabled: !_isRecording,
                          onPlayTone: _playToneGuideItem,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ],
          if (_assessmentError != null) ...[
            const SizedBox(height: 12),
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _assessmentError!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ),
          ],
          if (_practiceError != null) ...[
            const SizedBox(height: 12),
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _practiceError!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
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
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.cloud_outlined, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        'Backup',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Save your library, settings, and practice takes as one '
                    'file. In the Files sheet, choose iCloud Drive or Google '
                    'Drive.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    key: const ValueKey<String>('auto-backup-switch'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: _autoBackupEnabled,
                    onChanged: !_autoBackupAvailable || _isBackupBusy
                        ? null
                        : _toggleAutoBackup,
                    title: const Text('Automatic backup'),
                    subtitle: Text(
                      !_autoBackupAvailable
                          ? 'Available on iOS.'
                          : _autoBackupFolderName == null
                          ? 'Choose a folder in Files, such as iCloud Drive '
                                'or Google Drive.'
                          : 'Writes one rolling file to '
                                '${_autoBackupFolderName!} after changes.',
                    ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        key: const ValueKey<String>(
                          'auto-backup-folder-button',
                        ),
                        onPressed:
                            !_autoBackupAvailable ||
                                _isBackupBusy ||
                                _isLibraryLoading
                            ? null
                            : _chooseAutoBackupFolder,
                        icon: const Icon(Icons.folder_open, size: 18),
                        label: Text(
                          _autoBackupFolderName == null
                              ? 'Choose Folder'
                              : 'Change Folder',
                        ),
                      ),
                      if (_autoBackupEnabled)
                        OutlinedButton.icon(
                          key: const ValueKey<String>('auto-backup-now-button'),
                          onPressed: _autoBackupBusy || _isBackupBusy
                              ? null
                              : _runAutoBackup,
                          icon: const Icon(Icons.save_outlined, size: 18),
                          label: const Text('Back Up Now'),
                        ),
                    ],
                  ),
                  if (_autoBackupMessage != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _autoBackupMessage!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  if (_autoBackupLastSuccessUtc != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Last automatic backup: '
                      '${_formatLocalDateTime(_autoBackupLastSuccessUtc!)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.tonalIcon(
                        key: const ValueKey<String>('backup-library-button'),
                        onPressed: _isBackupBusy || _isLibraryLoading
                            ? null
                            : _exportLibraryBackup,
                        icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                        label: const Text('Back Up'),
                      ),
                      OutlinedButton.icon(
                        key: const ValueKey<String>('restore-backup-button'),
                        onPressed: _isBackupBusy || _isLibraryLoading
                            ? null
                            : _importLibraryBackup,
                        icon: const Icon(
                          Icons.cloud_download_outlined,
                          size: 18,
                        ),
                        label: const Text('Restore'),
                      ),
                    ],
                  ),
                  if (_isBackupBusy || _autoBackupBusy) ...[
                    const SizedBox(height: 12),
                    const LinearProgressIndicator(),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoBackupTimer?.cancel();
    _documentOpenService.dispose();
    unawaited(_practiceRecorder.cancel());
    unawaited(_playbackController.dispose());
    _textController.dispose();
    _openSubtitlesApiKeyController.dispose();
    _subdlApiKeyController.dispose();
    _subdlFilmNameController.dispose();
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
                                      _scheduleAutoBackup();
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
                                        _scheduleAutoBackup();
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
                                        _scheduleAutoBackup();
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
                                        _scheduleAutoBackup();
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
      practiceTab: _buildPracticeTab(context),
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
