import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vietnamese_shadowing/library/library_metadata.dart';
import 'package:vietnamese_shadowing/library/library_repository.dart';
import 'package:vietnamese_shadowing/library/vshadow_package.dart';
import 'package:vietnamese_shadowing/library/wav_info.dart';

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

  final audio = buildTestWav(sampleFrames: 2400);
  final wavInfo = WavInfo.parse(audio);

  VshadowMetadata createMetadata({
    List<int>? audioBytes,
    String stableId = 'mai-anh',
    String presetName = 'Mai Anh',
    int? sampleRate,
    String? checksum,
  }) {
    final bytes = audioBytes ?? audio;

    return VshadowMetadata(
      title: 'Xin chào',
      originalText: 'Xin chào, thế giới!',
      normalizedText: 'xin chào, thế giới!',
      voice: VoiceMetadata(
        stableId: stableId,
        presetName: presetName,
        displayName: voice.displayName,
        description: voice.description,
        gender: voice.gender,
        accent: voice.accent,
        style: voice.style,
      ),
      createdAtUtc: DateTime.utc(2026, 10, 20, 14, 30, 45),
      audio: AudioMetadata(
        sampleRate: sampleRate ?? wavInfo.sampleRate,
        channels: wavInfo.channels,
        bitDepth: wavInfo.bitDepth,
        durationSeconds: wavInfo.durationSeconds,
      ),
      audioBytes: bytes.length,
      audioSha256: checksum ?? sha256.convert(bytes).toString(),
    );
  }

  Uint8List encodeRawPackage(
    Map<String, dynamic> metadataJson,
    List<int> audioBytes, {
    ArchiveFile? extraEntry,
  }) {
    final archive = Archive()
      ..add(ArchiveFile.string('metadata.json', jsonEncode(metadataJson)))
      ..add(ArchiveFile.bytes('audio.wav', audioBytes));

    if (extraEntry != null) {
      archive.add(extraEntry);
    }

    return ZipEncoder().encodeBytes(archive);
  }

  test('valid package round trips metadata and audio', () {
    final metadata = createMetadata();
    final package = encodeVshadowPackage(metadata: metadata, audioBytes: audio);

    final decoded = decodeVshadowPackage(package);

    expect(decoded.metadata.toJson(), metadata.toJson());
    expect(decoded.audioBytes, audio);
    expect(
      buildVshadowExportFilename(
        text: 'Xin chào, thế giới!',
        stableVoiceId: 'mai-anh',
        exportedAt: DateTime(2026, 10, 20, 14, 30, 45),
      ),
      endsWith('.vshadow'),
    );
  });

  test('rejects malformed archive bytes', () {
    expect(
      () => decodeVshadowPackage(Uint8List.fromList([1, 2, 3, 4])),
      throwsFormatException,
    );
  });

  test('rejects unexpected entries and directories', () {
    final metadata = createMetadata();
    final package = encodeRawPackage(
      metadata.toJson(),
      audio,
      extraEntry: ArchiveFile.string('model.onnx', 'not allowed'),
    );

    expect(() => decodeVshadowPackage(package), throwsFormatException);
  });

  test('rejects duplicate entry names', () {
    final metadata = createMetadata();
    final archive = Archive()
      ..add(ArchiveFile.string('metadata.json', jsonEncode(metadata.toJson())))
      ..add(ArchiveFile.bytes('extra.bin', Uint8List(0)));

    archive.modifyAtIndex(
      1,
      ArchiveFile.string('metadata.json', jsonEncode(metadata.toJson())),
    );

    final package = ZipEncoder().encodeBytes(archive);

    expect(() => decodeVshadowPackage(package), throwsFormatException);
  });

  test('rejects path traversal names', () {
    final metadata = createMetadata();
    final archive = Archive()
      ..add(
        ArchiveFile.string('../metadata.json', jsonEncode(metadata.toJson())),
      )
      ..add(ArchiveFile.bytes('audio.wav', audio));

    final package = ZipEncoder().encodeBytes(archive);

    expect(() => decodeVshadowPackage(package), throwsFormatException);
  });

  test('rejects unsupported metadata versions', () {
    final metadataJson = createMetadata().toJson()..['schema_version'] = 2;
    final package = encodeRawPackage(metadataJson, audio);

    expect(() => decodeVshadowPackage(package), throwsFormatException);
  });

  test('rejects malformed metadata JSON', () {
    final archive = Archive()
      ..add(ArchiveFile.string('metadata.json', '{not-json'))
      ..add(ArchiveFile.bytes('audio.wav', audio));
    final package = ZipEncoder().encodeBytes(archive);

    expect(() => decodeVshadowPackage(package), throwsFormatException);
  });

  test('rejects invalid audio WAV data', () {
    final invalidAudio = Uint8List(100);
    final metadata = createMetadata(audioBytes: invalidAudio);
    final package = encodeVshadowPackage(
      metadata: metadata,
      audioBytes: invalidAudio,
    );

    expect(() => decodeVshadowPackage(package), throwsFormatException);
  });

  test('rejects checksum failures', () {
    final metadata = createMetadata(
      checksum: List<String>.filled(64, '0').join(),
    );
    final package = encodeVshadowPackage(metadata: metadata, audioBytes: audio);

    expect(() => decodeVshadowPackage(package), throwsFormatException);
  });

  test('rejects metadata/audio format mismatches', () {
    final metadata = createMetadata(sampleRate: 48000);
    final package = encodeVshadowPackage(metadata: metadata, audioBytes: audio);

    expect(() => decodeVshadowPackage(package), throwsFormatException);
  });

  test('rejects unknown or mismatched portable voice identity', () {
    final unknown = createMetadata(stableId: 'unknown-voice');
    final unknownPackage = encodeVshadowPackage(
      metadata: unknown,
      audioBytes: audio,
    );
    expect(() => decodeVshadowPackage(unknownPackage), throwsFormatException);

    final mismatched = createMetadata(stableId: 'minh-duc');
    final mismatchedPackage = encodeVshadowPackage(
      metadata: mismatched,
      audioBytes: audio,
    );
    expect(
      () => decodeVshadowPackage(mismatchedPackage),
      throwsFormatException,
    );
  });

  test('enforces package and metadata size limits', () {
    final metadata = createMetadata();
    final package = encodeVshadowPackage(metadata: metadata, audioBytes: audio);

    expect(
      () => decodeVshadowPackage(package, maxPackageBytes: 10),
      throwsFormatException,
    );
    expect(
      () => decodeVshadowPackage(package, maxMetadataBytes: 10),
      throwsFormatException,
    );
  });

  group('library import/export', () {
    late Directory temporaryDirectory;
    late LibraryRepository repository;
    late VshadowPackageService service;

    setUp(() async {
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'vshadow-package-test-',
      );
      repository = await LibraryRepository.open(
        applicationSupportDirectory: temporaryDirectory,
      );
      service = VshadowPackageService(repository: repository);
    });

    tearDown(() async {
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    });

    test(
      'exports a durable item and imports it with a new local UUID',
      () async {
        final original = await repository.saveAudioBytes(
          title: 'Original',
          originalText: 'Xin chào, thế giới!',
          normalizedText: 'xin chào, thế giới!',
          voice: voice,
          audioBytes: audio,
          createdAtUtc: DateTime.utc(2026, 10, 20, 14, 30, 45),
        );

        final package = await service.exportItem(original);
        final imported = await service.importBytes(package);
        final items = await repository.list();

        expect(items, hasLength(2));
        expect(imported.itemId, isNot(original.itemId));
        expect(imported.title, original.title);
        expect(imported.originalText, original.originalText);
        expect(imported.normalizedText, original.normalizedText);
        expect(imported.voice.stableId, 'mai-anh');
        expect(imported.createdAtUtc, original.createdAtUtc);
        expect(
          await repository.audioFile(imported.itemId).readAsBytes(),
          audio,
        );
      },
    );

    test('importing the same package twice never overwrites an item', () async {
      final original = await repository.saveAudioBytes(
        title: 'Original',
        originalText: 'Nội dung',
        normalizedText: 'nội dung',
        voice: voice,
        audioBytes: audio,
      );

      final package = await service.exportItem(original);
      final first = await service.importBytes(package);
      final second = await service.importBytes(package);
      final items = await repository.list();

      expect(items, hasLength(3));
      expect(first.itemId, isNot(second.itemId));
      expect(first.itemId, isNot(original.itemId));
    });
  });
}
