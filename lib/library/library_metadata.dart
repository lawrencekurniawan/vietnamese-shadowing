import '../native/vieneu_ffi.dart';
import '../voices/voice_identity.dart';

/// Current local library metadata schema version.
const int libraryMetadataSchemaVersion = 1;

/// Current `.vshadow` metadata schema version.
const int vshadowMetadataSchemaVersion = 1;

/// Filename of the durable audio file inside a library item.
const String libraryAudioFileName = 'audio.wav';

/// Filename of the local library metadata file.
const String libraryMetadataFileName = 'metadata.json';

/// Root entries allowed inside a `.vshadow` package.
const List<String> vshadowRootEntries = <String>['metadata.json', 'audio.wav'];

/// Initial package-size limits. These are intentionally conservative and can
/// be reviewed before package import/export ships.
const int maxVshadowPackageBytes = 200 * 1024 * 1024;
const int maxVshadowMetadataBytes = 1 * 1024 * 1024;

final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
final RegExp _uuidV4Pattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

bool isValidLibraryItemId(String value) => _uuidV4Pattern.hasMatch(value);

bool isValidSha256(String value) => _sha256Pattern.hasMatch(value);

/// Portable, human-readable voice metadata stored with a library item or
/// `.vshadow` package.
class VoiceMetadata {
  const VoiceMetadata({
    required this.stableId,
    required this.presetName,
    required this.displayName,
    required this.description,
    required this.gender,
    required this.accent,
    required this.style,
  });

  factory VoiceMetadata.fromVoice(VietnameseVoice voice) {
    final identity = voice.voiceIdentity;

    return VoiceMetadata(
      stableId: identity.stableId,
      presetName: identity.presetName,
      displayName: voice.name,
      description: voice.description,
      gender: voice.gender,
      accent: voice.accent,
      style: voice.style,
    )..validate();
  }

  factory VoiceMetadata.fromJson(Map<String, dynamic> json) {
    final metadata = VoiceMetadata(
      stableId: _requiredString(json, 'stable_id'),
      presetName: _requiredString(json, 'preset_name'),
      displayName: _requiredString(json, 'display_name'),
      description: _requiredString(json, 'description', allowEmpty: true),
      gender: _requiredString(json, 'gender'),
      accent: _requiredString(json, 'accent'),
      style: _requiredString(json, 'style'),
    );

    metadata.validate();
    return metadata;
  }

  final String stableId;
  final String presetName;
  final String displayName;
  final String description;
  final String gender;
  final String accent;
  final String style;

  Map<String, dynamic> toJson() {
    validate();

    return <String, dynamic>{
      'stable_id': stableId,
      'preset_name': presetName,
      'display_name': displayName,
      'description': description,
      'gender': gender,
      'accent': accent,
      'style': style,
    };
  }

  void validate() {
    if (!isValidStableVoiceId(stableId)) {
      throw FormatException('Invalid stable voice ID: "$stableId".');
    }

    _requireNonEmpty(presetName, 'preset_name');
    _requireNonEmpty(displayName, 'display_name');
    _requireNonEmpty(gender, 'gender');
    _requireNonEmpty(accent, 'accent');
    _requireNonEmpty(style, 'style');
  }
}

/// Audio format details shared by local library items and `.vshadow` packages.
class AudioMetadata {
  const AudioMetadata({
    this.format = 'wav',
    required this.sampleRate,
    required this.channels,
    required this.bitDepth,
    this.durationSeconds,
  });

  factory AudioMetadata.fromJson(Map<String, dynamic> json) {
    final metadata = AudioMetadata(
      format: _requiredString(json, 'format'),
      sampleRate: _requiredInt(json, 'sample_rate'),
      channels: _requiredInt(json, 'channels'),
      bitDepth: _requiredInt(json, 'bit_depth'),
      durationSeconds: _optionalDouble(json, 'duration_seconds'),
    );

    metadata.validate();
    return metadata;
  }

  final String format;
  final int sampleRate;
  final int channels;
  final int bitDepth;
  final double? durationSeconds;

  Map<String, dynamic> toJson() {
    validate();

    return <String, dynamic>{
      'format': format,
      'sample_rate': sampleRate,
      'channels': channels,
      'bit_depth': bitDepth,
      if (durationSeconds != null) 'duration_seconds': durationSeconds,
    };
  }

