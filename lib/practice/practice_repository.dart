// ignore_for_file: prefer_initializing_formals

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../library/library_ids.dart';
import '../library/library_metadata.dart';
import 'practice_take_metadata.dart';

class PracticeTakeExistsException implements Exception {
  const PracticeTakeExistsException(this.takeId);

  final String takeId;

  @override
  String toString() => 'A practice take with ID "$takeId" already exists.';
}

/// Durable storage for recordings made in the Practice tab.
class PracticeRepository {
  PracticeRepository({required Directory applicationSupportDirectory})
    : _applicationSupportDirectory = applicationSupportDirectory;

  static const String directoryName = 'practice';

  static Future<PracticeRepository> open({
    required Directory applicationSupportDirectory,
  }) async {
    final repository = PracticeRepository(
      applicationSupportDirectory: applicationSupportDirectory,
    );
    await repository.initialize();
    return repository;
  }

  final Directory _applicationSupportDirectory;

  Directory get rootDirectory =>
      Directory('${_applicationSupportDirectory.path}/vieneu/$directoryName');

  Future<void> initialize() async {
    await rootDirectory.create(recursive: true);
  }

  Future<List<PracticeTakeMetadata>> list() async {
    await initialize();

    final takes = <PracticeTakeMetadata>[];

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
          takes.add(metadata);
        }
      } on FormatException {
        // One corrupt take must not hide the rest of the recordings.
      } on FileSystemException {
        // The take may have disappeared while listing.
      }
    }

    takes.sort((a, b) {
      final createdComparison = b.createdAtUtc.compareTo(a.createdAtUtc);

      if (createdComparison != 0) {
        return createdComparison;
      }

      return b.takeId.compareTo(a.takeId);
    });

    return List<PracticeTakeMetadata>.unmodifiable(takes);
  }

  Future<PracticeTakeMetadata?> read(String takeId) async {
    _requireTakeId(takeId);

    final metadataFile = File(
      '${_takeDirectory(takeId).path}/$practiceTakeMetadataFileName',
    );

    if (!await metadataFile.exists()) {
      return null;
    }

    final decoded = jsonDecode(await metadataFile.readAsString());

    if (decoded is! Map) {
      throw const FormatException(
        'Practice take metadata must be a JSON object.',
      );
    }

    final metadata = PracticeTakeMetadata.fromJson(
      decoded.cast<String, dynamic>(),
    );

    if (metadata.takeId != takeId) {
      throw const FormatException(
        'Practice take ID does not match its directory.',
      );
    }

    return metadata;
  }

  Future<PracticeTakeMetadata> saveFromWavFile({
    required String libraryItemId,
    required String itemTitle,
    required String sourceWavPath,
    String? takeId,
    DateTime? createdAtUtc,
  }) async {
    final sourceFile = File(sourceWavPath);

    if (!await sourceFile.exists()) {
      throw StateError('Practice recording no longer exists: $sourceWavPath');
    }

    return saveAudioBytes(
      libraryItemId: libraryItemId,
      itemTitle: itemTitle,
      audioBytes: await sourceFile.readAsBytes(),
      takeId: takeId,
      createdAtUtc: createdAtUtc,
    );
  }

  /// Installs a take atomically. Existing take IDs are never overwritten.
  Future<PracticeTakeMetadata> saveAudioBytes({
    required String libraryItemId,
    required String itemTitle,
    required List<int> audioBytes,
    String? takeId,
    DateTime? createdAtUtc,
  }) async {
    await initialize();

    if (!isValidLibraryItemId(libraryItemId)) {
      throw const FormatException('Invalid practice library item ID.');
    }

    final trimmedTitle = itemTitle.trim();

    if (trimmedTitle.isEmpty) {
      throw const FormatException('Practice item title must not be empty.');
    }

    final resolvedTakeId = takeId ?? generateLibraryItemId();

    _requireTakeId(resolvedTakeId);

    if (await takeExists(resolvedTakeId)) {
      throw PracticeTakeExistsException(resolvedTakeId);
    }

    final bytes = audioBytes is Uint8List
        ? audioBytes
        : Uint8List.fromList(audioBytes);

    final metadata = buildPracticeTakeMetadata(
      takeId: resolvedTakeId,
      libraryItemId: libraryItemId,
      itemTitle: trimmedTitle,
      audioBytes: bytes,
      createdAtUtc: createdAtUtc,
    );

    final temporaryDirectory = Directory(
      '${rootDirectory.path}/.tmp-${generateLibraryItemId()}',
    );

    await temporaryDirectory.create(recursive: true);

    try {
      await File('${temporaryDirectory.path}/$practiceTakeAudioFileName')
          .writeAsBytes(bytes, flush: true);

      await File('${temporaryDirectory.path}/$practiceTakeMetadataFileName')
          .writeAsString(
            const JsonEncoder.withIndent('  ').convert(metadata.toJson()),
            flush: true,
          );

      final destination = _takeDirectory(resolvedTakeId);

      if (await destination.exists()) {
        throw PracticeTakeExistsException(resolvedTakeId);
      }

      await temporaryDirectory.rename(destination.path);
    } on PracticeTakeExistsException {
      await _deleteIfExists(temporaryDirectory);
      rethrow;
    } catch (_) {
      await _deleteIfExists(temporaryDirectory);
      rethrow;
    }

    return metadata;
  }

  Future<void> delete(String takeId) async {
    final directory = _takeDirectory(takeId);

    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  File audioFile(String takeId) {
    _requireTakeId(takeId);

    return File('${_takeDirectory(takeId).path}/$practiceTakeAudioFileName');
  }

  Future<bool> takeExists(String takeId) async {
    _requireTakeId(takeId);

    return _takeDirectory(takeId).exists();
  }

  Directory _takeDirectory(String takeId) {
    _requireTakeId(takeId);

    return Directory('${rootDirectory.path}/$takeId');
  }

  void _requireTakeId(String takeId) {
    if (!isValidLibraryItemId(takeId)) {
      throw ArgumentError.value(takeId, 'takeId', 'must be a UUID v4');
    }
  }

  Future<void> _deleteIfExists(Directory directory) async {
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } on FileSystemException {
      // Best-effort cleanup only.
    }
  }
}
