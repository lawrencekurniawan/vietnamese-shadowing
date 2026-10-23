import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class ConversationHttpResponse {
  const ConversationHttpResponse({
    required this.statusCode,
    required this.bodyBytes,
    this.headers = const <String, String>{},
  });

  final int statusCode;
  final Uint8List bodyBytes;
  final Map<String, String> headers;

  String get body => utf8.decode(bodyBytes, allowMalformed: true);
}

class ConversationHttpException implements Exception {
  const ConversationHttpException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Injectable HTTP surface so the OpenSubtitles client can be tested without
/// network access.
abstract interface class ConversationHttpClient {
  Future<ConversationHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
  });

  Future<ConversationHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    String? body,
  });
}

class IoConversationHttpClient implements ConversationHttpClient {
  IoConversationHttpClient({
    this.connectionTimeout = const Duration(seconds: 20),
    this.requestTimeout = const Duration(seconds: 45),
    this.maxResponseBytes = 12 * 1024 * 1024,
  });

  final Duration connectionTimeout;
  final Duration requestTimeout;
  final int maxResponseBytes;

  @override
  Future<ConversationHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
  }) {
    return _send('GET', uri, headers: headers);
  }

  @override
  Future<ConversationHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    String? body,
  }) {
    return _send('POST', uri, headers: headers, body: body);
  }

  Future<ConversationHttpResponse> _send(
    String method,
    Uri uri, {
    required Map<String, String> headers,
    String? body,
  }) async {
    final client = HttpClient()..connectionTimeout = connectionTimeout;

    try {
      final request = await client.openUrl(method, uri).timeout(requestTimeout);
      request.followRedirects = true;
      request.maxRedirects = 5;

      headers.forEach(request.headers.set);

      if (body != null) {
        final bytes = Uint8List.fromList(utf8.encode(body));
        request.headers.contentType = ContentType.json;
        request.contentLength = bytes.length;
        request.add(bytes);
      }

      final response = await request.close().timeout(requestTimeout);
      final builder = BytesBuilder(copy: false);

      await for (final chunk in response.timeout(requestTimeout)) {
        builder.add(chunk);

        if (builder.length > maxResponseBytes) {
          throw const ConversationHttpException(
            'The server response was too large.',
          );
        }
      }

      final responseHeaders = <String, String>{};

      response.headers.forEach((name, values) {
        responseHeaders[name.toLowerCase()] = values.join(', ');
      });

      return ConversationHttpResponse(
        statusCode: response.statusCode,
        bodyBytes: builder.takeBytes(),
        headers: responseHeaders,
      );
    } on TimeoutException {
      throw const ConversationHttpException(
        'The online text service timed out. Check your connection.',
      );
    } on SocketException catch (error) {
      throw ConversationHttpException(
        'Could not reach the online text service: ${error.message}',
      );
    } on HandshakeException {
      throw const ConversationHttpException(
        'Could not establish a secure connection to the online text service.',
      );
    } finally {
      client.close(force: true);
    }
  }
}
