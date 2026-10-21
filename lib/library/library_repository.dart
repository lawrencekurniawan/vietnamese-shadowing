import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'library_ids.dart';
import 'library_metadata.dart';
import 'library_storage.dart';
import 'wav_info.dart';

class LibraryItemExistsException implements Exception {
  const LibraryItemExistsException(this.itemId);

  final String itemId;

  @override
  String toString() => 'A library item with ID "$itemId" already exists.';
}

/// Durable local library backed by Application Support.
///
/// Library audio is copied into the item directory and never references the
/// temporary TTS cache.
class LibraryRepository {
  LibraryRepository({required Directory applicationSupportDirectory})
    : this._(applicationSupportDirectory);

  LibraryRepository._(this._applicationSupportDirectory);

  static Future<LibraryRepository> open({
    required Directory applicationSupportDirectory,
  }) async {
    final repository = LibraryRepository(
      applicationSupportDirectory: applicationSupportDirectory,
    );
    await repository.initialize();
    return repository;
  }

  final Directory _applicationSupportDirectory;

  Directory get rootDirectory => Directory(
    '${_applicationSupportDirectory.path}/${LibraryStorage.libraryDirectory}',
  );

  Future<void> initialize() async {
    await rootDirectory.create(recursive: true);
  }

  Future<List<LibraryItemMetadata>> list() async {
    await initialize();

    final items = <LibraryItemMetadata>[];

    await for (final entity in rootDirectory.list(followLinks: false)) {
      if (entity is! Directory) {
        continue;
      }

      final name = entity.path.split(Platform.pathSeparator).last;

      if (!isValidLibraryItemId(name)) {
        continue;
      }

      try {
        final metadata = await read(name);

        if (metadata != null) {
          items.add(metadata);
        }
      } on FormatException {
        // A single corrupt item must not make the rest of the library
        // unusable. It remains on disk for explicit recovery/cleanup.
      } on FileSystemException {
        // The item may have disappeared while listing.
      }
    }

    items.sort((a, b) {
      final createdComparison = b.createdAtUtc.compareTo(a.createdAtUtc);

      if (createdComparison != 0) {
        return createdComparison;
      }

      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });

    return List<LibraryItemMetadata>.unmodifiable(items);
  }

  Future<LibraryItemMetadata?> read(String itemId) async {
    _requireItemId(itemId);

    final metadataFile = File(
      '${_itemDirectory(itemId).path}/${LibraryStorage.metadataFileName}',
    );

    if (!await metadataFile.exists()) {
      return null;
    }

    final decoded = jsonDecode(await metadataFile.readAsString());

    if (decoded is! Map) {
      throw const FormatException('Library metadata must be a JSON object.');
    }

    final metadata = LibraryItemMetadata.fromJson(
      decoded.cast<String, dynamic>(),
    );

    if (metadata.itemId != itemId) {
      throw const FormatException(
        'Library metadata item ID does not match its directory.',
      );
    }

    return metadata;
  }

  Future<LibraryItemMetadata> saveFromWavFile({
    required String title,
    required String originalText,
    required String normalizedText,
    required VoiceMetadata voice,
    required String sourceWavPath,
    DateTime? createdAtUtc,
  }) async {
    final sourceFile = File(sourceWavPath);

    if (!await sourceFile.exists()) {
      throw StateError('Generated WAV file no longer exists: $sourceWavPath');
    }

    return saveAudioBytes(
      title: title,
      originalText: originalText,
      normalizedText: normalizedText,
      voice: voice,
      audioBytes: await sourceFile.readAsBytes(),
      createdAtUtc: createdAtUtc,
    );
  }

