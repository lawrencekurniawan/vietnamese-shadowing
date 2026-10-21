import 'library_metadata.dart';

/// Intended on-disk layout under Application Support.
///
/// `vieneu/tts-cache` is temporary and expires after seven days.
/// `vieneu/library/<uuid>/` is durable and must never point at a cache file.
class LibraryStorage {
  static const String rootDirectory = 'vieneu';
  static const String assetsDirectory = 'vieneu/assets';
  static const String ttsCacheDirectory = 'vieneu/tts-cache';
  static const String libraryDirectory = 'vieneu/library';

  static const String metadataFileName = libraryMetadataFileName;
  static const String audioFileName = libraryAudioFileName;

  /// Returns a safe relative item directory, or throws for an invalid local ID.
  static String itemDirectory(String itemId) {
    if (!isValidLibraryItemId(itemId)) {
      throw ArgumentError.value(itemId, 'itemId', 'must be a UUID v4');
    }

    return '$libraryDirectory/$itemId';
  }

  static String metadataPath(String itemId) =>
      '${itemDirectory(itemId)}/$metadataFileName';

  static String audioPath(String itemId) =>
      '${itemDirectory(itemId)}/$audioFileName';
}
