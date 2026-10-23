import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vietnamese_shadowing/backup/auto_backup_service.dart';
import 'package:vietnamese_shadowing/backup/backup_folder_service.dart';
import 'package:vietnamese_shadowing/library/library_metadata.dart';
import 'package:vietnamese_shadowing/library/library_repository.dart';
import 'package:vietnamese_shadowing/library/vshadow_backup.dart';
import 'package:vietnamese_shadowing/practice/practice_repository.dart';

import 'support/wav_fixture.dart';

class _RecordingFolderService implements BackupFolderService {
  _RecordingFolderService(this.destinationDirectory);

  final Directory destinationDirectory;
  final List<String> writtenFileNames = <String>[];
  int chooseCalls = 0;
  int getCalls = 0;
  int clearCalls = 0;

  @override
  Future<BackupFolderInfo?> chooseFolder() async {
    chooseCalls++;
    return BackupFolderInfo(
      name: destinationDirectory.path.split(Platform.pathSeparator).last,
      path: destinationDirectory.path,
    );
  }

  @override
  Future<BackupFolderInfo?> getFolder() async {
    getCalls++;
    return BackupFolderInfo(
      name: destinationDirectory.path.split(Platform.pathSeparator).last,
      path: destinationDirectory.path,
    );
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
    writtenFileNames.add(fileName);
    final destination = File('${destinationDirectory.path}/$fileName');
    await File(sourcePath).copy(destination.path);
    return destination.path;
  }
}

void main() {
  const voice = VoiceMetadata(
    stableId: 'adam',
    presetName: 'Adam',
    displayName: 'Adam',
    description: 'Nam · Nam · Giọng đọc tự nhiên',
    gender: 'male',
    accent: 'Nam',
    style: 'tu_nhien',
  );

  late Directory temporaryDirectory;
  late Directory exportDirectory;
  late Directory autoBackupDirectory;
  late LibraryRepository repository;
  late PracticeRepository practice;
  late _RecordingFolderService folders;
  late AutoBackupService service;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'vshadow-auto-backup-',
    );
    exportDirectory = Directory('${temporaryDirectory.path}/exports')
      ..createSync();
    autoBackupDirectory = Directory('${temporaryDirectory.path}/selected')
      ..createSync();
    repository = await LibraryRepository.open(
      applicationSupportDirectory: temporaryDirectory,
    );
    practice = await PracticeRepository.open(
      applicationSupportDirectory: temporaryDirectory,
    );
    folders = _RecordingFolderService(autoBackupDirectory);
    service = AutoBackupService(
      repository: repository,
      practiceRepository: practice,
      folderService: folders,
      temporaryDirectoryProvider: () async => exportDirectory,
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('writes one rolling backup into the chosen folder', () async {
    final item = await repository.saveAudioBytes(
      title: 'Morning practice',
      originalText: 'Xin chào buổi sáng',
      normalizedText: 'xin chào buổi sáng',
      voice: voice,
      audioBytes: buildTestWav(sampleRate: 48000, sampleFrames: 4800),
      createdAtUtc: DateTime.utc(2026, 10, 22, 7, 30),
    );

    final take = await practice.saveAudioBytes(
      libraryItemId: item.itemId,
      itemTitle: item.title,
      audioBytes: buildTestWav(sampleRate: 44100, sampleFrames: 4410),
      createdAtUtc: DateTime.utc(2026, 10, 22, 7, 35),
    );

    final result = await service.run(
      items: await repository.list(),
      takes: await practice.list(),
      settings: const VshadowBackupSettings(
        defaultVoiceStableId: 'adam',
        defaultVoicePresetName: 'Adam',
        playbackSpeed: 1.25,
        repeatCount: 2,
        paddingSeconds: 0.25,
      ),
      completedAtUtc: DateTime.utc(2026, 10, 22, 8),
    );

    expect(result.fileName, vshadowAutoBackupFileName);
    expect(result.bytes, greaterThan(0));
    expect(result.completedAtUtc, DateTime.utc(2026, 10, 22, 8));
    expect(folders.writtenFileNames, [vshadowAutoBackupFileName]);
    expect(
      File('${autoBackupDirectory.path}/$vshadowAutoBackupFileName')
          .existsSync(),
      isTrue,
    );
    expect(
      File('${exportDirectory.path}/$vshadowAutoBackupFileName').existsSync(),
      isFalse,
    );

    final decoded = decodeVshadowBackup(
      await File('${autoBackupDirectory.path}/$vshadowAutoBackupFileName')
          .readAsBytes(),
    );

    expect(decoded.manifest.itemIds, [item.itemId]);
    expect(decoded.items.single.metadata.title, item.title);
    expect(decoded.manifest.takeIds, [take.takeId]);
    expect(decoded.takes.single.metadata.itemTitle, item.title);
    expect(decoded.manifest.settings.playbackSpeed, 1.25);
  });

  test('overwrites the existing rolling backup', () async {
    await service.run(
      items: const <LibraryItemMetadata>[],
      settings: const VshadowBackupSettings(),
      completedAtUtc: DateTime.utc(2026, 10, 22, 8),
    );

    final firstBytes = await File(
      '${autoBackupDirectory.path}/$vshadowAutoBackupFileName',
    ).readAsBytes();

    await repository.saveAudioBytes(
      title: 'Later item',
      originalText: 'Nội dung',
      normalizedText: 'nội dung',
      voice: voice,
      audioBytes: buildTestWav(sampleRate: 24000, sampleFrames: 2400),
    );

    await service.run(
      items: await repository.list(),
      settings: const VshadowBackupSettings(),
      completedAtUtc: DateTime.utc(2026, 10, 22, 9),
    );

    final secondBytes = await File(
      '${autoBackupDirectory.path}/$vshadowAutoBackupFileName',
    ).readAsBytes();

    expect(secondBytes, isNot(firstBytes));
    expect(decodeVshadowBackup(secondBytes).manifest.itemIds, hasLength(1));
  });
}
