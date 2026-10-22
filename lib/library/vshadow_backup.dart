import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../voices/voice_identity.dart';
import 'library_metadata.dart';
import 'library_repository.dart';
import 'vshadow_package.dart';

/// File extension for a full-library Vietnamese Shadowing backup.
const String vshadowBackupFileExtension = '.vshadowbackup';

const String vshadowBackupManifestEntry = 'backup.json';
const String vshadowBackupItemsDirectory = 'items';
const int vshadowBackupSchemaVersion = 1;

/// A backup is capped separately from a single `.vshadow` package because it
/// can contain many items. The limit is intentionally conservative so restore
/// remains safe on phones.
const int maxVshadowBackupBytes = 512 * 1024 * 1024;
const int maxVshadowBackupManifestBytes = 2 * 1024 * 1024;
const int maxVshadowBackupItems = 500;

const Set<int> _allowedRepeatCounts = <int>{1, 2, 3, 5, 10};
final Set<double> _allowedPaddingSeconds = <double>{
  0.0,
  0.25,
  0.5,
  0.75,
  1.0,
  1.5,
  2.0,
};

/// Settings that travel with a full-library backup.
class VshadowBackupSettings {
  const VshadowBackupSettings({
    this.defaultVoiceStableId,
    this.defaultVoicePresetName,
    this.playbackSpeed = 1.0,
    this.repeatCount = 1,
    this.paddingSeconds = 0.5,
    this.pauseUsesAudioLength = false,
  });

  factory VshadowBackupSettings.fromJson(Map<String, dynamic> json) {
    final settings = VshadowBackupSettings(
      defaultVoiceStableId: _optionalString(json, 'default_voice_stable_id'),
      defaultVoicePresetName: _optionalString(
        json,
        'default_voice_preset_name',
      ),
      playbackSpeed: _requiredDouble(json, 'playback_speed'),
      repeatCount: _requiredInt(json, 'repeat_count'),
      paddingSeconds: _requiredDouble(json, 'padding_seconds'),
      pauseUsesAudioLength: _requiredBool(json, 'pause_uses_audio_length'),
    );

    settings.validate();
    return settings;
  }

  final String? defaultVoiceStableId;
  final String? defaultVoicePresetName;
  final double playbackSpeed;
  final int repeatCount;
  final double paddingSeconds;
  final bool pauseUsesAudioLength;

  Map<String, dynamic> toJson() {
    validate();

    return <String, dynamic>{
      if (defaultVoiceStableId != null)
        'default_voice_stable_id': defaultVoiceStableId,
      if (defaultVoicePresetName != null)
        'default_voice_preset_name': defaultVoicePresetName,
      'playback_speed': playbackSpeed,
      'repeat_count': repeatCount,
      'padding_seconds': paddingSeconds,
      'pause_uses_audio_length': pauseUsesAudioLength,
    };
  }

  void validate() {
    if (!playbackSpeed.isFinite || playbackSpeed < 0.5 || playbackSpeed > 2.0) {
      throw FormatException(
        'Backup playback speed must be between 0.5 and 2.0.',
      );
    }

    if (!_allowedRepeatCounts.contains(repeatCount)) {
      throw FormatException('Unsupported backup repeat count: $repeatCount.');
    }

    if (!paddingSeconds.isFinite ||
        !_allowedPaddingSeconds.contains(paddingSeconds)) {
      throw FormatException(
        'Unsupported backup pause duration: $paddingSeconds.',
      );
    }

    final stableId = defaultVoiceStableId;
    final presetName = defaultVoicePresetName;

    if ((stableId == null) != (presetName == null)) {
      throw const FormatException(
        'Backup voice preference must include both a stable ID and preset name.',
      );
    }

    if (stableId != null && presetName != null) {
      final identity = VoiceIdentity.tryFromStableId(stableId);

      if (identity == null) {
        throw FormatException('Unknown backup voice stable ID: "$stableId".');
      }

      if (identity.presetName != presetName) {
        throw FormatException(
          'Backup voice preset "$presetName" does not match stable ID '
          '"$stableId".',
        );
      }
    }
  }
}

