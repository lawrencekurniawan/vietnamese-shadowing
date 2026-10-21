import '../library/library_metadata.dart';
import '../library/library_repository.dart';
import '../native/synthesis_service.dart';
import '../native/vieneu_ffi.dart';
import '../playback/playback_session.dart';
import 'preference_store.dart';

/// Preloaded state used by tests and other embedders.
///
/// Production startup uses the normal asset staging and worker initialization
/// path instead of this class.
class HomeBootstrap {
  const HomeBootstrap({
    required this.voices,
    required this.selectedVoice,
    this.libraryRepository,
    this.libraryItems = const <LibraryItemMetadata>[],
    this.libraryError,
    this.playbackSpeed = 1.0,
    this.repeatCount = 1,
    this.paddingSeconds = 0.5,
    this.pauseUsesAudioLength = false,
    this.initialTab = 0,
    this.status = 'Native engine ready',
  });

  final List<VietnameseVoice> voices;
  final VietnameseVoice selectedVoice;
  final LibraryRepository? libraryRepository;
  final List<LibraryItemMetadata> libraryItems;
  final String? libraryError;
  final double playbackSpeed;
  final int repeatCount;
  final double paddingSeconds;
  final bool pauseUsesAudioLength;
  final int initialTab;
  final String status;
}

/// Injectable runtime dependencies for [HomePage].
class HomePageEnvironment {
  const HomePageEnvironment({
    required this.synthesisService,
    required this.bootstrap,
    this.preferences,
    this.playbackAudioFactory,
  });

  final SynthesisService synthesisService;
  final Future<HomeBootstrap> Function() bootstrap;
  final PreferenceStore? preferences;
  final PlaybackAudio Function()? playbackAudioFactory;
}