  void validate() {
    if (format.toLowerCase() != 'wav') {
      throw FormatException('Unsupported audio format: "$format".');
    }

    if (sampleRate < 8000 || sampleRate > 384000) {
      throw FormatException('Invalid audio sample rate: $sampleRate.');
    }

    if (channels < 1 || channels > 8) {
      throw FormatException('Invalid audio channel count: $channels.');
    }

    if (!<int>{8, 16, 24, 32}.contains(bitDepth)) {
      throw FormatException('Invalid audio bit depth: $bitDepth.');
    }

    final duration = durationSeconds;

    if (duration != null && (!duration.isFinite || duration <= 0)) {
      throw FormatException('Invalid audio duration: $duration.');
    }
  }
}

/// Metadata for one durable item in the local library.
///
/// The item ID is local and is never used as a portable identity. Portable
/// metadata uses the stable voice ID instead.
class LibraryItemMetadata {
  const LibraryItemMetadata({
    this.schemaVersion = libraryMetadataSchemaVersion,
    required this.itemId,
    required this.title,
    required this.originalText,
    required this.normalizedText,
    required this.voice,
    required this.createdAtUtc,
    required this.audio,
    this.audioFileName = libraryAudioFileName,
  });

  factory LibraryItemMetadata.fromJson(Map<String, dynamic> json) {
    final schemaVersion = _requiredInt(json, 'schema_version');

    if (schemaVersion != libraryMetadataSchemaVersion) {
      throw FormatException(
        'Unsupported library metadata schema version: $schemaVersion.',
      );
    }

    final metadata = LibraryItemMetadata(
      schemaVersion: schemaVersion,
      itemId: _requiredString(json, 'item_id'),
      title: _requiredString(json, 'title'),
      originalText: _requiredString(json, 'original_text'),
      normalizedText: _requiredString(json, 'normalized_text'),
      voice: VoiceMetadata.fromJson(_requiredMap(json, 'voice')),
      createdAtUtc: _parseUtcTimestamp(json, 'created_at_utc'),
      audio: AudioMetadata.fromJson(_requiredMap(json, 'audio')),
      audioFileName: _requiredString(json, 'audio_file'),
    );

    metadata.validate();
    return metadata;
  }

  final int schemaVersion;
  final String itemId;
  final String title;
  final String originalText;
  final String normalizedText;
  final VoiceMetadata voice;
  final DateTime createdAtUtc;
  final AudioMetadata audio;
  final String audioFileName;

  Map<String, dynamic> toJson() {
    validate();

    return <String, dynamic>{
      'schema_version': schemaVersion,
      'item_id': itemId,
      'title': title,
      'original_text': originalText,
      'normalized_text': normalizedText,
      'voice': voice.toJson(),
      'created_at_utc': _formatUtc(createdAtUtc),
      'audio': audio.toJson(),
      'audio_file': audioFileName,
    };
  }

  void validate() {
    if (schemaVersion != libraryMetadataSchemaVersion) {
      throw FormatException(
        'Unsupported library metadata schema version: $schemaVersion.',
      );
    }

    if (!isValidLibraryItemId(itemId)) {
      throw FormatException('Invalid library item ID: "$itemId".');
    }

    _requireNonEmpty(title, 'title');
    _requireNonEmpty(originalText, 'original_text');
    _requireNonEmpty(normalizedText, 'normalized_text');

    if (!createdAtUtc.isUtc) {
      throw FormatException('created_at_utc must be stored in UTC.');
    }

    if (audioFileName != libraryAudioFileName) {
      throw FormatException(
        'Library audio file must be named "$libraryAudioFileName".',
      );
    }

    voice.validate();
    audio.validate();
  }
}

/// Versioned metadata stored as `metadata.json` inside a `.vshadow` package.
///
/// The package itself must contain exactly `metadata.json` and `audio.wav`.
/// Import/export, ZIP handling, checksum verification, and file registration
/// belong to a later phase.
class VshadowMetadata {
  const VshadowMetadata({
    this.schemaVersion = vshadowMetadataSchemaVersion,
    required this.title,
    required this.originalText,
    required this.normalizedText,
    required this.voice,
    required this.createdAtUtc,
    required this.audio,
    required this.audioBytes,
    required this.audioSha256,
  });

