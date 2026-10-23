import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vietnamese_shadowing/app/home_page_environment.dart';
import 'package:vietnamese_shadowing/library/library_ids.dart';
import 'package:vietnamese_shadowing/library/library_metadata.dart';
import 'package:vietnamese_shadowing/library/library_repository.dart';
import 'package:vietnamese_shadowing/main.dart';
import 'package:vietnamese_shadowing/native/vieneu_ffi.dart';
import 'package:vietnamese_shadowing/practice/practice_recording_service.dart';
import 'package:vietnamese_shadowing/practice/practice_repository.dart';
import 'package:vietnamese_shadowing/practice/practice_take_metadata.dart';
import 'package:vietnamese_shadowing/ui/home_tab_scaffold.dart';

import 'support/fake_playback_audio.dart';
import 'support/fake_synthesis_service.dart';
import 'support/memory_preference_store.dart';
import 'support/wav_fixture.dart';

class _FakePracticeRecorder implements PracticeRecorder {
  _FakePracticeRecorder(this.recordingPath);

  final String recordingPath;
  bool _isRecording = false;
  int startCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;

  @override
  bool get isRecording => _isRecording;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> start() async {
    startCalls++;
    _isRecording = true;
  }

  @override
  Future<PracticeRecordingResult?> stop() async {
    stopCalls++;
    _isRecording = false;
    return PracticeRecordingResult(path: recordingPath, durationSeconds: 0.1);
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
    _isRecording = false;
  }
}

class _FakePracticeRepository extends PracticeRepository {
  _FakePracticeRepository({
    required super.applicationSupportDirectory,
    required this.playbackPath,
  });

  final String playbackPath;
  final List<PracticeTakeMetadata> takes = <PracticeTakeMetadata>[];

  @override
  Future<void> initialize() async {}

  @override
  Future<List<PracticeTakeMetadata>> list() async =>
      List<PracticeTakeMetadata>.unmodifiable(takes);

  @override
  Future<PracticeTakeMetadata?> read(String takeId) async {
    for (final take in takes) {
      if (take.takeId == takeId) {
        return take;
      }
    }

    return null;
  }

  @override
  Future<PracticeTakeMetadata> saveFromWavFile({
    required String libraryItemId,
    required String itemTitle,
    required String sourceWavPath,
    String? takeId,
    DateTime? createdAtUtc,
  }) async {
    final metadata = buildPracticeTakeMetadata(
      takeId: takeId ?? generateLibraryItemId(),
      libraryItemId: libraryItemId,
      itemTitle: itemTitle,
      audioBytes: buildTestWav(sampleRate: 44100, sampleFrames: 4410),
      createdAtUtc: createdAtUtc ?? DateTime.now().toUtc(),
    );

    takes.insert(0, metadata);
    return metadata;
  }

  @override
  File audioFile(String takeId) => File(playbackPath);

  @override
  Future<void> delete(String takeId) async {
    takes.removeWhere((take) => take.takeId == takeId);
  }
}

void main() {
  const adamVoice = VietnameseVoice(
    id: 'Adam',
    name: 'Adam',
    description: 'Nam · Nam · Giọng đọc tự nhiên',
    gender: 'male',
    accent: 'Nam',
    style: 'tu_nhien',
  );

  const thaiSonVoice = VietnameseVoice(
    id: 'Thái Sơn',
    name: 'Thái Sơn',
    description: 'Nam · Nam · Phong cách kể chuyện',
    gender: 'male',
    accent: 'Nam',
    style: 'doc_truyen',
  );

  const voiceMetadata = VoiceMetadata(
    stableId: 'adam',
    presetName: 'Adam',
    displayName: 'Adam',
    description: 'Nam · Nam · Giọng đọc tự nhiên',
    gender: 'male',
    accent: 'Nam',
    style: 'tu_nhien',
  );

  testWidgets('records, saves, and plays a practice take', (tester) async {
    final temporaryDirectory = Directory.systemTemp.createTempSync(
      'vshadow-practice-flow-',
    );
    final sourceWav = File('${temporaryDirectory.path}/source.wav')
      ..writeAsBytesSync(buildTestWav(sampleRate: 48000, sampleFrames: 4800));
    final recordingPath = '${temporaryDirectory.path}/take.wav';
    final library = await tester.runAsync(
      () => LibraryRepository.open(
        applicationSupportDirectory: temporaryDirectory,
      ),
    );
    final practice = _FakePracticeRepository(
      applicationSupportDirectory: temporaryDirectory,
      playbackPath: sourceWav.path,
    );
    final item = await tester.runAsync(
      () => library!.saveAudioBytes(
        title: 'Morning practice',
        originalText: 'Xin chào buổi sáng',
        normalizedText: 'xin chào buổi sáng',
        voice: voiceMetadata,
        audioBytes: buildTestWav(sampleRate: 48000, sampleFrames: 4800),
      ),
    );
    final recorder = _FakePracticeRecorder(recordingPath);
    final playback = FakePlaybackAudio();

    addTearDown(() {
      temporaryDirectory.deleteSync(recursive: true);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          environment: HomePageEnvironment(
            synthesisService: FakeSynthesisService(
              voices: const [adamVoice, thaiSonVoice],
              wavPath: sourceWav.path,
            ),
            preferences: MemoryPreferenceStore(),
            playbackAudioFactory: () => playback,
            practiceRecorder: recorder,
            bootstrap: () async {
              return HomeBootstrap(
                voices: const [adamVoice, thaiSonVoice],
                selectedVoice: adamVoice,
                libraryRepository: library,
                libraryItems: <LibraryItemMetadata>[item!],
                practiceRepository: practice,
                practiceTakes: const [],
              );
            },
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(HomeTabScaffold.practiceTabKey));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'Practice'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey<String>('practice-item-dropdown')),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    expect(find.text('Morning practice'), findsWidgets);
    expect(find.text('No practice takes yet.'), findsOneWidget);

    final recordButton = find.byKey(
      const ValueKey<String>('practice-record-button'),
    );
    await tester.ensureVisible(recordButton);
    await tester.tap(recordButton);
    await tester.pump();
    await tester.pump();

    expect(recorder.startCalls, 1);
    expect(find.text('Stop & Save'), findsOneWidget);
    expect(find.text('Recording…'), findsOneWidget);

    await tester.tap(recordButton);
    await tester.pump();
    await tester.pump();

    expect(recorder.stopCalls, 1);
    await tester.drag(find.byType(Scrollable).last, const Offset(0, 900));
    await tester.pumpAndSettle();
    expect(find.textContaining('Saved a take'), findsOneWidget);

    final takes = await practice.list();
    expect(takes, hasLength(1));
    expect(takes.single.itemTitle, 'Morning practice');
    expect(find.text('No practice takes yet.'), findsNothing);

    final playTake = find.byKey(
      ValueKey<String>('practice-play-take-${takes.single.takeId}'),
    );
    await tester.scrollUntilVisible(
      playTake,
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(playTake);
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pump();

    expect(playback.playCount, 1);
    expect(playback.playedPaths, [
      practice.audioFile(takes.single.takeId).path,
    ]);
  });
}
