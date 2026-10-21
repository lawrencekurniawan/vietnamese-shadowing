import 'package:flutter_test/flutter_test.dart';
import 'package:vietnamese_shadowing/library/library_metadata.dart';
import 'package:vietnamese_shadowing/library/library_storage.dart';
import 'package:vietnamese_shadowing/native/vieneu_ffi.dart';

void main() {
  const voice = VoiceMetadata(
    stableId: 'minh-duc',
    presetName: 'Minh Đức',
    displayName: 'Minh Đức',
    description: 'Nam · Bắc · Phong cách tin tức',
    gender: 'male',
    accent: 'Bắc',
    style: 'tin_tuc',
  );

  const audio = AudioMetadata(
    sampleRate: 24000,
    channels: 1,
    bitDepth: 16,
    durationSeconds: 1.5,
  );

  const itemId = '123e4567-e89b-42d3-a456-426614174000';
  final createdAt = DateTime.utc(2026, 10, 20, 14, 30, 45);
  final checksum = List<String>.filled(64, 'a').join();

  test('local library metadata round trips as versioned JSON', () {
    final metadata = LibraryItemMetadata(
      itemId: itemId,
      title: 'Xin chào',
      originalText: 'Xin chào, thế giới!',
      normalizedText: 'xin chào, thế giới!',
      voice: voice,
      createdAtUtc: createdAt,
      audio: audio,
    );

    final json = metadata.toJson();
    final decoded = LibraryItemMetadata.fromJson(json);

    expect(json['schema_version'], libraryMetadataSchemaVersion);
    expect(json['created_at_utc'], '2026-10-20T14:30:45.000Z');
    expect(json['audio_file'], libraryAudioFileName);
    expect(decoded.toJson(), json);
  });

  test('local library metadata rejects unsupported schema versions', () {
    final json = LibraryItemMetadata(
      itemId: itemId,
      title: 'Title',
      originalText: 'Text',
      normalizedText: 'Text',
      voice: voice,
      createdAtUtc: createdAt,
      audio: audio,
    ).toJson();

    json['schema_version'] = 2;

    expect(() => LibraryItemMetadata.fromJson(json), throwsFormatException);
  });

  test('local library item IDs must be UUID v4 values', () {
    final metadata = LibraryItemMetadata(
      itemId: '../outside-library',
      title: 'Title',
      originalText: 'Text',
      normalizedText: 'Text',
      voice: voice,
      createdAtUtc: createdAt,
      audio: audio,
    );

    expect(metadata.validate, throwsFormatException);
    expect(
      () => LibraryStorage.itemDirectory('../outside-library'),
      throwsArgumentError,
    );
  });

  test('stored timestamps must be UTC', () {
    final metadata = LibraryItemMetadata(
      itemId: itemId,
      title: 'Title',
      originalText: 'Text',
      normalizedText: 'Text',
      voice: voice,
      createdAtUtc: DateTime(2026, 10, 20, 14, 30, 45),
      audio: audio,
    );

    expect(metadata.validate, throwsFormatException);
  });

  test('audio metadata validates format and bounds', () {
    expect(
      () => const AudioMetadata(
        format: 'mp3',
        sampleRate: 24000,
        channels: 1,
        bitDepth: 16,
      ).validate(),
      throwsFormatException,
    );
    expect(
      () => const AudioMetadata(
        sampleRate: 0,
        channels: 1,
        bitDepth: 16,
      ).validate(),
      throwsFormatException,
    );
    expect(
      () => const AudioMetadata(
        sampleRate: 24000,
        channels: 0,
        bitDepth: 16,
      ).validate(),
      throwsFormatException,
    );
    expect(
      () => const AudioMetadata(
        sampleRate: 24000,
        channels: 1,
        bitDepth: 12,
      ).validate(),
      throwsFormatException,
    );
    expect(
      () => const AudioMetadata(
        sampleRate: 24000,
        channels: 1,
        bitDepth: 16,
        durationSeconds: 0,
      ).validate(),
      throwsFormatException,
    );
  });

  test('voice metadata is derived from the native voice identity', () {
    const nativeVoice = VietnameseVoice(
      id: 'Minh Đức',
      name: 'Minh Đức',
      description: 'Nam · Bắc · Phong cách tin tức',
      gender: 'male',
      accent: 'Bắc',
      style: 'tin_tuc',
    );

    final metadata = VoiceMetadata.fromVoice(nativeVoice);

    expect(metadata.stableId, 'minh-duc');
    expect(metadata.presetName, 'Minh Đức');
    expect(metadata.displayName, 'Minh Đức');
  });

  test(
    '.vshadow metadata round trips and preserves portable voice identity',
    () {
      final metadata = VshadowMetadata(
        title: 'Xin chào',
        originalText: 'Xin chào, thế giới!',
        normalizedText: 'xin chào, thế giới!',
        voice: voice,
        createdAtUtc: createdAt,
        audio: audio,
        audioBytes: 48044,
        audioSha256: checksum,
      );

      final json = metadata.toJson();
      final decoded = VshadowMetadata.fromJson(json);

      expect(json['schema_version'], vshadowMetadataSchemaVersion);
      expect(json['voice'], containsPair('stable_id', 'minh-duc'));
      expect(json['voice'], containsPair('display_name', 'Minh Đức'));
      expect(decoded.toJson(), json);
    },
  );

  test('.vshadow metadata rejects unsupported versions and bad checksums', () {
    final metadata = VshadowMetadata(
      title: 'Title',
      originalText: 'Text',
      normalizedText: 'Text',
      voice: voice,
      createdAtUtc: createdAt,
      audio: audio,
      audioBytes: 100,
      audioSha256: checksum,
    );

    final unsupported = metadata.toJson()..['schema_version'] = 2;
    expect(() => VshadowMetadata.fromJson(unsupported), throwsFormatException);

    final badChecksum = metadata.toJson()..['audio_sha256'] = 'not-a-checksum';
    expect(() => VshadowMetadata.fromJson(badChecksum), throwsFormatException);
  });

  test('.vshadow metadata enforces the initial package audio limit', () {
    final metadata = VshadowMetadata(
      title: 'Title',
      originalText: 'Text',
      normalizedText: 'Text',
      voice: voice,
      createdAtUtc: createdAt,
      audio: audio,
      audioBytes: maxVshadowPackageBytes + 1,
      audioSha256: checksum,
    );

    expect(metadata.validate, throwsFormatException);
  });

  test('package contract exposes exactly two root entries', () {
    expect(vshadowRootEntries, ['metadata.json', 'audio.wav']);
    expect(vshadowRootEntries.toSet(), hasLength(2));
    expect(maxVshadowPackageBytes, 200 * 1024 * 1024);
    expect(maxVshadowMetadataBytes, 1024 * 1024);
  });

  test('storage layout keeps library audio separate from the cache', () {
    expect(LibraryStorage.rootDirectory, 'vieneu');
    expect(LibraryStorage.assetsDirectory, 'vieneu/assets');
    expect(LibraryStorage.ttsCacheDirectory, 'vieneu/tts-cache');
    expect(LibraryStorage.libraryDirectory, 'vieneu/library');
    expect(LibraryStorage.itemDirectory(itemId), 'vieneu/library/$itemId');
    expect(
      LibraryStorage.metadataPath(itemId),
      'vieneu/library/$itemId/metadata.json',
    );
    expect(
      LibraryStorage.audioPath(itemId),
      'vieneu/library/$itemId/audio.wav',
    );
    expect(
      LibraryStorage.audioPath(itemId)
          .startsWith(LibraryStorage.ttsCacheDirectory),
      isFalse,
    );
  });
}
