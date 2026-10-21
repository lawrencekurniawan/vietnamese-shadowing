import 'package:flutter/services.dart';

typedef DocumentOpenHandler = Future<void> Function(String path);

/// Receives `.vshadow` documents opened by the operating system.
///
/// Native code copies the opened document into a temporary location and queues
/// its path until Dart is ready. Dart drains the queue once at startup and then
/// receives later documents through `openDocument` method calls.
class DocumentOpenService {
  DocumentOpenService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'vietnamese_shadowing/documents';

  final MethodChannel _channel;

  DocumentOpenHandler? _handler;
  bool _listening = false;

  void setHandler(DocumentOpenHandler handler) {
    _handler = handler;

    if (_listening) {
      return;
    }

    _listening = true;
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  Future<String?> takePendingDocument() {
    return _channel.invokeMethod<String>('takePendingDocument');
  }

  void dispose() {
    _handler = null;

    if (_listening) {
      _listening = false;
      _channel.setMethodCallHandler(null);
    }
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method != 'openDocument' || call.arguments is! String) {
      return;
    }

    await _handler?.call(call.arguments as String);
  }
}
