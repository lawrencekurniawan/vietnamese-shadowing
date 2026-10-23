import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vietnamese_shadowing/backup/backup_folder_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(PlatformBackupFolderService.channelName);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('chooses a folder and parses its name and path', () async {
    final calls = <MethodCall>[];

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return <String, String>{
            'name': 'VShadow Backups',
            'path': '/private/backups',
          };
        });

    final service = PlatformBackupFolderService();
    final folder = await service.chooseFolder();

    expect(calls.single.method, 'chooseFolder');
    expect(folder?.name, 'VShadow Backups');
    expect(folder?.path, '/private/backups');
  });

  test('returns null when no folder has been selected', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);

    final service = PlatformBackupFolderService();

    expect(await service.getFolder(), isNull);
  });

  test('writes a backup file through the native channel', () async {
    MethodCall? receivedCall;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          receivedCall = call;
          return '/private/backups/vshadow-autobackup.vshadowbackup';
        });

    final service = PlatformBackupFolderService();
    final result = await service.writeBackupFile(
      sourcePath: '/tmp/source.vshadowbackup',
      fileName: 'vshadow-autobackup.vshadowbackup',
    );

    expect(receivedCall?.method, 'writeBackupFile');
    expect(receivedCall?.arguments, <String, dynamic>{
      'sourcePath': '/tmp/source.vshadowbackup',
      'fileName': 'vshadow-autobackup.vshadowbackup',
    });
    expect(result, '/private/backups/vshadow-autobackup.vshadowbackup');
  });

  test('clears the stored folder', () async {
    MethodCall? receivedCall;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          receivedCall = call;
          return null;
        });

    final service = PlatformBackupFolderService();
    await service.clearFolder();

    expect(receivedCall?.method, 'clearFolder');
  });

  test('rejects malformed folder responses', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return <String, String>{'name': '', 'path': ''};
        });

    final service = PlatformBackupFolderService();

    await expectLater(service.getFolder(), throwsFormatException);
  });
}
