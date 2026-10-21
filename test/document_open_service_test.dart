import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vietnamese_shadowing/documents/document_open_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/document-open');
  const codec = StandardMethodCodec();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('drains a document queued before Dart was ready', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'takePendingDocument');
          return '/tmp/pending.vshadow';
        });

    final service = DocumentOpenService(channel: channel);
    addTearDown(service.dispose);

    final received = <String>[];
    service.setHandler((path) async {
      received.add(path);
    });

    expect(await service.takePendingDocument(), '/tmp/pending.vshadow');
    expect(received, isEmpty);
  });

  test('delivers later documents through the method handler', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);

    final service = DocumentOpenService(channel: channel);
    addTearDown(service.dispose);

    final received = <String>[];
    service.setHandler((path) async {
      received.add(path);
    });

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          codec.encodeMethodCall(
            const MethodCall('openDocument', '/tmp/opened.vshadow'),
          ),
          (_) {},
        );

    expect(received, ['/tmp/opened.vshadow']);
  });

  test('ignores unknown methods and non-string arguments', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);

    final service = DocumentOpenService(channel: channel);
    addTearDown(service.dispose);

    final received = <String>[];
    service.setHandler((path) async {
      received.add(path);
    });

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          codec.encodeMethodCall(const MethodCall('openOther', '/tmp/file')),
          (_) {},
        );

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          codec.encodeMethodCall(
            const MethodCall('openDocument', <String, String>{
              'path': '/tmp/file.vshadow',
            }),
          ),
          (_) {},
        );

    expect(received, isEmpty);
  });
}