  /// Installs an audio payload atomically.
  ///
  /// When [itemId] is provided, an existing item is never overwritten. When it
  /// is omitted, a fresh local UUID is assigned.
  Future<LibraryItemMetadata> saveAudioBytes({
    required String title,
    required String originalText,
    required String normalizedText,
    required VoiceMetadata voice,
    required List<int> audioBytes,
    DateTime? createdAtUtc,
    String? itemId,
  }) async {
    await initialize();

    final trimmedTitle = title.trim();
    final trimmedOriginalText = originalText.trim();
    final trimmedNormalizedText = normalizedText.trim();

    if (trimmedTitle.isEmpty) {
      throw const FormatException('Library title must not be empty.');
    }

    if (trimmedOriginalText.isEmpty || trimmedNormalizedText.isEmpty) {
      throw const FormatException('Library text must not be empty.');
    }

    final wavInfo = WavInfo.parse(
      audioBytes is Uint8List ? audioBytes : Uint8List.fromList(audioBytes),
    );

    final resolvedItemId = itemId ?? await _newUniqueItemId();

    _requireItemId(resolvedItemId);

    if (await itemExists(resolvedItemId)) {
      throw LibraryItemExistsException(resolvedItemId);
    }

    final metadata = LibraryItemMetadata(
      itemId: resolvedItemId,
      title: trimmedTitle,
      originalText: trimmedOriginalText,
      normalizedText: trimmedNormalizedText,
      voice: voice,
      createdAtUtc: (createdAtUtc ?? DateTime.now()).toUtc(),
      audio: AudioMetadata(
        sampleRate: wavInfo.sampleRate,
        channels: wavInfo.channels,
        bitDepth: wavInfo.bitDepth,
        durationSeconds: wavInfo.durationSeconds,
      ),
    );

    final temporaryDirectory = Directory(
      '${rootDirectory.path}/.tmp-${generateLibraryItemId()}',
    );

    await temporaryDirectory.create(recursive: true);

    try {
      await File('${temporaryDirectory.path}/${LibraryStorage.audioFileName}')
          .writeAsBytes(audioBytes, flush: true);

      await File(
        '${temporaryDirectory.path}/${LibraryStorage.metadataFileName}',
      ).writeAsString(
        const JsonEncoder.withIndent('  ').convert(metadata.toJson()),
        flush: true,
      );

      final destination = _itemDirectory(resolvedItemId);

      if (await destination.exists()) {
        throw LibraryItemExistsException(resolvedItemId);
      }

      await temporaryDirectory.rename(destination.path);
    } on LibraryItemExistsException {
      await _deleteIfExists(temporaryDirectory);
      rethrow;
    } catch (_) {
      await _deleteIfExists(temporaryDirectory);
      rethrow;
    }

    return metadata;
  }

  Future<void> rename(String itemId, String title) async {
    final trimmedTitle = title.trim();

    if (trimmedTitle.isEmpty) {
      throw const FormatException('Library title must not be empty.');
    }

    final metadata = await read(itemId);

    if (metadata == null) {
      throw StateError('Library item not found: $itemId');
    }

    if (metadata.title == trimmedTitle) {
      return;
    }

    final updated = LibraryItemMetadata(
      itemId: metadata.itemId,
      title: trimmedTitle,
      originalText: metadata.originalText,
      normalizedText: metadata.normalizedText,
      voice: metadata.voice,
      createdAtUtc: metadata.createdAtUtc,
      audio: metadata.audio,
      audioFileName: metadata.audioFileName,
    );

    final itemDirectory = _itemDirectory(itemId);
    final temporaryMetadata = File(
      '${itemDirectory.path}/.metadata-${generateLibraryItemId()}.json',
    );

    try {
      await temporaryMetadata.writeAsString(
        const JsonEncoder.withIndent('  ').convert(updated.toJson()),
        flush: true,
      );
      await temporaryMetadata.rename(
        '${itemDirectory.path}/${LibraryStorage.metadataFileName}',
      );
    } catch (_) {
      await _deleteIfExists(temporaryMetadata);
      rethrow;
    }
  }

  Future<void> delete(String itemId) async {
    final directory = _itemDirectory(itemId);

    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  File audioFile(String itemId) {
    _requireItemId(itemId);

    return File(
      '${_itemDirectory(itemId).path}/${LibraryStorage.audioFileName}',
    );
  }

  Future<bool> itemExists(String itemId) async {
    _requireItemId(itemId);

    return _itemDirectory(itemId).exists();
  }

  Directory _itemDirectory(String itemId) {
    _requireItemId(itemId);

    return Directory('${rootDirectory.path}/$itemId');
  }

  Future<String> _newUniqueItemId() async {
    for (var attempt = 0; attempt < 8; attempt++) {
      final candidate = generateLibraryItemId();

      if (!await itemExists(candidate)) {
        return candidate;
      }
    }

    throw StateError('Could not allocate a unique library item ID.');
  }

  void _requireItemId(String itemId) {
    if (!isValidLibraryItemId(itemId)) {
      throw FormatException('Invalid library item ID: "$itemId".');
    }
  }

  Future<void> _deleteIfExists(FileSystemEntity entity) async {
    try {
      if (await entity.exists()) {
        await entity.delete(recursive: true);
      }
    } on FileSystemException {
      // Best-effort cleanup of a failed temporary install.
    }
  }
}
