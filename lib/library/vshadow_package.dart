import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import '../voices/voice_identity.dart';
import 'library_ids.dart';
import 'library_metadata.dart';
import 'library_repository.dart';
import 'wav_export_filename.dart';
import 'wav_info.dart';

const String vshadowFileExtension = '.vshadow';
const String vshadowMetadataEntry = 'metadata.json';
const String vshadowAudioEntry = 'audio.wav';

class VshadowPackageData {
  const VshadowPackageData({required this.metadata, required this.audioBytes});

  final VshadowMetadata metadata;
  final Uint8List audioBytes;
}

/// Builds the `.vshadow` export filename from the same slug convention as WAV
/// exports.
String buildVshadowExportFilename({
  required String text,
  required String stableVoiceId,
  DateTime? exportedAt,
  int collisionIndex = 0,
}) {
  final wavName = buildWavExportFilename(
    text: text,
    stableVoiceId: stableVoiceId,
    exportedAt: exportedAt,
    collisionIndex: collisionIndex,
  );

  final stem = wavName.substring(0, wavName.length - wavFileExtension.length);

  return '$stem$vshadowFileExtension';
}

/// Creates package metadata from the durable library item and its exact audio
/// bytes.
VshadowMetadata buildVshadowMetadata({
  required LibraryItemMetadata item,
  required Uint8List audioBytes,
}) {
  final wavInfo = WavInfo.parse(audioBytes);

  return VshadowMetadata(
    title: item.title,
    originalText: item.originalText,
    normalizedText: item.normalizedText,
    voice: item.voice,
    createdAtUtc: item.createdAtUtc,
    audio: AudioMetadata(
      sampleRate: wavInfo.sampleRate,
      channels: wavInfo.channels,
      bitDepth: wavInfo.bitDepth,
      durationSeconds: wavInfo.durationSeconds,
    ),
    audioBytes: audioBytes.length,
    audioSha256: sha256.convert(audioBytes).toString(),
  );
}

/// Encodes a ZIP-compatible `.vshadow` package with exactly two root entries.
Uint8List encodeVshadowPackage({
  required VshadowMetadata metadata,
  required List<int> audioBytes,
}) {
  if (audioBytes.isEmpty || audioBytes.length > maxVshadowPackageBytes) {
    throw FormatException(
      'Audio payload must be between 1 and $maxVshadowPackageBytes bytes.',
    );
  }

  final metadataJson = jsonEncode(metadata.toJson());
  final metadataBytes = utf8.encode(metadataJson);

  if (metadataBytes.length > maxVshadowMetadataBytes) {
    throw FormatException(
      'Metadata must not exceed $maxVshadowMetadataBytes bytes.',
    );
  }

  final archive = Archive()
    ..add(ArchiveFile.string(vshadowMetadataEntry, metadataJson))
    ..add(ArchiveFile.bytes(vshadowAudioEntry, audioBytes));

  return ZipEncoder().encodeBytes(archive);
}