class VshadowBackupManifest {
  const VshadowBackupManifest({
    this.schemaVersion = vshadowBackupSchemaVersion,
    required this.createdAtUtc,
    required this.settings,
    required this.itemIds,
  });

  factory VshadowBackupManifest.fromJson(Map<String, dynamic> json) {
    final schemaVersion = _requiredInt(json, 'schema_version');

    if (schemaVersion != vshadowBackupSchemaVersion) {
      throw FormatException(
        'Unsupported backup schema version: $schemaVersion.',
      );
    }

    final createdAtUtc = _parseUtcTimestamp(json, 'created_at_utc');
    final settings = VshadowBackupSettings.fromJson(
      _requiredMap(json, 'settings'),
    );
    final rawItemIds = json['items'];

    if (rawItemIds is! List) {
      throw const FormatException('"items" must be an array.');
    }

    if (rawItemIds.length > maxVshadowBackupItems) {
      throw FormatException(
        'Backup must contain at most $maxVshadowBackupItems items.',
      );
    }

    final itemIds = <String>[];

    for (final rawItemId in rawItemIds) {
      if (rawItemId is! String || !isValidLibraryItemId(rawItemId)) {
        throw const FormatException(
          'Backup item IDs must be lowercase UUID v4 values.',
        );
      }

      itemIds.add(rawItemId);
    }

    if (itemIds.toSet().length != itemIds.length) {
      throw const FormatException('Duplicate backup item IDs are not allowed.');
    }

    final manifest = VshadowBackupManifest(
      schemaVersion: schemaVersion,
      createdAtUtc: createdAtUtc,
      settings: settings,
      itemIds: List<String>.unmodifiable(itemIds),
    );

    manifest.validate();
    return manifest;
  }

  final int schemaVersion;
  final DateTime createdAtUtc;
  final VshadowBackupSettings settings;
  final List<String> itemIds;

  Map<String, dynamic> toJson() {
    validate();

    return <String, dynamic>{
      'schema_version': schemaVersion,
      'created_at_utc': _formatUtc(createdAtUtc),
      'settings': settings.toJson(),
      'items': itemIds,
    };
  }

  void validate() {
    if (schemaVersion != vshadowBackupSchemaVersion) {
      throw FormatException(
        'Unsupported backup schema version: $schemaVersion.',
      );
    }

    if (!createdAtUtc.isUtc) {
      throw const FormatException('Backup created_at_utc must be in UTC.');
    }

    if (itemIds.length > maxVshadowBackupItems) {
      throw FormatException(
        'Backup must contain at most $maxVshadowBackupItems items.',
      );
    }

    if (itemIds.toSet().length != itemIds.length) {
      throw const FormatException('Duplicate backup item IDs are not allowed.');
    }

    for (final itemId in itemIds) {
      if (!isValidLibraryItemId(itemId)) {
        throw const FormatException(
          'Backup item IDs must be lowercase UUID v4 values.',
        );
      }
    }

    settings.validate();
  }
}

class VshadowBackupItem {
  const VshadowBackupItem({
    required this.itemId,
    required this.metadata,
    required this.audioBytes,
  });

  final String itemId;
  final VshadowMetadata metadata;
  final Uint8List audioBytes;
}

class VshadowBackupData {
  const VshadowBackupData({required this.manifest, required this.items});

  final VshadowBackupManifest manifest;
  final List<VshadowBackupItem> items;
}

class VshadowBackupRestoreResult {
  const VshadowBackupRestoreResult({
    required this.importedCount,
    required this.skippedCount,
    required this.manifest,
  });

  final int importedCount;
  final int skippedCount;
  final VshadowBackupManifest manifest;
}

/// Builds the suggested backup filename:
/// `vshadow-backup_<YYYY-MM-DD>_<HHmmss>.vshadowbackup`.
///
/// [exportedAt] is rendered in local time. [collisionIndex] is zero for the
/// base name; 1 produces `-2`, 2 produces `-3`, and so on.
String buildVshadowBackupFilename({
  DateTime? exportedAt,
  int collisionIndex = 0,
}) {
  if (collisionIndex < 0) {
    throw ArgumentError.value(
      collisionIndex,
      'collisionIndex',
      'must not be negative',
    );
  }

  final timestamp = (exportedAt ?? DateTime.now()).toLocal();
  final baseName =
      'vshadow-backup_${_formatDate(timestamp)}_${_formatTime(timestamp)}'
      '$vshadowBackupFileExtension';

  if (collisionIndex == 0) {
    return baseName;
  }

  final stem = baseName.substring(
    0,
    baseName.length - vshadowBackupFileExtension.length,
  );

  return '$stem-${collisionIndex + 1}$vshadowBackupFileExtension';
}

