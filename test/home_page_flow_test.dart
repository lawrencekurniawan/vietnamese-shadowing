import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vietnamese_shadowing/app/home_page_environment.dart';
import 'package:vietnamese_shadowing/documents/document_open_service.dart';
import 'package:vietnamese_shadowing/library/library_metadata.dart';
import 'package:vietnamese_shadowing/library/library_repository.dart';
import 'package:vietnamese_shadowing/library/vshadow_package.dart';
import 'package:vietnamese_shadowing/main.dart';
import 'package:vietnamese_shadowing/native/vieneu_ffi.dart';
import 'package:vietnamese_shadowing/ui/home_tab_scaffold.dart';

import 'support/fake_library_repository.dart';
import 'support/fake_playback_audio.dart';
import 'support/fake_synthesis_service.dart';
import 'support/memory_preference_store.dart';
import 'support/wav_fixture.dart';

const documentChannel = MethodChannel(DocumentOpenService.channelName);
const codec = StandardMethodCodec();

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

  testWidgets('generates, saves, plays, stops, and switches tabs', (
    tester,
  ) async {
    final temporaryDirectory = Directory.systemTemp.createTempSync(
      'vshadow-home-flow-',
    );
    final sourceWav = File('${temporaryDirectory.path}/source.wav')
      ..writeAsBytesSync(buildTestWav(sampleRate: 48000, sampleFrames: 48000));
    final repository = FakeLibraryRepository(
      applicationSupportDirectory: temporaryDirectory,
    );

    _installDocumentHandler();
    addTearDown(() {
      _removeDocumentHandler();
      temporaryDirectory.deleteSync(recursive: true);
    });

    final synthesis = FakeSynthesisService(
      voices: const [adamVoice, thaiSonVoice],
      wavPath: sourceWav.path,
    );
    final playback = FakePlaybackAudio();

    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          environment: HomePageEnvironment(
            synthesisService: synthesis,
            preferences: MemoryPreferenceStore(),
            playbackAudioFactory: () => playback,
            bootstrap: () async {
              return HomeBootstrap(
                voices: const [adamVoice, thaiSonVoice],
                selectedVoice: adamVoice,
                libraryRepository: repository,
                libraryItems: const [],
              );
            },
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();

    expect(find.text('Native engine ready'), findsOneWidget);

    final generateButton = find.byKey(
      const ValueKey<String>('generate-button'),
    );
    await tester.ensureVisible(generateButton);
    await tester.tap(generateButton);
    await tester.pump();
    await tester.pump();

    expect(synthesis.synthesizeCalls, 1);
    expect(synthesis.synthesizeVoiceIds, ['Adam']);
    expect(find.text('Synthesis complete — cache MISS'), findsOneWidget);

    final saveButton = find.byKey(
      const ValueKey<String>('save-library-button'),
    );
    await tester.ensureVisible(saveButton);
    await tester.pump();
    expect(tester.widget<FilledButton>(saveButton).onPressed, isNotNull);
    await tester.tap(saveButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    final savedItems = repository.items;
    expect(savedItems, hasLength(1));
    expect(savedItems.single.title, 'Hôm nay bạn khỏe không?');
    expect(find.widgetWithText(AppBar, 'Library'), findsOneWidget);

    final playKey = ValueKey<String>(
      'library-play-${savedItems.single.itemId}',
    );
    await tester.ensureVisible(find.byKey(playKey));
    await tester.tap(find.byKey(playKey));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pump();

    expect(playback.playCount, 1);

    await tester.tap(find.byKey(playKey));
    await tester.pump();
    await tester.pump();

    expect(playback.stopCount, 1);

    await tester.tap(find.byKey(HomeTabScaffold.generateTabKey));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.widgetWithText(AppBar, 'Vietnamese Shadowing'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'Hôm nay bạn khỏe không?',
    );

    await tester.tap(find.byKey(HomeTabScaffold.libraryTabKey));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Hôm nay bạn khỏe không?'), findsWidgets);
  });

  testWidgets('generates with both curated voices', (tester) async {
    final temporaryDirectory = Directory.systemTemp.createTempSync(
      'vshadow-voice-flow-',
    );
    final sourceWav = File('${temporaryDirectory.path}/source.wav')
      ..writeAsBytesSync(buildTestWav(sampleRate: 48000, sampleFrames: 48000));
    final repository = FakeLibraryRepository(
      applicationSupportDirectory: temporaryDirectory,
    );

    _installDocumentHandler();
    addTearDown(() {
      _removeDocumentHandler();
      temporaryDirectory.deleteSync(recursive: true);
    });

    final synthesis = FakeSynthesisService(
      voices: const [adamVoice, thaiSonVoice],
      wavPath: sourceWav.path,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          environment: HomePageEnvironment(
            synthesisService: synthesis,
            preferences: MemoryPreferenceStore(),
            playbackAudioFactory: () => FakePlaybackAudio(),
            bootstrap: () async {
              return HomeBootstrap(
                voices: const [adamVoice, thaiSonVoice],
                selectedVoice: adamVoice,
                libraryRepository: repository,
              );
            },
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();

    expect(find.text('Nam · male · Adam'), findsOneWidget);

    final generateButton = find.byKey(
      const ValueKey<String>('generate-button'),
    );
    await tester.ensureVisible(generateButton);
    await tester.tap(generateButton);
    await tester.pump();
    await tester.pump();

    expect(synthesis.synthesizeVoiceIds, ['Adam']);

    final voiceDropdown = find.byKey(const ValueKey<String>('voice-dropdown'));
    await tester.ensureVisible(voiceDropdown);
    await tester.tap(voiceDropdown);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Nam · male · Thái Sơn').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Voice selected: Thái Sơn'), findsOneWidget);

    await tester.ensureVisible(generateButton);
    await tester.tap(generateButton);
    await tester.pump();
    await tester.pump();

    expect(synthesis.synthesizeVoiceIds, ['Adam', 'Thái Sơn']);
  });

  testWidgets('previews the selected voice without generating full text', (
    tester,
  ) async {
    final temporaryDirectory = Directory.systemTemp.createTempSync(
      'vshadow-voice-preview-',
    );
    final sourceWav = File('${temporaryDirectory.path}/preview.wav')
      ..writeAsBytesSync(buildTestWav(sampleRate: 48000, sampleFrames: 48000));
    final repository = FakeLibraryRepository(
      applicationSupportDirectory: temporaryDirectory,
    );

    _installDocumentHandler();
    addTearDown(() {
      _removeDocumentHandler();
      temporaryDirectory.deleteSync(recursive: true);
    });

    final synthesis = FakeSynthesisService(
      voices: const [adamVoice, thaiSonVoice],
      wavPath: sourceWav.path,
    );
    final playback = FakePlaybackAudio();

    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          environment: HomePageEnvironment(
            synthesisService: synthesis,
            preferences: MemoryPreferenceStore(),
            playbackAudioFactory: () => playback,
            bootstrap: () async {
              return HomeBootstrap(
                voices: const [adamVoice, thaiSonVoice],
                selectedVoice: adamVoice,
                libraryRepository: repository,
              );
            },
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();

    final voiceDropdown = find.byKey(const ValueKey<String>('voice-dropdown'));
    await tester.ensureVisible(voiceDropdown);
    await tester.tap(voiceDropdown);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Nam · male · Thái Sơn').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final previewButton = find.byKey(
      const ValueKey<String>('voice-preview-button'),
    );
    await tester.ensureVisible(previewButton);
    await tester.tap(previewButton);
    await tester.pump();
    await tester.pump();

    expect(synthesis.synthesizeCalls, 1);
    expect(synthesis.synthesizeVoiceIds, ['Thái Sơn']);
    expect(synthesis.synthesizeTexts, ['Xin chào, đây là giọng đọc mẫu.']);
    expect(playback.playedPaths, [sourceWav.path]);
    expect(find.text('Playing voice preview...'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('stop-generated-button')),
    );
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pump();

    expect(playback.stopCount, 1);
    expect(find.text('Playback stopped.'), findsOneWidget);
  });

  testWidgets('imports a .vshadow opened by the operating system', (
    tester,
  ) async {
    final library = await _createLibrary(tester);
    final item = await tester.runAsync(
      () => library.repository.saveAudioBytes(
        title: 'Original item',
        originalText: 'Nội dung gốc',
        normalizedText: 'nội dung gốc',
        voice: voiceMetadata,
        audioBytes: buildTestWav(sampleRate: 48000, sampleFrames: 48000),
      ),
    );
    final packageFile = File('${library.directory.path}/external.vshadow');
    await tester.runAsync(() async {
      final packageBytes = await VshadowPackageService(
        repository: library.repository,
      ).exportItem(item!);
      await packageFile.writeAsBytes(packageBytes);
    });
    final initialItems = await tester.runAsync(library.repository.list);

    _installDocumentHandler();
    addTearDown(() {
      _removeDocumentHandler();
      library.directory.deleteSync(recursive: true);
    });

    final synthesis = FakeSynthesisService(
      voices: const [adamVoice, thaiSonVoice],
      wavPath: '${library.directory.path}/unused.wav',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          environment: HomePageEnvironment(
            synthesisService: synthesis,
            preferences: MemoryPreferenceStore(),
            bootstrap: () async {
              return HomeBootstrap(
                voices: const [adamVoice, thaiSonVoice],
                selectedVoice: adamVoice,
                libraryRepository: library.repository,
                libraryItems: initialItems!,
              );
            },
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();

    await tester.runAsync(() async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            documentChannel.name,
            codec.encodeMethodCall(
              MethodCall('openDocument', packageFile.path),
            ),
            (_) {},
          );
    });

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final items = await tester.runAsync(library.repository.list);
    expect(items, hasLength(2));
    expect(find.widgetWithText(AppBar, 'Library'), findsOneWidget);
    expect(find.text('Original item'), findsNWidgets(2));
    expect(packageFile.existsSync(), isFalse);
  });
}

Future<({Directory directory, LibraryRepository repository})> _createLibrary(
  WidgetTester tester,
) async {
  final result = await tester.runAsync(() async {
    final directory = await Directory.systemTemp.createTemp(
      'vshadow-home-flow-',
    );
    final repository = await LibraryRepository.open(
      applicationSupportDirectory: directory,
    );
    return (directory: directory, repository: repository);
  });

  return result!;
}

void _installDocumentHandler() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(documentChannel, (call) async {
        if (call.method == 'takePendingDocument') {
          return null;
        }

        return null;
      });
}

void _removeDocumentHandler() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(documentChannel, null);
}