/// Strictly validates a `.vshadow` package before any installation occurs.
///
/// The optional limits are injectable for tests; production callers use the
/// versioned defaults from `library_metadata.dart`.
VshadowPackageData decodeVshadowPackage(
  Uint8List packageBytes, {
  int maxPackageBytes = maxVshadowPackageBytes,
  int maxMetadataBytes = maxVshadowMetadataBytes,
}) {
  if (packageBytes.isEmpty || packageBytes.length > maxPackageBytes) {
    throw FormatException(
      'Package must be between 1 and $maxPackageBytes bytes.',
    );
  }

  final decoder = ZipDecoder();
  final Archive archive;

  try {
    archive = decoder.decodeBytes(packageBytes);
  } on ArchiveException catch (error) {
    throw FormatException('Invalid .vshadow archive: $error');
  } on RangeError catch (error) {
    throw FormatException('Invalid .vshadow archive: $error');
  }

  final headers = decoder.directory.fileHeaders;

  if (headers.length != vshadowRootEntries.length) {
    throw FormatException(
      '.vshadow must contain exactly ${vshadowRootEntries.length} root entries.',
    );
  }

  final names = headers.map((header) => header.filename).toList();

  if (names.toSet().length != names.length) {
    throw const FormatException(
      'Duplicate .vshadow entry names are not allowed.',
    );
  }

  for (final name in names) {
    _validateRootEntryName(name);

    if (!vshadowRootEntries.contains(name)) {
      throw FormatException('Unexpected .vshadow entry: "$name".');
    }
  }

  if (!names.toSet().containsAll(vshadowRootEntries)) {
    throw const FormatException('.vshadow is missing a required entry.');
  }

  for (final header in headers) {
    if (header.filename == vshadowMetadataEntry &&
        header.uncompressedSize > maxMetadataBytes) {
      throw FormatException(
        'Metadata must not exceed $maxMetadataBytes bytes.',
      );
    }

    if (header.filename == vshadowAudioEntry &&
        (header.uncompressedSize <= 0 ||
            header.uncompressedSize > maxPackageBytes)) {
      throw FormatException(
        'Audio payload must be between 1 and $maxPackageBytes bytes.',
      );
    }
  }

  final metadataEntry = archive.find(vshadowMetadataEntry);
  final audioEntry = archive.find(vshadowAudioEntry);

  if (metadataEntry == null ||
      audioEntry == null ||
      !metadataEntry.isFile ||
      !audioEntry.isFile ||
      metadataEntry.isSymbolicLink ||
      audioEntry.isSymbolicLink) {
    throw const FormatException('.vshadow root entries must be regular files.');
  }

  final metadataBytes = metadataEntry.readBytes();
  final audioBytes = audioEntry.readBytes();

  if (metadataBytes == null ||
      metadataBytes.length > maxMetadataBytes ||
      metadataBytes.length != metadataEntry.size) {
    throw FormatException('Metadata must be at most $maxMetadataBytes bytes.');
  }

  if (audioBytes == null ||
      audioBytes.isEmpty ||
      audioBytes.length > maxPackageBytes ||
      audioBytes.length != audioEntry.size) {
    throw FormatException(
      'Audio payload must be between 1 and $maxPackageBytes bytes.',
    );
  }

  final dynamic decoded;

  try {
    decoded = jsonDecode(utf8.decode(metadataBytes));
  } on FormatException catch (error) {
    throw FormatException('Invalid .vshadow metadata JSON: $error');
  }

  if (decoded is! Map) {
    throw const FormatException('.vshadow metadata must be a JSON object.');
  }

  final metadata = VshadowMetadata.fromJson(decoded.cast<String, dynamic>());

  _validatePortableVoiceIdentity(metadata.voice);

  if (metadata.audioBytes != audioBytes.length) {
    throw const FormatException(
      'Metadata audio size does not match audio.wav.',
    );
  }

  final expectedChecksum = sha256.convert(audioBytes).toString();

  if (metadata.audioSha256 != expectedChecksum) {
    throw const FormatException('audio.wav checksum verification failed.');
  }

  final wavInfo = WavInfo.parse(audioBytes);

  if (wavInfo.sampleRate != metadata.audio.sampleRate ||
      wavInfo.channels != metadata.audio.channels ||
      wavInfo.bitDepth != metadata.audio.bitDepth) {
    throw const FormatException(
      'Metadata audio format does not match audio.wav.',
    );
  }

  final declaredDuration = metadata.audio.durationSeconds;

  if (declaredDuration != null &&
      (declaredDuration - wavInfo.durationSeconds).abs() > 0.1) {
    throw const FormatException(
      'Metadata audio duration does not match audio.wav.',
    );
  }

  return VshadowPackageData(metadata: metadata, audioBytes: audioBytes);
}

class VshadowPackageService {
  VshadowPackageService({required LibraryRepository repository})
    : this._(repository);

  VshadowPackageService._(this._repository);

  final LibraryRepository _repository;

  Future<Uint8List> exportItem(LibraryItemMetadata item) async {
    final audioFile = _repository.audioFile(item.itemId);

    if (!await audioFile.exists()) {
      throw StateError('Library audio is missing: ${audioFile.path}');
    }

    final audioBytes = await audioFile.readAsBytes();
    final metadata = buildVshadowMetadata(item: item, audioBytes: audioBytes);

    return encodeVshadowPackage(metadata: metadata, audioBytes: audioBytes);
  }

  /// Imports a validated package with a fresh local UUID.
  ///
  /// Existing library items are never overwritten. If the first generated ID
  /// collides, another is allocated.
  Future<LibraryItemMetadata> importBytes(Uint8List packageBytes) async {
    final package = decodeVshadowPackage(packageBytes);

    for (var attempt = 0; attempt < 8; attempt++) {
      final itemId = generateLibraryItemId();

      try {
        return await _repository.saveAudioBytes(
          title: package.metadata.title,
          originalText: package.metadata.originalText,
          normalizedText: package.metadata.normalizedText,
          voice: package.metadata.voice,
          audioBytes: package.audioBytes,
          createdAtUtc: package.metadata.createdAtUtc,
          itemId: itemId,
        );
      } on LibraryItemExistsException {
        continue;
      }
    }

    throw StateError('Could not allocate a unique library item ID.');
  }
}

void _validateRootEntryName(String name) {
  if (name.isEmpty ||
      name.startsWith('/') ||
      name.startsWith(r'\') ||
      name.contains('../') ||
      name.contains(r'..\') ||
      name.contains(r'\') ||
      name.contains('\u0000') ||
      name.contains(':')) {
    throw FormatException('Unsafe .vshadow entry name: "$name".');
  }

  if (name == '.' || name == '..') {
    throw FormatException('Unsafe .vshadow entry name: "$name".');
  }
}

void _validatePortableVoiceIdentity(VoiceMetadata voice) {
  final identity = VoiceIdentity.tryFromStableId(voice.stableId);

  if (identity == null) {
    throw FormatException('Unknown stable voice ID: "${voice.stableId}".');
  }

  if (identity.presetName != voice.presetName) {
    throw FormatException(
      'Voice preset "${voice.presetName}" does not match stable ID '
      '"${voice.stableId}".',
    );
  }
}
