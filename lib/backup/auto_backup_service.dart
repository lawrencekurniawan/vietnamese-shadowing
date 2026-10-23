// ignore_for_file: prefer_initializing_formals

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../library/library_metadata.dart';
import '../library/library_repository.dart';
import '../library/vshadow_backup.dart';
import '../practice/practice_repository.dart';
import '../practice/practice_take_metadata.dart';
import 'backup_folder_service.dart';

/// One rolling file is enough for automatic backups. Manual backups keep their
/// timestamped names and are never overwritten by this service.
const String vshadowAutoBackupFileName = 'vshadow-autobackup.vshadowbackup';

class AutoBackupResult {
  const AutoBackupResult({
    required this.fileName,
    required this.bytes,
    required this.writtenPath,
    required this.completedAtUtc,
  });

  final String fileName;
  final int bytes;
  final String writtenPath;
  final DateTime completedAtUtc;
}

/// Exports the current library/settings and copies the result into the folder
/// selected by the user.
class AutoBackupService {
  AutoBackupService({
    required LibraryRepository repository,
    PracticeRepository? practiceRepository,
    required BackupFolderService folderService,
    Future<Directory> Function()? temporaryDirectoryProvider,
  }) : _repository = repository,
       _practiceRepository = practiceRepository,
       _folderService = folderService,
       _temporaryDirectoryProvider =
           temporaryDirectoryProvider ?? getTemporaryDirectory;

  final LibraryRepository _repository;
  final PracticeRepository? _practiceRepository;
  final BackupFolderService _folderService;
  final Future<Directory> Function() _temporaryDirectoryProvider;

  Future<AutoBackupResult> run({
    required List<LibraryItemMetadata> items,
    required VshadowBackupSettings settings,
    List<PracticeTakeMetadata> takes = const <PracticeTakeMetadata>[],
    DateTime? completedAtUtc,
  }) async {
    final backupService = VshadowBackupService(
      repository: _repository,
      practiceRepository: _practiceRepository,
    );
    final backupBytes = await backupService.exportBackup(
      items: items,
      settings: settings,
      takes: takes,
    );
    final temporaryDirectory = await _temporaryDirectoryProvider();

    await temporaryDirectory.create(recursive: true);

    final sourceFile = File(
      '${temporaryDirectory.path}/$vshadowAutoBackupFileName',
    );

    try {
      await sourceFile.writeAsBytes(backupBytes, flush: true);

      final writtenPath = await _folderService.writeBackupFile(
        sourcePath: sourceFile.path,
        fileName: vshadowAutoBackupFileName,
      );

      return AutoBackupResult(
        fileName: vshadowAutoBackupFileName,
        bytes: backupBytes.length,
        writtenPath: writtenPath,
        completedAtUtc: (completedAtUtc ?? DateTime.now()).toUtc(),
      );
    } finally {
      try {
        if (await sourceFile.exists()) {
          await sourceFile.delete();
        }
      } on FileSystemException {
        // The temporary directory is cleaned by the OS, so a failed cleanup
        // must not hide a successful backup.
      }
    }
  }
}