/// Strictly decodes a full-library backup before any restore occurs.
VshadowBackupData decodeVshadowBackup(
  Uint8List backupBytes, {
  int maxBackupBytes = maxVshadowBackupBytes,
  int maxManifestBytes = maxVshadowBackupManifestBytes,
  int maxItems = maxVshadowBackupItems,
}) {
  if (backupBytes.isEmpty || backupBytes.length > maxBackupBytes) {
    throw FormatException(
      'Backup must be between 1 and $maxBackupBytes bytes.',
    );
  }

  final decoder = ZipDecoder();
  final Archive archive;

  try {
    archive = decoder.decodeBytes(backupBytes);
  } on ArchiveException catch (error) {
    throw FormatException('Invalid backup archive: $error');
  } on RangeError catch (error) {
    throw FormatException('Invalid backup archive: $error');
  }

  final headers = decoder.directory.fileHeaders;

  if (headers.isEmpty) {
    throw const FormatException('Backup archive is empty.');
  }

  final names = headers.map((header) => header.filename).toList();

  if (names.toSet().length != names.length) {
    throw const FormatException(
      'Duplicate backup entry names are not allowed.',
    );
  }

  for (final name in names) {
    _validateBackupEntryName(name);
  }

  final manifestHeader = headers
      .where((header) => header.filename == vshadowBackupManifestEntry)
      .firstOrNull;

  if (manifestHeader == null) {
    throw const FormatException('Backup is missing backup.json.');
  }

  if (manifestHeader.uncompressedSize > maxManifestBytes) {
    throw FormatException(
      'Backup manifest must not exceed $maxManifestBytes bytes.',
    );
  }

  final manifestEntry = archive.find(vshadowBackupManifestEntry);

  if (manifestEntry == null ||
      !manifestEntry.isFile ||
      manifestEntry.isSymbolicLink) {
    throw const FormatException('Backup manifest must be a regular file.');
  }

  final manifestBytes = manifestEntry.readBytes();

  if (manifestBytes == null ||
      manifestBytes.length > maxManifestBytes ||
      manifestBytes.length != manifestEntry.size) {
    throw FormatException(
      'Backup manifest must be at most $maxManifestBytes bytes.',
    );
  }

  final dynamic decodedManifest;

  try {
    decodedManifest = jsonDecode(utf8.decode(manifestBytes));
  } on FormatException catch (error) {
    throw FormatException('Invalid backup manifest JSON: $error');
  }

  if (decodedManifest is! Map) {
    throw const FormatException('Backup manifest must be a JSON object.');
  }

  final manifest = VshadowBackupManifest.fromJson(
    decodedManifest.cast<String, dynamic>(),
  );

  if (manifest.itemIds.length > maxItems) {
    throw FormatException('Backup must contain at most $maxItems items.');
  }

  final expectedNames = <String>{vshadowBackupManifestEntry};

  for (final itemId in manifest.itemIds) {
    expectedNames.add(_metadataEntry(itemId));
    expectedNames.add(_audioEntry(itemId));
  }

  if (names.length != expectedNames.length) {
    throw const FormatException(
      'Backup contains unexpected entries or is missing item files.',
    );
  }

  for (final name in names) {
    if (!expectedNames.contains(name)) {
      throw FormatException('Unexpected backup entry: "$name".');
    }
  }

  final items = <VshadowBackupItem>[];
  var totalAudioBytes = 0;

  for (final itemId in manifest.itemIds) {
    final metadataName = _metadataEntry(itemId);
    final audioName = _audioEntry(itemId);
    final metadataHeader = headers
        .where((header) => header.filename == metadataName)
        .firstOrNull;
    final audioHeader = headers
        .where((header) => header.filename == audioName)
        .firstOrNull;

    if (metadataHeader == null || audioHeader == null) {
      throw FormatException('Backup item "$itemId" is missing files.');
    }

    if (metadataHeader.uncompressedSize > maxVshadowMetadataBytes) {
      throw FormatException(
        'Backup metadata must not exceed $maxVshadowMetadataBytes bytes.',
      );
    }

    if (audioHeader.uncompressedSize <= 0 ||
        audioHeader.uncompressedSize > maxVshadowPackageBytes) {
      throw FormatException(
        'Backup audio must be between 1 and $maxVshadowPackageBytes bytes.',
      );
    }

    final metadataEntry = archive.find(metadataName);
    final audioEntry = archive.find(audioName);

    if (metadataEntry == null ||
        audioEntry == null ||
        !metadataEntry.isFile ||
        !audioEntry.isFile ||
        metadataEntry.isSymbolicLink ||
        audioEntry.isSymbolicLink) {
      throw FormatException(
        'Backup item "$itemId" entries must be regular files.',
      );
    }

    final metadataBytes = metadataEntry.readBytes();
    final audioBytes = audioEntry.readBytes();

    if (metadataBytes == null ||
        metadataBytes.length > maxVshadowMetadataBytes ||
        metadataBytes.length != metadataEntry.size) {
      throw FormatException(
        'Backup metadata must be at most $maxVshadowMetadataBytes bytes.',
      );
    }

    if (audioBytes == null ||
        audioBytes.isEmpty ||
        audioBytes.length > maxVshadowPackageBytes ||
        audioBytes.length != audioEntry.size) {
      throw FormatException(
        'Backup audio must be between 1 and $maxVshadowPackageBytes bytes.',
      );
    }

    totalAudioBytes += audioBytes.length;

    if (totalAudioBytes > maxBackupBytes) {
      throw FormatException(
        'Backup audio must not exceed $maxBackupBytes bytes in total.',
      );
    }

    final dynamic decodedMetadata;

    try {
      decodedMetadata = jsonDecode(utf8.decode(metadataBytes));
    } on FormatException catch (error) {
      throw FormatException(
        'Invalid backup item metadata JSON for "$itemId": $error',
      );
    }

    if (decodedMetadata is! Map) {
      throw FormatException(
        'Backup item metadata for "$itemId" must be a JSON object.',
      );
    }

    final package = validateVshadowPayload(
      metadataJson: decodedMetadata.cast<String, dynamic>(),
      audioBytes: audioBytes,
    );

    items.add(
      VshadowBackupItem(
        itemId: itemId,
        metadata: package.metadata,
        audioBytes: package.audioBytes,
      ),
    );
  }

  return VshadowBackupData(
    manifest: manifest,
    items: List<VshadowBackupItem>.unmodifiable(items),
  );
}

