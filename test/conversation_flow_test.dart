import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vietnamese_shadowing/app/home_page_environment.dart';
import 'package:vietnamese_shadowing/conversation/conversation_service.dart';
import 'package:vietnamese_shadowing/main.dart';
import 'package:vietnamese_shadowing/native/vieneu_ffi.dart';
import 'package:vietnamese_shadowing/practice/practice_repository.dart';
import 'package:vietnamese_shadowing/practice/practice_take_metadata.dart';
import 'package:vietnamese_shadowing/ui/home_tab_scaffold.dart';

import 'support/fake_library_repository.dart';
import 'support/fake_playback_audio.dart';
import 'support/fake_synthesis_service.dart';
import 'support/memory_preference_store.dart';
import 'support/wav_fixture.dart';

class _EmptyPracticeRepository extends PracticeRepository {
  _EmptyPracticeRepository({required super.applicationSupportDirectory});

  @override
  Future<void> initialize() async {}

  @override
  Future<List<PracticeTakeMetadata>> list() async =>
      const <PracticeTakeMetadata>[];

  @override
  Future<PracticeTakeMetadata?> read(String takeId) async => null;

  @override
  Future<PracticeTakeMetadata> saveFromWavFile({
    required String libraryItemId,
    required String itemTitle,
    required String sourceWavPath,
    String? takeId,
    DateTime? createdAtUtc,
  }) {
    throw UnimplementedError();
  }

  @override
  File audioFile(String takeId) => File('/fake-take/$takeId.wav');

  @override
  Future<void> delete(String takeId) async {}
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

  testWidgets('saves a conversation line to the library and practice tab', (
    tester,
  ) async {
    final temporaryDirectory = Directory.systemTemp.createTempSync(
      'vshadow-conversation-flow-',
    );
    final sourceWav = File('${temporaryDirectory.path}/source.wav')
      ..writeAsBytesSync(buildTestWav(sampleRate: 48000, sampleFrames: 4800));
    addTearDown(() => temporaryDirectory.deleteSync(recursive: true));

    final synthesis = FakeSynthesisService(
      voices: const <VietnameseVoice>[adamVoice, thaiSonVoice],
      wavPath: sourceWav.path,
    );
    final library = FakeLibraryRepository(
      applicationSupportDirectory: temporaryDirectory,
    );
    final practice = _EmptyPracticeRepository(
      applicationSupportDirectory: temporaryDirectory,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          environment: HomePageEnvironment(
            synthesisService: synthesis,
            preferences: MemoryPreferenceStore(),
            playbackAudioFactory: () => FakePlaybackAudio(),
            conversationService: ConversationService(),
            bootstrap: () async {
              return HomeBootstrap(
                voices: const <VietnameseVoice>[adamVoice, thaiSonVoice],
                selectedVoice: adamVoice,
                libraryRepository: library,
                practiceRepository: practice,
              );
            },
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(HomeTabScaffold.practiceTabKey));
    await tester.pump(const Duration(milliseconds: 300));

    final saveButton = find.byKey(
      const ValueKey<String>('conversation-save-practice'),
    );
    await tester.scrollUntilVisible(
      saveButton,
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -220));
    await tester.pumpAndSettle();
    await tester.tap(saveButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(synthesis.synthesizeCalls, 1);
    expect(synthesis.synthesizeVoiceIds, <String>['Adam']);
    expect(synthesis.synthesizeTexts.single, contains('Hôm nay trời đẹp quá'));
    expect(library.saveFromWavCalls, 1);
    expect(library.items, hasLength(1));
    expect(library.items.single.originalText, contains('Hôm nay trời đẹp quá'));
    expect(
      library.items.single.title,
      startsWith('Everyday Vietnamese — Hôm nay trời đẹp quá'),
    );
    await tester.drag(find.byType(Scrollable).last, const Offset(0, 900));
    await tester.pumpAndSettle();
    expect(find.textContaining('Saved to the Library'), findsOneWidget);
    expect(find.textContaining('Reference ready for'), findsOneWidget);
  });
}
