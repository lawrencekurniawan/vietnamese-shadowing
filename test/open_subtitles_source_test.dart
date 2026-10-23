import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vietnamese_shadowing/conversation/conversation_http_client.dart';
import 'package:vietnamese_shadowing/conversation/open_subtitles_source.dart';

const _srt = '''
1
00:00:01,000 --> 00:00:03,000
Chào bạn, hôm nay bạn có khỏe không?

2
00:00:03,100 --> 00:00:05,000
Mình khỏe, cảm ơn bạn rất nhiều.
''';

class _FakeHttpClient implements ConversationHttpClient {
  _FakeHttpClient({this.fail = false});

  final bool fail;
  final List<Uri> requests = <Uri>[];
  final List<String> bodies = <String>[];

  @override
  Future<ConversationHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
  }) async {
    if (fail) {
      throw const ConversationHttpException('network unavailable');
    }

    requests.add(uri);

    if (uri.host == 'api.opensubtitles.com') {
      return ConversationHttpResponse(
        statusCode: 200,
        bodyBytes: Uint8List.fromList(
          utf8.encode(
            jsonEncode(<String, dynamic>{
              'data': <Map<String, dynamic>>[
                <String, dynamic>{
                  'attributes': <String, dynamic>{
                    'ai_translated': false,
                    'machine_translated': false,
                    'foreign_parts_only': false,
                    'download_count': 12500,
                    'ratings': 8.2,
                    'from_trusted': true,
                    'hd': true,
                    'feature_details': <String, dynamic>{
                      'title': 'Inception',
                      'year': 2010,
                    },
                    'files': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'file_id': 42,
                        'file_name': 'Inception.vi.srt',
                        'cd_number': 1,
                      },
                    ],
                  },
                },
                <String, dynamic>{
                  'attributes': <String, dynamic>{
                    'ai_translated': true,
                    'download_count': 999999,
                    'files': <Map<String, dynamic>>[
                      <String, dynamic>{'file_id': 99, 'file_name': 'ai.srt'},
                    ],
                  },
                },
              ],
            }),
          ),
        ),
      );
    }

    if (uri.host == 'dl.example') {
      return ConversationHttpResponse(
        statusCode: 200,
        bodyBytes: Uint8List.fromList(utf8.encode(_srt)),
      );
    }

    throw StateError('Unexpected GET $uri');
  }

  @override
  Future<ConversationHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    String? body,
  }) async {
    if (fail) {
      throw const ConversationHttpException('network unavailable');
    }

    requests.add(uri);
    bodies.add(body ?? '');

    return ConversationHttpResponse(
      statusCode: 200,
      bodyBytes: Uint8List.fromList(
        utf8.encode(
          jsonEncode(<String, dynamic>{
            'link': 'https://dl.example/Inception.vi.srt',
            'file_name': 'Inception.vi.srt',
            'remaining': 4,
          }),
        ),
      ),
    );
  }
}

void main() {
  test('searches, filters, downloads, and caches one subtitle', () async {
    final directory = await Directory.systemTemp.createTemp(
      'vshadow-opensubtitles-',
    );
    addTearDown(() => directory.delete(recursive: true));

    final client = _FakeHttpClient();
    final source = OpenSubtitlesSource(
      httpClient: client,
      cacheDirectory: directory,
    );

    final result = await source.fetchLines(
      apiKey: 'test-key',
      forceRefresh: true,
    );

    expect(result.lines, isNotEmpty);
    expect(result.lines.first.sourceTitle, 'Inception (2010)');
    expect(result.lines.first.sourceDetail, contains('OpenSubtitles'));
    expect(result.lines.first.sourceDetail, contains('12.5K downloads'));
    expect(result.lines.first.isOnline, isTrue);
    expect(result.remainingDownloads, 4);

    final searchUri = client.requests.first;
    expect(searchUri.host, 'api.opensubtitles.com');
    expect(searchUri.queryParameters['languages'], 'vi');
    expect(searchUri.queryParameters['order_by'], 'download_count');
    expect(searchUri.queryParameters['order_direction'], 'desc');
    expect(searchUri.queryParameters['ai_translated'], 'exclude');
    expect(searchUri.queryParameters['machine_translated'], 'exclude');
    expect(searchUri.queryParameters['type'], 'movie');

    final downloadRequest = client.requests.firstWhere(
      (uri) =>
          uri.host == 'api.opensubtitles.com' && uri.path.endsWith('/download'),
    );
    expect(downloadRequest, isNotNull);
    expect(client.bodies.single, '{"file_id":42}');

    final cachedSource = OpenSubtitlesSource(
      httpClient: _FakeHttpClient(fail: true),
      cacheDirectory: directory,
    );
    final cached = await cachedSource.fetchLines(apiKey: 'test-key');

    expect(cached.fromCache, isTrue);
    expect(cached.lines, hasLength(result.lines.length));
  });

  test('maps a quota response to a useful error', () async {
    final client = _FakeHttpClient();
    final source = OpenSubtitlesSource(httpClient: _QuotaHttpClient(client));

    expect(
      () => source.fetchLines(apiKey: 'test-key', forceRefresh: true),
      throwsA(
        isA<OpenSubtitlesException>().having(
          (error) => error.message,
          'message',
          contains('quota'),
        ),
      ),
    );
  });
}

class _QuotaHttpClient implements ConversationHttpClient {
  _QuotaHttpClient(this.delegate);

  final _FakeHttpClient delegate;

  @override
  Future<ConversationHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
  }) {
    return delegate.get(uri, headers: headers);
  }

  @override
  Future<ConversationHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    String? body,
  }) async {
    return ConversationHttpResponse(
      statusCode: 429,
      bodyBytes: Uint8List.fromList(
        utf8.encode(jsonEncode(<String, dynamic>{'message': 'quota reached'})),
      ),
    );
  }
}