class VshadowBackupService {
  factory VshadowBackupService({required LibraryRepository repository}) {
    return VshadowBackupService._(repository);
  }

  VshadowBackupService._(this._repository);

  final LibraryRepository _repository;

  /// Exports every item in [items] and the supplied playback/voice settings.
  ///
  /// All item audio and metadata are validated while the backup is built.
  Future<Uint8List> exportBackup({
    required List<LibraryItemMetadata> items,
    required VshadowBackupSettings settings,
    DateTime? createdAtUtc,
  }) async {
    if (items.length > maxVshadowBackupItems) {
      throw FormatException(
        'Backup must contain at most $maxVshadowBackupItems items.',
      );
    }

    settings.validate();

    final itemIds = <String>[];
    final archive = Archive();
    var totalAudioBytes = 0;

    for (final item in items) {
      final audioFile = _repository.audioFile(item.itemId);

      if (!await audioFile.exists()) {
        throw StateError('Library audio is missing: ${audioFile.path}');
      }

      final audioBytes = await audioFile.readAsBytes();

      if (audioBytes.isEmpty || audioBytes.length > maxVshadowPackageBytes) {
        throw FormatException(
          'Library audio must be between 1 and '
          '$maxVshadowPackageBytes bytes.',
        );
      }

      totalAudioBytes += audioBytes.length;

      if (totalAudioBytes > maxVshadowBackupBytes) {
        throw FormatException(
          'Backup audio must not exceed $maxVshadowBackupBytes bytes in total.',
        );
      }

      final metadata = buildVshadowMetadata(item: item, audioBytes: audioBytes);
      final metadataJson = jsonEncode(metadata.toJson());
      final metadataBytes = utf8.encode(metadataJson);

      if (metadataBytes.length > maxVshadowMetadataBytes) {
        throw FormatException(
          'Backup metadata must not exceed $maxVshadowMetadataBytes bytes.',
        );
      }

      itemIds.add(item.itemId);
      archive
        ..add(ArchiveFile.string(_metadataEntry(item.itemId), metadataJson))
        ..add(ArchiveFile.bytes(_audioEntry(item.itemId), audioBytes));
    }

    final manifest = VshadowBackupManifest(
      createdAtUtc: (createdAtUtc ?? DateTime.now()).toUtc(),
      settings: settings,
      itemIds: List<String>.unmodifiable(itemIds),
    );

    archive.add(
      ArchiveFile.string(
        vshadowBackupManifestEntry,
        jsonEncode(manifest.toJson()),
      ),
    );

    final backupBytes = ZipEncoder().encodeBytes(archive);

    if (backupBytes.isEmpty || backupBytes.length > maxVshadowBackupBytes) {
      throw FormatException(
        'Backup must be between 1 and $maxVshadowBackupBytes bytes.',
      );
    }

    return backupBytes;
  }

