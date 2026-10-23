import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vietnamese_shadowing/app/home_page_environment.dart';
import 'package:vietnamese_shadowing/backup/backup_folder_service.dart';
import 'package:vietnamese_shadowing/library/library_repository.dart';
import 'package:vietnamese_shadowing/main.dart';
import 'package:vietnamese_shadowing/native/vieneu_ffi.dart';
import 'package:vietnamese_shadowing/ui/home_tab_scaffold.dart';

import 'support/fake_playback_audio.dart';
import 'support/fake_synthesis_service.dart';
import 'support/memory_preference_store.dart';
import 'support/wav_fixture.dart';

class _FakeBackupFolderService implements BackupFolderService {
  int chooseCalls = 0;
  int getCalls = 0;
  int clearCalls = 0;
  int writeCalls = 0;

  @override
  Future<BackupFolderInfo?> chooseFolder() async {
    chooseCalls++;
    return const BackupFolderInfo(name: 'Backups', path: '/backups');
  }

  @override
  Future<BackupFolderInfo?> getFolder() async {
    getCalls++;
    return null;
  }

  @override
  Future<void> clearFolder() async {
    clearCalls++;
  }

  @override
  Future<String> writeBackupFile({
    required String sourcePath,
    required String fileName,
  }) async {
    writeCalls++;
    return '/backups/$fileName';
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

  testWidgets('enables automatic backup after choosing a folder', (
    tester,
  ) async {
    final temporaryDirectory = Directory.systemTemp.createTempSync(
      'vshadow-auto-backup-flow-',
    );
    final sourceWav = File('${temporaryDirectory.path}/source.wav')
      ..writeAsBytesSync(buildTestWav(sampleRate: 48000, sampleFrames: 4800));
    final preferences = MemoryPreferenceStore();
    final folders = _FakeBackupFolderService();
    final library = await tester.runAsync(
      () => LibraryRepository.open(
        applicationSupportDirectory: temporaryDirectory,
      ),
    );

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
            preferences: preferences,
            playbackAudioFactory: FakePlaybackAudio.new,
            backupFolderService: folders,
            bootstrap: () async {
              return HomeBootstrap(
                voices: const [adamVoice, thaiSonVoice],
                selectedVoice: adamVoice,
                libraryRepository: library,
              );
            },
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(HomeTabScaffold.libraryTabKey));
    await tester.pumpAndSettle();

    final switchFinder = find.byKey(
      const ValueKey<String>('auto-backup-switch'),
    );

    expect(tester.widget<SwitchListTile>(switchFinder).value, isFalse);

    await tester.ensureVisible(switchFinder);
    await tester.tap(switchFinder);
    await tester.pump();
    await tester.pump();

    expect(folders.chooseCalls, 1);
    expect(await preferences.getBool('vshadow_auto_backup_enabled'), isTrue);
    expect(tester.widget<SwitchListTile>(switchFinder).value, isTrue);
    expect(find.textContaining('Backups'), findsWidgets);
  });
}
