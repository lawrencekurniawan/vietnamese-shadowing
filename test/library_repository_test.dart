import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vietnamese_shadowing/library/library_metadata.dart';
import 'package:vietnamese_shadowing/library/library_repository.dart';

import 'support/wav_fixture.dart';

void main() {
  const voice = VoiceMetadata(
    stableId: 'mai-anh',
    presetName: 'Mai Anh',
    displayName: 'Mai Anh',
    description: 'Nữ · Bắc · Phong cách tự nhiên',
    gender: 'female',
    accent: 'Bắc',
    style: 'tu_nhien',
  );

  const explicitItemId = '123e4567-e89b-42d3-a456-426614174000';

  late Directory temporaryDirectory;
  late LibraryRepository repository;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'vshadow-library-test-',
    );
    repository = await LibraryRepository.open(
      applicationSupportDirectory: temporaryDirectory,
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('saves durable audio separately from the temporary cache', () async {
    final source = await writeTestWavFile(
      '${temporaryDirectory.path}/cache.wav',
      sampleRate: 48000,
      sampleFrames: 48000,
    );

    final item = await repository.saveFromWavFile(
      title: 'Xin chào',
      originalText: 'Xin chào, thế giới!',
      normalizedText: 'xin chào, thế giới!',
      voice: voice,
      sourceWavPath: source.path,
      createdAtUtc: DateTime.utc(2026, 10, 20, 12),
    );

    final audioFile = repository.audioFile(item.itemId);

    expect(await audioFile.exists(), isTrue);
    expect(audioFile.path, contains('/vieneu/library/'));
    expect(audioFile.path, isNot(contains('/tts-cache/')));
    expect(item.audio.sampleRate, 48000);
    expect(item.audio.channels, 1);
    expect(item.audio.bitDepth, 16);
    expect(item.audio.durationSeconds, closeTo(1.0, 0.001));

    await source.delete();
    expect(await audioFile.exists(), isTrue);
  });

  test('restores items from disk after reopening the repository', () async {
    await repository.saveAudioBytes(
      title: 'Persisted item',
      originalText: 'Nội dung gốc',
      normalizedText: 'nội dung gốc',
      voice: voice,
      audioBytes: buildTestWav(sampleFrames: 1200),
      createdAtUtc: DateTime.utc(2026, 10, 20, 12),
    );

    final reopened = await LibraryRepository.open(
      applicationSupportDirectory: temporaryDirectory,
    );
    final items = await reopened.list();

    expect(items, hasLength(1));
    expect(items.single.title, 'Persisted item');
    expect(items.single.voice.stableId, 'mai-anh');
    expect(await reopened.audioFile(items.single.itemId).exists(), isTrue);
  });

  test('renames an item without changing its audio', () async {
    final item = await repository.saveAudioBytes(
      title: 'Old title',
      originalText: 'Nội dung',
      normalizedText: 'nội dung',
      voice: voice,
      audioBytes: buildTestWav(),
    );
    final audioFile = repository.audioFile(item.itemId);
    final audioBefore = await audioFile.readAsBytes();

    await repository.rename(item.itemId, '  New title  ');

    final renamed = await repository.read(item.itemId);

    expect(renamed?.title, 'New title');
    expect(await audioFile.readAsBytes(), audioBefore);
  });

  test('deletes an item and its durable audio', () async {
    final item = await repository.saveAudioBytes(
      title: 'Delete me',
      originalText: 'Nội dung',
      normalizedText: 'nội dung',
      voice: voice,
      audioBytes: buildTestWav(),
    );
    final audioFile = repository.audioFile(item.itemId);

    await repository.delete(item.itemId);

    expect(await repository.read(item.itemId), isNull);
    expect(await audioFile.exists(), isFalse);
    expect(await repository.list(), isEmpty);
  });

  test('never overwrites an explicit item ID', () async {
    await repository.saveAudioBytes(
      title: 'First',
      originalText: 'Nội dung',
      normalizedText: 'nội dung',
      voice: voice,
      audioBytes: buildTestWav(),
      itemId: explicitItemId,
    );

    await expectLater(
      repository.saveAudioBytes(
        title: 'Second',
        originalText: 'Nội dung khác',
        normalizedText: 'nội dung khác',
        voice: voice,
        audioBytes: buildTestWav(sampleFrames: 100),
        itemId: explicitItemId,
      ),
      throwsA(isA<LibraryItemExistsException>()),
    );

    expect((await repository.read(explicitItemId))?.title, 'First');
  });

  test('rejects invalid WAV payloads without installing an item', () async {
    await expectLater(
      repository.saveAudioBytes(
        title: 'Invalid',
        originalText: 'Nội dung',
        normalizedText: 'nội dung',
        voice: voice,
        audioBytes: List<int>.filled(20, 0),
      ),
      throwsFormatException,
    );

    expect(await repository.list(), isEmpty);
  });

  test('skips corrupt items while listing valid items', () async {
    final item = await repository.saveAudioBytes(
      title: 'Valid',
      originalText: 'Nội dung',
      normalizedText: 'nội dung',
      voice: voice,
      audioBytes: buildTestWav(),
    );

    final corruptDirectory = Directory(
      '${repository.rootDirectory.path}/123e4567-e89b-42d3-a456-426614174001',
    );
    await corruptDirectory.create(recursive: true);
    await File('${corruptDirectory.path}/metadata.json')
        .writeAsString('{"schema_version": 999}');

    final items = await repository.list();

    expect(items.map((entry) => entry.itemId), [item.itemId]);
  });
}