  /// Restores a validated backup without overwriting local items.
  ///
  /// Backup item IDs are preserved so retrying an interrupted restore is
  /// idempotent. Items whose IDs already exist are counted as skipped.
  Future<VshadowBackupRestoreResult> importBackup(Uint8List backupBytes) async {
    final backup = decodeVshadowBackup(backupBytes);
    var importedCount = 0;
    var skippedCount = 0;

    for (final item in backup.items) {
      try {
        await _repository.saveAudioBytes(
          title: item.metadata.title,
          originalText: item.metadata.originalText,
          normalizedText: item.metadata.normalizedText,
          voice: item.metadata.voice,
          audioBytes: item.audioBytes,
          createdAtUtc: item.metadata.createdAtUtc,
          itemId: item.itemId,
        );
        importedCount++;
      } on LibraryItemExistsException {
        skippedCount++;
      } catch (error) {
        throw StateError(
          'Restore stopped after $importedCount of ${backup.items.length} '
          'items: $error',
        );
      }
    }

    return VshadowBackupRestoreResult(
      importedCount: importedCount,
      skippedCount: skippedCount,
      manifest: backup.manifest,
    );
  }
}

String _metadataEntry(String itemId) =>
    '$vshadowBackupItemsDirectory/$itemId/metadata.json';

String _audioEntry(String itemId) =>
    '$vshadowBackupItemsDirectory/$itemId/audio.wav';

void _validateBackupEntryName(String name) {
  if (name.isEmpty ||
      name.startsWith('/') ||
      name.startsWith(r'\') ||
      name.contains('../') ||
      name.contains(r'..\') ||
      name.contains(r'\') ||
      name.contains('\u0000') ||
      name.contains(':')) {
    throw FormatException('Unsafe backup entry name: "$name".');
  }

  if (name == '.' || name == '..') {
    throw FormatException('Unsafe backup entry name: "$name".');
  }
}

String? _optionalString(Map<String, dynamic> json, String key) {
  final value = json[key];

  if (value == null) {
    return null;
  }

  if (value is! String) {
    throw FormatException('"$key" must be a string.');
  }

  if (value.trim().isEmpty) {
    throw FormatException('"$key" must not be empty.');
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

double _requiredDouble(Map<String, dynamic> json, String key) {
  final value = json[key];

  if (value is! num) {
    throw FormatException('"$key" must be a number.');
  }

  return value.toDouble();
}

bool _requiredBool(Map<String, dynamic> json, String key) {
  final value = json[key];

  if (value is! bool) {
    throw FormatException('"$key" must be a boolean.');
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

String _formatDate(DateTime value) {
  final year = value.year.toString().padLeft(4, '0');
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');

  return '$year-$month-$day';
}

String _formatTime(DateTime value) {
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  final second = value.second.toString().padLeft(2, '0');

  return '$hour$minute$second';
}
