import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vietnamese_shadowing/library/library_metadata.dart';
import 'package:vietnamese_shadowing/library/library_repository.dart';
import 'package:vietnamese_shadowing/library/vshadow_backup.dart';
import 'package:vietnamese_shadowing/library/vshadow_package.dart';

import 'support/wav_fixture.dart';

void main() {
  const adamVoice = VoiceMetadata(
    stableId: 'adam',
    presetName: 'Adam',
    displayName: 'Adam',
    description: 'Nam · Nam · Giọng đọc tự nhiên',
    gender: 'male',
    accent: 'Nam',
    style: 'tu_nhien',
  );

  const thaiSonVoice = VoiceMetadata(
    stableId: 'thai-son',
    presetName: 'Thái Sơn',
    displayName: 'Thái Sơn',
    description: 'Nam · Nam · Phong cách kể chuyện',
    gender: 'male',
    accent: 'Nam',
    style: 'doc_truyen',
  );

  const firstItemId = '123e4567-e89b-42d3-a456-426614174000';
  const secondItemId = '123e4567-e89b-42d3-a456-426614174001';

  final firstAudio = buildTestWav(sampleRate: 48000, sampleFrames: 4800);
  final secondAudio = buildTestWav(sampleRate: 24000, sampleFrames: 2400);

  Uint8List encodeRawBackup({
    required Map<String, dynamic> manifest,
    required Map<String, Map<String, dynamic>> metadataByItem,
    required Map<String, Uint8List> audioByItem,
    List<ArchiveFile> extraEntries = const <ArchiveFile>[],
  }) {
    final archive = Archive()
      ..add(ArchiveFile.string('backup.json', jsonEncode(manifest)));

    for (final entry in metadataByItem.entries) {
      archive.add(
        ArchiveFile.string(
          'items/${entry.key}/metadata.json',
          jsonEncode(entry.value),
        ),
      );
    }

    for (final entry in audioByItem.entries) {
      archive.add(
        ArchiveFile.bytes('items/${entry.key}/audio.wav', entry.value),
      );
    }

    for (final extraEntry in extraEntries) {
      archive.add(extraEntry);
    }

    return ZipEncoder().encodeBytes(archive);
  }

  Map<String, dynamic> manifestJson({
    List<String> itemIds = const <String>[],
    Map<String, dynamic>? settings,
    int schemaVersion = vshadowBackupSchemaVersion,
  }) {
    return <String, dynamic>{
      'schema_version': schemaVersion,
      'created_at_utc': '2026-10-22T07:30:00.000Z',
      'settings':
          settings ??
          const VshadowBackupSettings(
            defaultVoiceStableId: 'adam',
            defaultVoicePresetName: 'Adam',
            playbackSpeed: 1.25,
            repeatCount: 3,
            paddingSeconds: 0.75,
            pauseUsesAudioLength: false,
          ).toJson(),
      'items': itemIds,
    };
  }

  late Directory temporaryDirectory;
  late LibraryRepository repository;
  late VshadowBackupService service;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'vshadow-backup-test-',
    );
    repository = await LibraryRepository.open(
      applicationSupportDirectory: temporaryDirectory,
    );
    service = VshadowBackupService(repository: repository);
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('round trips library audio, metadata, and settings', () async {
    final first = await repository.saveAudioBytes(
      title: 'First item',
      originalText: 'Xin chào, thế giới!',
      normalizedText: 'xin chào, thế giới!',
      voice: adamVoice,
      audioBytes: firstAudio,
      createdAtUtc: DateTime.utc(2026, 10, 20, 14, 30, 45),
      itemId: firstItemId,
    );
    final second = await repository.saveAudioBytes(
      title: 'Second item',
      originalText: 'Hôm nay bạn khỏe không?',
      normalizedText: 'hôm nay bạn khỏe không?',
      voice: thaiSonVoice,
      audioBytes: secondAudio,
      createdAtUtc: DateTime.utc(2026, 10, 21, 8, 15),
      itemId: secondItemId,
    );

    const settings = VshadowBackupSettings(
      defaultVoiceStableId: 'thai-son',
      defaultVoicePresetName: 'Thái Sơn',
      playbackSpeed: 1.5,
      repeatCount: 5,
      paddingSeconds: 1.0,
      pauseUsesAudioLength: true,
    );

    final backup = await service.exportBackup(
      items: await repository.list(),
      settings: settings,
      createdAtUtc: DateTime.utc(2026, 10, 22, 7, 30),
    );
    final decoded = decodeVshadowBackup(backup);

    expect(decoded.manifest.settings.toJson(), settings.toJson());
    expect(decoded.manifest.createdAtUtc, DateTime.utc(2026, 10, 22, 7, 30));
    expect(decoded.manifest.itemIds, [second.itemId, first.itemId]);
    expect(decoded.items, hasLength(2));
    expect(decoded.items.first.itemId, second.itemId);
    expect(decoded.items.first.metadata.title, second.title);
    expect(decoded.items.first.audioBytes, secondAudio);
    expect(decoded.items.last.itemId, first.itemId);
    expect(decoded.items.last.metadata.title, first.title);
    expect(decoded.items.last.audioBytes, firstAudio);

    final restoreDirectory = await Directory.systemTemp.createTemp(
      'vshadow-backup-restore-',
    );
    addTearDown(() async {
      if (await restoreDirectory.exists()) {
        await restoreDirectory.delete(recursive: true);
      }
    });
    final restoredRepository = await LibraryRepository.open(
      applicationSupportDirectory: restoreDirectory,
    );
    final restoreService = VshadowBackupService(repository: restoredRepository);
    final result = await restoreService.importBackup(backup);
    final restoredItems = await restoredRepository.list();

    expect(result.importedCount, 2);
    expect(result.skippedCount, 0);
    expect(result.manifest.settings.toJson(), settings.toJson());
    expect(restoredItems, hasLength(2));
    expect(
      restoredItems.map((item) => item.itemId),
      containsAll(<String>[firstItemId, secondItemId]),
    );
    expect(
      await restoredRepository.audioFile(firstItemId).readAsBytes(),
      firstAudio,
    );
    expect(
      await restoredRepository.audioFile(secondItemId).readAsBytes(),
      secondAudio,
    );
  });

  test('exports and restores an empty library', () async {
    final backup = await service.exportBackup(
      items: const <LibraryItemMetadata>[],
      settings: const VshadowBackupSettings(),
      createdAtUtc: DateTime.utc(2026, 10, 22, 7, 30),
    );
    final decoded = decodeVshadowBackup(backup);

    expect(decoded.manifest.itemIds, isEmpty);
    expect(decoded.items, isEmpty);

    final result = await service.importBackup(backup);

    expect(result.importedCount, 0);
    expect(result.skippedCount, 0);
    expect(await repository.list(), isEmpty);
  });

  test('retrying a restore is idempotent', () async {
    final item = await repository.saveAudioBytes(
      title: 'Persisted item',
      originalText: 'Nội dung',
      normalizedText: 'nội dung',
      voice: adamVoice,
      audioBytes: firstAudio,
      itemId: firstItemId,
    );
    final backup = await service.exportBackup(
      items: await repository.list(),
      settings: const VshadowBackupSettings(),
    );

    final restoreDirectory = await Directory.systemTemp.createTemp(
      'vshadow-backup-idempotent-',
    );
    addTearDown(() async {
      if (await restoreDirectory.exists()) {
        await restoreDirectory.delete(recursive: true);
      }
    });
    final restoredRepository = await LibraryRepository.open(
      applicationSupportDirectory: restoreDirectory,
    );
    final restoreService = VshadowBackupService(repository: restoredRepository);
    final firstRestore = await restoreService.importBackup(backup);
    final secondRestore = await restoreService.importBackup(backup);
    final restoredItems = await restoredRepository.list();

    expect(firstRestore.importedCount, 1);
    expect(firstRestore.skippedCount, 0);
    expect(secondRestore.importedCount, 0);
    expect(secondRestore.skippedCount, 1);
    expect(restoredItems, hasLength(1));
    expect(restoredItems.single.itemId, item.itemId);
  });

  test('rejects malformed archive bytes and unexpected entries', () async {
    expect(
      () => decodeVshadowBackup(Uint8List.fromList(<int>[1, 2, 3, 4])),
      throwsFormatException,
    );

    final metadata = buildVshadowMetadata(
      item: LibraryItemMetadata(
        itemId: firstItemId,
        title: 'Item',
        originalText: 'Nội dung',
        normalizedText: 'nội dung',
        voice: adamVoice,
        createdAtUtc: DateTime.utc(2026, 10, 20),
        audio: const AudioMetadata(
          sampleRate: 48000,
          channels: 1,
          bitDepth: 16,
        ),
      ),
      audioBytes: firstAudio,
    );

    final backupWithExtra = encodeRawBackup(
      manifest: manifestJson(itemIds: <String>[firstItemId]),
      metadataByItem: <String, Map<String, dynamic>>{
        firstItemId: metadata.toJson(),
      },
      audioByItem: <String, Uint8List>{firstItemId: firstAudio},
      extraEntries: <ArchiveFile>[ArchiveFile.string('notes.txt', 'extra')],
    );

    expect(() => decodeVshadowBackup(backupWithExtra), throwsFormatException);
  });

  test('rejects path traversal and missing item files', () async {
    final metadata = buildVshadowMetadata(
      item: LibraryItemMetadata(
        itemId: firstItemId,
        title: 'Item',
        originalText: 'Nội dung',
        normalizedText: 'nội dung',
        voice: adamVoice,
        createdAtUtc: DateTime.utc(2026, 10, 20),
        audio: const AudioMetadata(
          sampleRate: 48000,
          channels: 1,
          bitDepth: 16,
        ),
      ),
      audioBytes: firstAudio,
    );

    final traversalBackup = encodeRawBackup(
      manifest: manifestJson(itemIds: <String>[firstItemId]),
      metadataByItem: <String, Map<String, dynamic>>{
        firstItemId: metadata.toJson(),
      },
      audioByItem: <String, Uint8List>{firstItemId: firstAudio},
      extraEntries: <ArchiveFile>[
        ArchiveFile.string('../metadata.json', 'not allowed'),
      ],
    );
    expect(() => decodeVshadowBackup(traversalBackup), throwsFormatException);

    final missingAudioBackup = encodeRawBackup(
      manifest: manifestJson(itemIds: <String>[firstItemId]),
      metadataByItem: <String, Map<String, dynamic>>{
        firstItemId: metadata.toJson(),
      },
      audioByItem: const <String, Uint8List>{},
    );
    expect(
      () => decodeVshadowBackup(missingAudioBackup),
      throwsFormatException,
    );
  });

  test('rejects checksum failures and invalid metadata', () async {
    final metadata = buildVshadowMetadata(
      item: LibraryItemMetadata(
        itemId: firstItemId,
        title: 'Item',
        originalText: 'Nội dung',
        normalizedText: 'nội dung',
        voice: adamVoice,
        createdAtUtc: DateTime.utc(2026, 10, 20),
        audio: const AudioMetadata(
          sampleRate: 48000,
          channels: 1,
          bitDepth: 16,
        ),
      ),
      audioBytes: firstAudio,
    );
    final tamperedAudio = Uint8List.fromList(firstAudio);
    tamperedAudio[44] = tamperedAudio[44] ^ 0xff;

    final checksumBackup = encodeRawBackup(
      manifest: manifestJson(itemIds: <String>[firstItemId]),
      metadataByItem: <String, Map<String, dynamic>>{
        firstItemId: metadata.toJson(),
      },
      audioByItem: <String, Uint8List>{firstItemId: tamperedAudio},
    );
    expect(() => decodeVshadowBackup(checksumBackup), throwsFormatException);

    final invalidMetadataBackup = ZipEncoder().encodeBytes(
      Archive()
        ..add(
          ArchiveFile.string(
            'backup.json',
            jsonEncode(manifestJson(itemIds: <String>[firstItemId])),
          ),
        )
        ..add(
          ArchiveFile.string('items/$firstItemId/metadata.json', '{not-json'),
        )
        ..add(ArchiveFile.bytes('items/$firstItemId/audio.wav', firstAudio)),
    );
    expect(
      () => decodeVshadowBackup(invalidMetadataBackup),
      throwsFormatException,
    );
  });

  test('rejects invalid manifest settings and versions', () async {
    final settings = const VshadowBackupSettings().toJson();

    expect(
      () => VshadowBackupSettings.fromJson(<String, dynamic>{
        ...settings,
        'playback_speed': 3.0,
      }),
      throwsFormatException,
    );
    expect(
      () => VshadowBackupSettings.fromJson(<String, dynamic>{
        ...settings,
        'repeat_count': 4,
      }),
      throwsFormatException,
    );
    expect(
      () => VshadowBackupSettings.fromJson(<String, dynamic>{
        ...settings,
        'default_voice_stable_id': 'unknown',
        'default_voice_preset_name': 'Unknown',
      }),
      throwsFormatException,
    );
    expect(
      () => VshadowBackupManifest.fromJson(
        manifestJson(
          settings: settings,
          schemaVersion: vshadowBackupSchemaVersion + 1,
        ),
      ),
      throwsFormatException,
    );
    expect(
      () => VshadowBackupManifest.fromJson(
        manifestJson(
          settings: settings,
          itemIds: <String>[firstItemId, firstItemId],
        ),
      ),
      throwsFormatException,
    );
  });

  test('enforces backup, manifest, and item limits', () async {
    final backup = await service.exportBackup(
      items: <LibraryItemMetadata>[
        await repository.saveAudioBytes(
          title: 'Item',
          originalText: 'Nội dung',
          normalizedText: 'nội dung',
          voice: adamVoice,
          audioBytes: firstAudio,
          itemId: firstItemId,
        ),
      ],
      settings: const VshadowBackupSettings(),
    );

    expect(
      () => decodeVshadowBackup(backup, maxBackupBytes: 10),
      throwsFormatException,
    );
    expect(
      () => decodeVshadowBackup(backup, maxManifestBytes: 10),
      throwsFormatException,
    );
    expect(
      () => decodeVshadowBackup(backup, maxItems: 0),
      throwsFormatException,
    );
  });

  test('builds deterministic backup filenames', () {
    final exportedAt = DateTime(2026, 10, 22, 7, 30, 5);

    expect(
      buildVshadowBackupFilename(exportedAt: exportedAt),
      'vshadow-backup_2026-10-22_073005.vshadowbackup',
    );
    expect(
      buildVshadowBackupFilename(exportedAt: exportedAt, collisionIndex: 1),
      'vshadow-backup_2026-10-22_073005-2.vshadowbackup',
    );
    expect(
      () => buildVshadowBackupFilename(
        exportedAt: exportedAt,
        collisionIndex: -1,
      ),
      throwsArgumentError,
    );
  });
}
