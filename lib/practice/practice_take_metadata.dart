import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../library/library_metadata.dart';
import '../library/wav_info.dart';

/// Current schema version for one saved practice take.
const int practiceTakeMetadataSchemaVersion = 1;

/// Filename of the durable recording inside a practice take directory.
const String practiceTakeAudioFileName = 'audio.wav';

/// Filename of the practice take metadata file.
const String practiceTakeMetadataFileName = 'metadata.json';

/// A recording saved from the Practice tab.
///
/// The library item ID and title are snapshots. A take remains playable even
/// if the original library item is later deleted.
class PracticeTakeMetadata {
  const PracticeTakeMetadata({
    this.schemaVersion = practiceTakeMetadataSchemaVersion,
    required this.takeId,
    required this.libraryItemId,
    required this.itemTitle,
    required this.createdAtUtc,
    required this.audio,
    required this.audioBytes,
    required this.audioSha256,
  });

  factory PracticeTakeMetadata.fromJson(Map<String, dynamic> json) {
    final schemaVersion = _requiredInt(json, 'schema_version');

    if (schemaVersion != practiceTakeMetadataSchemaVersion) {
      throw FormatException(
        'Unsupported practice take schema version: $schemaVersion.',
      );
    }

    final metadata = PracticeTakeMetadata(
      schemaVersion: schemaVersion,
      takeId: _requiredString(json, 'take_id'),
      libraryItemId: _requiredString(json, 'library_item_id'),
      itemTitle: _requiredString(json, 'item_title'),
      createdAtUtc: _parseUtcTimestamp(json, 'created_at_utc'),
      audio: AudioMetadata.fromJson(_requiredMap(json, 'audio')),
      audioBytes: _requiredInt(json, 'audio_bytes'),
      audioSha256: _requiredString(json, 'audio_sha256'),
    );

    metadata.validate();
    return metadata;
  }

  final int schemaVersion;
  final String takeId;
  final String libraryItemId;
  final String itemTitle;
  final DateTime createdAtUtc;
  final AudioMetadata audio;
  final int audioBytes;
  final String audioSha256;

  Map<String, dynamic> toJson() {
    validate();

    return <String, dynamic>{
      'schema_version': schemaVersion,
      'take_id': takeId,
      'library_item_id': libraryItemId,
      'item_title': itemTitle,
      'created_at_utc': _formatUtc(createdAtUtc),
      'audio': audio.toJson(),
      'audio_bytes': audioBytes,
      'audio_sha256': audioSha256,
    };
  }

  void validate() {
    if (schemaVersion != practiceTakeMetadataSchemaVersion) {
      throw FormatException(
        'Unsupported practice take schema version: $schemaVersion.',
      );
    }

    if (!isValidLibraryItemId(takeId)) {
      throw FormatException('Invalid practice take ID: "$takeId".');
    }

    if (!isValidLibraryItemId(libraryItemId)) {
      throw FormatException(
        'Invalid practice library item ID: "$libraryItemId".',
      );
    }

    if (itemTitle.trim().isEmpty) {
      throw const FormatException('Practice item title must not be empty.');
    }

    if (!createdAtUtc.isUtc) {
      throw const FormatException(
        'Practice take created_at_utc must be stored in UTC.',
      );
    }

    if (audioBytes <= 0) {
      throw const FormatException('Practice audio must not be empty.');
    }

    if (!isValidSha256(audioSha256)) {
      throw const FormatException('Invalid practice audio checksum.');
    }

    audio.validate();
  }
}

/// Builds take metadata from the exact WAV bytes written by the recorder.
PracticeTakeMetadata buildPracticeTakeMetadata({
  required String takeId,
  required String libraryItemId,
  required String itemTitle,
  required Uint8List audioBytes,
  DateTime? createdAtUtc,
}) {
  final wavInfo = WavInfo.parse(audioBytes);

  return PracticeTakeMetadata(
    takeId: takeId,
    libraryItemId: libraryItemId,
    itemTitle: itemTitle.trim(),
    createdAtUtc: (createdAtUtc ?? DateTime.now()).toUtc(),
    audio: AudioMetadata(
      sampleRate: wavInfo.sampleRate,
      channels: wavInfo.channels,
      bitDepth: wavInfo.bitDepth,
      durationSeconds: wavInfo.durationSeconds,
    ),
    audioBytes: audioBytes.length,
    audioSha256: sha256.convert(audioBytes).toString(),
  )..validate();
}

/// Strictly checks that metadata matches the WAV payload in a take.
PracticeTakeMetadata validatePracticeTakePayload({
  required Map<String, dynamic> metadataJson,
  required Uint8List audioBytes,
}) {
  final metadata = PracticeTakeMetadata.fromJson(metadataJson);

  if (audioBytes.isEmpty) {
    throw const FormatException('Practice audio must not be empty.');
  }

  if (metadata.audioBytes != audioBytes.length) {
    throw const FormatException(
      'Practice metadata audio size does not match audio.wav.',
    );
  }

  final expectedChecksum = sha256.convert(audioBytes).toString();

  if (metadata.audioSha256 != expectedChecksum) {
    throw const FormatException('Practice audio checksum verification failed.');
  }

  final wavInfo = WavInfo.parse(audioBytes);

  if (wavInfo.sampleRate != metadata.audio.sampleRate ||
      wavInfo.channels != metadata.audio.channels ||
      wavInfo.bitDepth != metadata.audio.bitDepth) {
    throw const FormatException(
      'Practice metadata audio format does not match audio.wav.',
    );
  }

  final declaredDuration = metadata.audio.durationSeconds;

  if (declaredDuration != null &&
      (declaredDuration - wavInfo.durationSeconds).abs() > 0.1) {
    throw const FormatException(
      'Practice metadata duration does not match audio.wav.',
    );
  }

  return metadata;
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];

  if (value is! String || value.trim().isEmpty) {
    throw FormatException('"$key" must be a non-empty string.');
  }

  return value;
}

int _requiredInt(Map<String, dynamic> json, String key) {
  final value = json[key];

  if (value is! int) {
    throw FormatException('"$key" must be an integer.');
  }

  return value;
}

Map<String, dynamic> _requiredMap(Map<String, dynamic> json, String key) {
  final value = json[key];

  if (value is! Map<String, dynamic>) {
    throw FormatException('"$key" must be an object.');
  }

  return value;
}

DateTime _parseUtcTimestamp(Map<String, dynamic> json, String key) {
  final rawValue = json[key];

  if (rawValue is! String) {
    throw FormatException('"$key" must be a string.');
  }

  final value = DateTime.tryParse(rawValue);

  if (value == null || !value.isUtc) {
    throw FormatException(
      '"$key" must be an ISO-8601 UTC timestamp ending in Z.',
    );
  }

  return value;
}

String _formatUtc(DateTime value) => value.toUtc().toIso8601String();
