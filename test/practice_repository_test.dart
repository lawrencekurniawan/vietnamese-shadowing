import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vietnamese_shadowing/practice/practice_repository.dart';
import 'package:vietnamese_shadowing/practice/practice_take_metadata.dart';

import 'support/wav_fixture.dart';

void main() {
  const libraryItemId = '123e4567-e89b-42d3-a456-426614174000';
  const takeId = '123e4567-e89b-42d3-a456-426614174001';
  final audio = buildTestWav(sampleRate: 44100, sampleFrames: 4410);

  late Directory temporaryDirectory;
  late PracticeRepository repository;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'vshadow-practice-test-',
    );
    repository = await PracticeRepository.open(
      applicationSupportDirectory: temporaryDirectory,
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('saves, lists, reads, and deletes a take', () async {
    final saved = await repository.saveAudioBytes(
      libraryItemId: libraryItemId,
      itemTitle: 'Morning practice',
      audioBytes: audio,
      takeId: takeId,
      createdAtUtc: DateTime.utc(2026, 10, 22, 8, 30),
    );

    expect(saved.takeId, takeId);
    expect(saved.libraryItemId, libraryItemId);
    expect(saved.itemTitle, 'Morning practice');
    expect(saved.audioBytes, audio.length);
    expect(saved.audio.durationSeconds, closeTo(0.1, 0.01));

    final listed = await repository.list();

    expect(listed, hasLength(1));
    expect(listed.single.takeId, takeId);
    expect(await repository.read(takeId), isNotNull);
    expect(await repository.audioFile(takeId).readAsBytes(), audio);
  });

  test('refuses to overwrite an existing take', () async {
    await repository.saveAudioBytes(
      libraryItemId: libraryItemId,
      itemTitle: 'Morning practice',
      audioBytes: audio,
      takeId: takeId,
    );

    await expectLater(
      repository.saveAudioBytes(
        libraryItemId: libraryItemId,
        itemTitle: 'Different title',
        audioBytes: audio,
        takeId: takeId,
      ),
      throwsA(isA<PracticeTakeExistsException>()),
    );
  });

  test('rejects invalid audio and identifiers', () async {
    await expectLater(
      repository.saveAudioBytes(
        libraryItemId: libraryItemId,
        itemTitle: 'Bad audio',
        audioBytes: <int>[1, 2, 3],
        takeId: takeId,
      ),
      throwsFormatException,
    );

    expect(() => repository.audioFile('../escape'), throwsArgumentError);
  });

  test('removes the take directory', () async {
    await repository.saveAudioBytes(
      libraryItemId: libraryItemId,
      itemTitle: 'Morning practice',
      audioBytes: audio,
      takeId: takeId,
    );

    await repository.delete(takeId);

    expect(await repository.list(), isEmpty);
    expect(await repository.audioFile(takeId).exists(), isFalse);
  });

  test('builds validated metadata from WAV bytes', () {
    final metadata = buildPracticeTakeMetadata(
      takeId: takeId,
      libraryItemId: libraryItemId,
      itemTitle: 'Morning practice',
      audioBytes: audio,
      createdAtUtc: DateTime.utc(2026, 10, 22, 8, 30),
    );

    expect(metadata.audioSha256, hasLength(64));
    expect(metadata.toJson()['schema_version'], 1);
    expect(
      () => PracticeTakeMetadata.fromJson(metadata.toJson()),
      returnsNormally,
    );
  });
}