  factory VshadowMetadata.fromJson(Map<String, dynamic> json) {
    final schemaVersion = _requiredInt(json, 'schema_version');

    if (schemaVersion != vshadowMetadataSchemaVersion) {
      throw FormatException(
        'Unsupported .vshadow metadata schema version: $schemaVersion.',
      );
    }

    final metadata = VshadowMetadata(
      schemaVersion: schemaVersion,
      title: _requiredString(json, 'title'),
      originalText: _requiredString(json, 'original_text'),
      normalizedText: _requiredString(json, 'normalized_text'),
      voice: VoiceMetadata.fromJson(_requiredMap(json, 'voice')),
      createdAtUtc: _parseUtcTimestamp(json, 'created_at_utc'),
      audio: AudioMetadata.fromJson(_requiredMap(json, 'audio')),
      audioBytes: _requiredInt(json, 'audio_bytes'),
      audioSha256: _requiredString(json, 'audio_sha256'),
    );

    metadata.validate();
    return metadata;
  }

  final int schemaVersion;
  final String title;
  final String originalText;
  final String normalizedText;
  final VoiceMetadata voice;
  final DateTime createdAtUtc;
  final AudioMetadata audio;
  final int audioBytes;

  /// SHA-256 of the package's `audio.wav`, as lowercase hexadecimal.
  ///
  /// This is an integrity check, not an authenticity or security guarantee.
  final String audioSha256;

  Map<String, dynamic> toJson() {
    validate();

    return <String, dynamic>{
      'schema_version': schemaVersion,
      'title': title,
      'original_text': originalText,
      'normalized_text': normalizedText,
      'voice': voice.toJson(),
      'created_at_utc': _formatUtc(createdAtUtc),
      'audio': audio.toJson(),
      'audio_bytes': audioBytes,
      'audio_sha256': audioSha256,
    };
  }

  void validate() {
    if (schemaVersion != vshadowMetadataSchemaVersion) {
      throw FormatException(
        'Unsupported .vshadow metadata schema version: $schemaVersion.',
      );
    }

    _requireNonEmpty(title, 'title');
    _requireNonEmpty(originalText, 'original_text');
    _requireNonEmpty(normalizedText, 'normalized_text');

    if (!createdAtUtc.isUtc) {
      throw FormatException('created_at_utc must be stored in UTC.');
    }

    if (audioBytes <= 0 || audioBytes > maxVshadowPackageBytes) {
      throw FormatException(
        'Audio payload must be between 1 and $maxVshadowPackageBytes bytes.',
      );
    }

    if (!isValidSha256(audioSha256)) {
      throw FormatException(
        'audio_sha256 must be 64 lowercase hexadecimal characters.',
      );
    }

    voice.validate();
    audio.validate();
  }
}

String _requiredString(
  Map<String, dynamic> json,
  String key, {
  bool allowEmpty = false,
}) {
  final value = json[key];

  if (value is! String) {
    throw FormatException('"$key" must be a string.');
  }

  if (!allowEmpty) {
    _requireNonEmpty(value, key);
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

double? _optionalDouble(Map<String, dynamic> json, String key) {
  final value = json[key];

  if (value == null) {
    return null;
  }

  if (value is! num) {
    throw FormatException('"$key" must be a number.');
  }

  return value.toDouble();
}

Map<String, dynamic> _requiredMap(Map<String, dynamic> json, String key) {
  final value = json[key];

  if (value is! Map<String, dynamic>) {
    throw FormatException('"$key" must be an object.');
  }

  return value;
}

DateTime _parseUtcTimestamp(Map<String, dynamic> json, String key) {
  final rawValue = _requiredString(json, key);
  final value = DateTime.tryParse(rawValue);

  if (value == null || !value.isUtc) {
    throw FormatException(
      '"$key" must be an ISO-8601 UTC timestamp ending in Z.',
    );
  }

  return value;
}

String _formatUtc(DateTime value) => value.toUtc().toIso8601String();

void _requireNonEmpty(String value, String fieldName) {
  if (value.trim().isEmpty) {
    throw FormatException('"$fieldName" must not be empty.');
  }
}
