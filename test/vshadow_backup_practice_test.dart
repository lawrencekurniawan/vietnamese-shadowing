import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vietnamese_shadowing/library/library_metadata.dart';
import 'package:vietnamese_shadowing/library/library_repository.dart';
import 'package:vietnamese_shadowing/library/vshadow_backup.dart';
import 'package:vietnamese_shadowing/library/vshadow_package.dart';
import 'package:vietnamese_shadowing/practice/practice_repository.dart';

import 'support/wav_fixture.dart';

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

  const itemId = '123e4567-e89b-42d3-a456-426614174000';
  const takeId = '123e4567-e89b-42d3-a456-426614174001';
  final itemAudio = buildTestWav(sampleRate: 48000, sampleFrames: 4800);
  final takeAudio = buildTestWav(sampleRate: 44100, sampleFrames: 4410);

  late Directory temporaryDirectory;
  late LibraryRepository library;
  late PracticeRepository practice;
  late VshadowBackupService service;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'vshadow-backup-practice-',
    );
    library = await LibraryRepository.open(
      applicationSupportDirectory: temporaryDirectory,
    );
    practice = await PracticeRepository.open(
      applicationSupportDirectory: temporaryDirectory,
    );
    service = VshadowBackupService(
      repository: library,
      practiceRepository: practice,
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('round trips library items, settings, and practice takes', () async {
    final item = await library.saveAudioBytes(
      title: 'Morning practice',
      originalText: 'Xin chào buổi sáng',
      normalizedText: 'xin chào buổi sáng',
      voice: voice,
      audioBytes: itemAudio,
      createdAtUtc: DateTime.utc(2026, 10, 20, 7),
      itemId: itemId,
    );
    final take = await practice.saveAudioBytes(
      libraryItemId: item.itemId,
      itemTitle: item.title,
      audioBytes: takeAudio,
      takeId: takeId,
      createdAtUtc: DateTime.utc(2026, 10, 20, 7, 5),
    );

    final backup = await service.exportBackup(
      items: await library.list(),
      takes: await practice.list(),
      settings: const VshadowBackupSettings(
        defaultVoiceStableId: 'adam',
        defaultVoicePresetName: 'Adam',
        playbackSpeed: 1.25,
        repeatCount: 2,
        paddingSeconds: 0.25,
      ),
      createdAtUtc: DateTime.utc(2026, 10, 22, 9),
    );
    final decoded = decodeVshadowBackup(backup);

    expect(decoded.manifest.schemaVersion, 2);
    expect(decoded.manifest.itemIds, [item.itemId]);
    expect(decoded.manifest.takeIds, [take.takeId]);
    expect(decoded.takes, hasLength(1));
    expect(decoded.takes.single.metadata.itemTitle, item.title);
    expect(decoded.takes.single.metadata.libraryItemId, item.itemId);
    expect(decoded.takes.single.audioBytes, takeAudio);

    final restoreDirectory = await Directory.systemTemp.createTemp(
      'vshadow-backup-practice-restore-',
    );
    addTearDown(() async {
      if (await restoreDirectory.exists()) {
        await restoreDirectory.delete(recursive: true);
      }
    });
    final restoredLibrary = await LibraryRepository.open(
      applicationSupportDirectory: restoreDirectory,
    );
    final restoredPractice = await PracticeRepository.open(
      applicationSupportDirectory: restoreDirectory,
    );
    final restoreService = VshadowBackupService(
      repository: restoredLibrary,
      practiceRepository: restoredPractice,
    );
    final result = await restoreService.importBackup(backup);

    expect(result.importedCount, 1);
    expect(result.importedTakeCount, 1);
    expect(result.skippedCount, 0);
    expect(result.skippedTakeCount, 0);
    expect(await restoredLibrary.list(), hasLength(1));
    expect(await restoredPractice.list(), hasLength(1));
    expect(await restoredPractice.audioFile(takeId).readAsBytes(), takeAudio);
  });

  test('retrying a restore skips existing takes', () async {
    final item = await library.saveAudioBytes(
      title: 'Morning practice',
      originalText: 'Xin chào',
      normalizedText: 'xin chào',
      voice: voice,
      audioBytes: itemAudio,
      itemId: itemId,
    );
    await practice.saveAudioBytes(
      libraryItemId: item.itemId,
      itemTitle: item.title,
      audioBytes: takeAudio,
      takeId: takeId,
    );

    final backup = await service.exportBackup(
      items: await library.list(),
      takes: await practice.list(),
      settings: const VshadowBackupSettings(),
    );

    final first = await service.importBackup(backup);
    final second = await service.importBackup(backup);

    expect(first.importedCount, 0);
    expect(first.skippedCount, 1);
    expect(first.importedTakeCount, 0);
    expect(first.skippedTakeCount, 1);
    expect(second.importedTakeCount, 0);
    expect(second.skippedTakeCount, 1);
    expect(await practice.list(), hasLength(1));
  });

  test('restores version 1 backups without practice takes', () async {
    final item = await library.saveAudioBytes(
      title: 'Legacy item',
      originalText: 'Nội dung cũ',
      normalizedText: 'nội dung cũ',
      voice: voice,
      audioBytes: itemAudio,
      itemId: itemId,
    );
    final metadata = buildVshadowMetadata(item: item, audioBytes: itemAudio);
    final manifest = <String, dynamic>{
      'schema_version': 1,
      'created_at_utc': '2026-10-22T09:00:00.000Z',
      'settings': const VshadowBackupSettings().toJson(),
      'items': [itemId],
    };
    final backup = ZipEncoder().encodeBytes(
      Archive()
        ..add(ArchiveFile.string('backup.json', jsonEncode(manifest)))
        ..add(
          ArchiveFile.string(
            'items/$itemId/metadata.json',
            jsonEncode(metadata.toJson()),
          ),
        )
        ..add(ArchiveFile.bytes('items/$itemId/audio.wav', itemAudio)),
    );

    final decoded = decodeVshadowBackup(backup);

    expect(decoded.manifest.schemaVersion, 1);
    expect(decoded.manifest.takeIds, isEmpty);
    expect(decoded.takes, isEmpty);
    expect(decoded.items, hasLength(1));
  });

  test('rejects version 1 backups that declare practice takes', () async {
    final manifest = <String, dynamic>{
      'schema_version': 1,
      'created_at_utc': '2026-10-22T09:00:00.000Z',
      'settings': const VshadowBackupSettings().toJson(),
      'items': <String>[],
      'practice_takes': [takeId],
    };
    final backup = ZipEncoder().encodeBytes(
      Archive()..add(ArchiveFile.string('backup.json', jsonEncode(manifest))),
    );

    expect(() => decodeVshadowBackup(backup), throwsFormatException);
  });

  test('rejects tampered practice audio', () async {
    final item = await library.saveAudioBytes(
      title: 'Morning practice',
      originalText: 'Xin chào',
      normalizedText: 'xin chào',
      voice: voice,
      audioBytes: itemAudio,
      itemId: itemId,
    );
    final take = await practice.saveAudioBytes(
      libraryItemId: item.itemId,
      itemTitle: item.title,
      audioBytes: takeAudio,
      takeId: takeId,
    );

    final backup = await service.exportBackup(
      items: await library.list(),
      takes: await practice.list(),
      settings: const VshadowBackupSettings(),
    );
    final decoder = ZipDecoder();
    final archive = decoder.decodeBytes(backup);
    final tampered = Uint8List.fromList(takeAudio);
    tampered[44] = tampered[44] ^ 0xff;

    final rebuilt = Archive();

    for (final file in archive) {
      if (file.name == 'practice/$takeId/audio.wav') {
        rebuilt.add(ArchiveFile.bytes(file.name, tampered));
      } else {
        rebuilt.add(ArchiveFile.bytes(file.name, file.readBytes()!));
      }
    }

    expect(
      () => decodeVshadowBackup(ZipEncoder().encodeBytes(rebuilt)),
      throwsFormatException,
    );
    expect(take.takeId, takeId);
  });
}
