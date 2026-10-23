import 'package:flutter/services.dart';

/// A user-selected folder that can receive automatic backups.
class BackupFolderInfo {
  const BackupFolderInfo({required this.name, required this.path});

  factory BackupFolderInfo.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final path = json['path'];

    if (name is! String || name.trim().isEmpty) {
      throw const FormatException('Backup folder name is missing.');
    }

    if (path is! String || path.trim().isEmpty) {
      throw const FormatException('Backup folder path is missing.');
    }

    return BackupFolderInfo(name: name, path: path);
  }

  final String name;
  final String path;
}

/// Chooses and writes into a folder that the user granted access to.
///
/// On iOS the folder is persisted as a security-scoped bookmark so automatic
/// backups continue to work across launches, including folders in iCloud
/// Drive or third-party file providers exposed by Files.
abstract interface class BackupFolderService {
  Future<BackupFolderInfo?> chooseFolder();

  Future<BackupFolderInfo?> getFolder();

  Future<void> clearFolder();

  Future<String> writeBackupFile({
    required String sourcePath,
    required String fileName,
  });
}

class PlatformBackupFolderService implements BackupFolderService {
  PlatformBackupFolderService({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('vietnamese_shadowing/backup_folder');

  static const String channelName = 'vietnamese_shadowing/backup_folder';

  final MethodChannel _channel;

  @override
  Future<BackupFolderInfo?> chooseFolder() async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'chooseFolder',
    );

    if (result == null) {
      return null;
    }

    return BackupFolderInfo.fromJson(result.cast<String, dynamic>());
  }

  @override
  Future<BackupFolderInfo?> getFolder() async {
    final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'getFolder',
    );

    if (result == null) {
      return null;
    }

    return BackupFolderInfo.fromJson(result.cast<String, dynamic>());
  }

  @override
  Future<void> clearFolder() async {
    await _channel.invokeMethod<void>('clearFolder');
  }

  @override
  Future<String> writeBackupFile({
    required String sourcePath,
    required String fileName,
  }) async {
    final result = await _channel.invokeMethod<String>(
      'writeBackupFile',
      <String, dynamic>{'sourcePath': sourcePath, 'fileName': fileName},
    );

    if (result == null || result.isEmpty) {
      throw const FormatException('Backup folder did not return a file path.');
    }

    return result;
  }
}
