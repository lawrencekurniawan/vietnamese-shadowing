import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vietnamese_shadowing/conversation/conversation_http_client.dart';
import 'package:vietnamese_shadowing/conversation/subdl_source.dart';

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

  @override
  Future<ConversationHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
  }) async {
    if (fail) {
      throw const ConversationHttpException('network unavailable');
    }

    requests.add(uri);

    if (uri.host == 'api.subdl.com') {
      return ConversationHttpResponse(
        statusCode: 200,
        bodyBytes: Uint8List.fromList(
          utf8.encode(
            jsonEncode(<String, dynamic>{
              'status': true,
              'subtitles': <Map<String, dynamic>>[
                <String, dynamic>{
                  'release_name': 'Inception.2010.1080p',
                  'name': 'Inception.vi.zip',
                  'lang': 'vietnamese',
                  'author': 'A Translator',
                  'url': '/subtitle/42.zip',
                  'downloads': 2300,
                  'rating': 8.1,
                  'hi': false,
                },
                <String, dynamic>{
                  'release_name': 'AI translation',
                  'name': 'ai.zip',
                  'url': '/subtitle/99.zip',
                  'downloads': 99999,
                  'ai_translated': true,
                },
                <String, dynamic>{
                  'release_name': 'Hearing impaired',
                  'name': 'hi.zip',
                  'url': '/subtitle/100.zip',
                  'downloads': 99998,
                  'hi': true,
                },
              ],
            }),
          ),
        ),
      );
    }

    if (uri.host == 'dl.subdl.com') {
      final archive = Archive()
        ..add(ArchiveFile.string('Inception.vi.srt', _srt));
      return ConversationHttpResponse(
        statusCode: 200,
        bodyBytes: ZipEncoder().encodeBytes(archive),
      );
    }

    throw StateError('Unexpected GET $uri');
  }

  @override
  Future<ConversationHttpResponse> post(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    String? body,
  }) {
    throw StateError('SubDL should not POST');
  }
}

void main() {
  test('searches by film, filters, downloads, and caches', () async {
    final directory = await Directory.systemTemp.createTemp('vshadow-subdl-');
    addTearDown(() => directory.delete(recursive: true));

    final client = _FakeHttpClient();
    final source = SubDLSource(
      httpClient: client,
      cacheDirectory: directory,
      starterTitles: const <String>['Inception'],
    );

    final result = await source.fetchLines(
      apiKey: 'test-key',
      filmName: 'Inception',
      forceRefresh: true,
    );

    expect(result.lines, isNotEmpty);
    expect(result.query, 'Inception');
    expect(result.lines.first.sourceTitle, 'Inception');
    expect(result.lines.first.sourceDetail, contains('SubDL'));
    expect(result.lines.first.sourceDetail, contains('2.3K downloads'));
    expect(result.lines.first.sourceDetail, contains('A Translator'));

    final searchUri = client.requests.firstWhere(
      (uri) => uri.host == 'api.subdl.com',
    );
    expect(searchUri.host, 'api.subdl.com');
    expect(searchUri.queryParameters['api_key'], 'test-key');
    expect(searchUri.queryParameters['film_name'], 'Inception');
    expect(searchUri.queryParameters['languages'], 'vi');
    expect(searchUri.queryParameters['type'], 'movie');
    expect(searchUri.queryParameters['hi'], '0');

    final cachedSource = SubDLSource(
      httpClient: _FakeHttpClient(fail: true),
      cacheDirectory: directory,
      starterTitles: const <String>['Inception'],
    );
    final cached = await cachedSource.fetchLines(
      apiKey: 'test-key',
      filmName: 'Inception',
    );

    expect(cached.fromCache, isTrue);
    expect(cached.lines, hasLength(result.lines.length));
  });

  test('picks a starter title when no film is supplied', () async {
    final client = _FakeHttpClient();
    final source = SubDLSource(
      httpClient: client,
      starterTitles: const <String>['Inception'],
    );

    final result = await source.fetchLines(
      apiKey: 'test-key',
      forceRefresh: true,
    );

    expect(result.query, 'Inception');
  });
}
