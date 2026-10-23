// ignore_for_file: prefer_initializing_formals

import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'conversation_http_client.dart';
import 'conversation_line.dart';
import 'subdl_movie_titles.dart';
import 'subtitle_parser.dart';

class SubDLException implements Exception {
  const SubDLException(this.message);

  final String message;

  @override
  String toString() => message;
}

class SubDLFetchResult {
  const SubDLFetchResult({
    required this.lines,
    required this.query,
    required this.fromCache,
    this.fetchedAtUtc,
    this.remainingDownloads,
  });

  final List<ConversationLine> lines;
  final String query;
  final bool fromCache;
  final DateTime? fetchedAtUtc;
  final int? remainingDownloads;
}

class _SubDLCandidate {
  const _SubDLCandidate({
    required this.id,
    required this.releaseName,
    required this.fileName,
    required this.downloadUrl,
    required this.downloadCount,
    required this.rating,
    required this.author,
    required this.hearingImpaired,
    required this.aiTranslated,
  });

  final String id;
  final String releaseName;
  final String fileName;
  final String downloadUrl;
  final int downloadCount;
  final double? rating;
  final String? author;
  final bool hearingImpaired;
  final bool aiTranslated;
}

/// SubDL is an alternate online source for when OpenSubtitles is blocked or
/// its daily download quota is exhausted.
///
/// SubDL searches by film name, so the caller supplies a title. When none is
/// supplied, one of the curated starter titles is picked at random.
class SubDLSource {
  SubDLSource({
    ConversationHttpClient? httpClient,
    SubtitleParser? parser,
    Directory? cacheDirectory,
    List<String> starterTitles = subdlStarterMovieTitles,
    this.cacheMaxAge = const Duration(days: 7),
  }) : _httpClient = httpClient ?? IoConversationHttpClient(),
       _parser = parser ?? const SubtitleParser(),
       _cacheDirectory = cacheDirectory,
       _starterTitles = List<String>.unmodifiable(starterTitles);

  static const String _downloadBase = 'https://dl.subdl.com';
  static const String _cacheFileName = 'subdl_cache.json';
  static const String _userAgent =
      'VietnameseShadowing/1.0 (personal language practice)';

  final ConversationHttpClient _httpClient;
  final SubtitleParser _parser;
  final Directory? _cacheDirectory;
  final List<String> _starterTitles;
  final Duration cacheMaxAge;

  Future<SubDLFetchResult> fetchLines({
    required String apiKey,
    String? filmName,
    int maxSubtitles = 1,
    bool forceRefresh = false,
  }) async {
    final trimmedKey = apiKey.trim();

    if (trimmedKey.isEmpty) {
      throw const SubDLException('Add your SubDL API key first.');
    }

    final query = _resolveQuery(filmName);

    if (!forceRefresh) {
      final cached = await readCachedLines(query: query, allowStale: false);

      if (cached != null && cached.lines.isNotEmpty) {
        return cached;
      }
    }

    final search = await _search(trimmedKey, query);

    if (search.candidates.isEmpty) {
      throw SubDLException(
        'SubDL returned no Vietnamese subtitles for "$query". '
        'Try another film name.',
      );
    }

    final requested = maxSubtitles.clamp(1, 3);
    final lines = <ConversationLine>[];
    int? remaining = search.remainingDownloads;

    for (final candidate in search.candidates.take(requested)) {
      final bytes = await _download(candidate);
      final parsed = _parser.parse(
        bytes,
        fileName: candidate.fileName.isEmpty
            ? 'subdl-subtitle.zip'
            : candidate.fileName,
      );
      final passages = _parser.extractPassages(parsed.cues);

      for (var index = 0; index < passages.length; index++) {
        final passage = passages[index];
        lines.add(
          ConversationLine(
            id: 'subdl-${candidate.id}-$index',
            displayText: passage.text,
            sourceTitle: query,
            sourceDetail: _sourceDetail(candidate),
            rating: candidate.rating,
            downloadCount: candidate.downloadCount,
            isOnline: true,
          ),
        );
      }
    }

    if (lines.isEmpty) {
      throw SubDLException(
        'No clean conversational Vietnamese lines were found for "$query". '
        'Try another film or import a subtitle file.',
      );
    }

    final result = SubDLFetchResult(
      lines: List<ConversationLine>.unmodifiable(lines),
      query: query,
      fromCache: false,
      fetchedAtUtc: DateTime.now().toUtc(),
      remainingDownloads: remaining,
    );

    await _writeCache(result);
    return result;
  }

  Future<SubDLFetchResult?> readCachedLines({
    required String query,
    bool allowStale = false,
  }) async {
    final directory = _cacheDirectory;

    if (directory == null) {
      return null;
    }

    final file = File('${directory.path}/$_cacheFileName');

    if (!await file.exists()) {
      return null;
    }

    try {
      final decoded = jsonDecode(await file.readAsString());

      if (decoded is! Map) {
        return null;
      }

      final map = decoded.cast<String, dynamic>();
      final cachedQuery = map['query'];
      final fetchedAtRaw = map['fetched_at_utc'];
      final fetchedAt = fetchedAtRaw is String
          ? DateTime.tryParse(fetchedAtRaw)
          : null;

      if (cachedQuery is! String ||
          cachedQuery.toLowerCase() != query.toLowerCase() ||
          fetchedAt == null ||
          !fetchedAt.isUtc) {
        return null;
      }

      if (!allowStale &&
          DateTime.now().toUtc().difference(fetchedAt) > cacheMaxAge) {
        return null;
      }

      final rawLines = map['lines'];

      if (rawLines is! List) {
        return null;
      }

      final lines = <ConversationLine>[];

      for (final raw in rawLines) {
        if (raw is! Map) {
          continue;
        }

        try {
          lines.add(ConversationLine.fromJson(raw.cast<String, dynamic>()));
        } on FormatException {
          // Ignore one corrupt cached line.
        }
      }

      if (lines.isEmpty) {
        return null;
      }

      return SubDLFetchResult(
        lines: List<ConversationLine>.unmodifiable(lines),
        query: cachedQuery,
        fromCache: true,
        fetchedAtUtc: fetchedAt,
        remainingDownloads: map['remaining_downloads'] is int
            ? map['remaining_downloads'] as int
            : null,
      );
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<_SubDLSearchResult> _search(String apiKey, String query) async {
    final parameters = SplayTreeMap<String, String>.from(<String, String>{
      'api_key': apiKey,
      'film_name': query,
      'hi': '0',
      'languages': 'vi',
      'subs_per_page': '30',
      'type': 'movie',
    });
    final uri = Uri.https('api.subdl.com', '/api/v1/subtitles', parameters);
    final response = await _httpClient.get(
      uri,
      headers: <String, String>{
        'Accept': 'application/json',
        'User-Agent': _userAgent,
      },
    );

    if (response.statusCode != 200) {
      throw SubDLException(_statusMessage(response));
    }

    final decoded = _decodeJson(response);

    if (decoded == null) {
      throw const SubDLException(
        'SubDL returned an unreadable search response.',
      );
    }

    if (decoded['status'] == false) {
      final message = decoded['error'];
      throw SubDLException(
        message is String && message.trim().isNotEmpty
            ? message.trim()
            : 'SubDL rejected the search request.',
      );
    }

    final rawSubtitles = decoded['subtitles'];

    if (rawSubtitles is! List) {
      return _SubDLSearchResult(
        candidates: const <_SubDLCandidate>[],
        remainingDownloads: _remainingFromJson(decoded),
      );
    }

    final candidates = <_SubDLCandidate>[];

    for (var index = 0; index < rawSubtitles.length; index++) {
      final raw = rawSubtitles[index];

      if (raw is! Map) {
        continue;
      }

      final item = raw.cast<String, dynamic>();
      final url = _firstString(<Object?>[item['download_link'], item['url']]);

      if (url == null) {
        continue;
      }

      final aiTranslated =
          item['ai_translated'] == true ||
          item['machine_translated'] == true ||
          item['ai_translation'] == true;
      final hearingImpaired =
          item['hi'] == true || item['hearing_impaired'] == true;

      if (aiTranslated || hearingImpaired) {
        continue;
      }

      candidates.add(
        _SubDLCandidate(
          id: _shortId(url, index),
          releaseName: _firstString(<Object?>[item['release_name']]) ?? query,
          fileName:
              _firstString(<Object?>[item['name'], item['file_name']]) ?? '',
          downloadUrl: _resolveDownloadUrl(url),
          downloadCount: item['downloads'] is num
              ? (item['downloads'] as num).toInt()
              : 0,
          rating: item['rating'] is num
              ? (item['rating'] as num).toDouble()
              : null,
          author: _firstString(<Object?>[item['author']]),
          hearingImpaired: hearingImpaired,
          aiTranslated: aiTranslated,
        ),
      );
    }

    candidates.sort((a, b) {
      final downloads = b.downloadCount.compareTo(a.downloadCount);

      if (downloads != 0) {
        return downloads;
      }

      final rating = (b.rating ?? 0).compareTo(a.rating ?? 0);

      if (rating != 0) {
        return rating;
      }

      return a.releaseName.compareTo(b.releaseName);
    });

    return _SubDLSearchResult(
      candidates: candidates,
      remainingDownloads: _remainingFromJson(decoded),
    );
  }

  Future<Uint8List> _download(_SubDLCandidate candidate) async {
    final response = await _httpClient.get(
      Uri.parse(candidate.downloadUrl),
      headers: <String, String>{'Accept': '*/*', 'User-Agent': _userAgent},
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SubDLException(
        'SubDL subtitle download failed (HTTP ${response.statusCode}).',
      );
    }

    return response.bodyBytes;
  }

  String _resolveQuery(String? filmName) {
    final trimmed = filmName?.trim();

    if (trimmed != null && trimmed.isNotEmpty) {
      return trimmed;
    }

    if (_starterTitles.isEmpty) {
      return 'Inception';
    }

    return _starterTitles[math.Random().nextInt(_starterTitles.length)];
  }

  String _resolveDownloadUrl(String url) {
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return url;
    }

    if (url.startsWith('//')) {
      return 'https:$url';
    }

    if (url.startsWith('/')) {
      return '$_downloadBase$url';
    }

    return '$_downloadBase/$url';
  }

  String _sourceDetail(_SubDLCandidate candidate) {
    final parts = <String>['SubDL'];

    if (candidate.downloadCount > 0) {
      parts.add('${_formatCount(candidate.downloadCount)} downloads');
    }

    if (candidate.rating != null && candidate.rating! > 0) {
      parts.add('${candidate.rating!.toStringAsFixed(1)}/10');
    }

    if (candidate.author != null) {
      parts.add('by ${candidate.author}');
    }

    parts.add(candidate.releaseName);
    return parts.join(' · ');
  }

  String _shortId(String url, int index) {
    final hash = url.hashCode.abs().toRadixString(16);
    return '$hash-$index';
  }

  String _formatCount(int value) {
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(1)}M';
    }

    if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(1)}K';
    }

    return '$value';
  }

  int? _remainingFromJson(Map<String, dynamic> decoded) {
    for (final key in <String>[
      'remaining',
      'downloads_remaining',
      'remaining_downloads',
    ]) {
      final value = decoded[key];

      if (value is num) {
        return value.toInt();
      }
    }

    return null;
  }

  Map<String, dynamic>? _decodeJson(ConversationHttpResponse response) {
    try {
      final decoded = jsonDecode(response.body);

      if (decoded is Map) {
        return decoded.cast<String, dynamic>();
      }
    } on FormatException {
      return null;
    }

    return null;
  }

  String _statusMessage(ConversationHttpResponse response) {
    final decoded = _decodeJson(response);
    final message = decoded?['error'] ?? decoded?['message'];

    if (message is String && message.trim().isNotEmpty) {
      return message.trim();
    }

    switch (response.statusCode) {
      case 401:
      case 403:
        return 'SubDL rejected the API key. Check your personal key.';
      case 429:
        return 'SubDL rate limit reached. Try again later.';
      default:
        return 'SubDL search failed (HTTP ${response.statusCode}).';
    }
  }

  Future<void> _writeCache(SubDLFetchResult result) async {
    final directory = _cacheDirectory;

    if (directory == null) {
      return;
    }

    try {
      await directory.create(recursive: true);
      final file = File('${directory.path}/$_cacheFileName');
      final payload = <String, dynamic>{
        'query': result.query,
        'fetched_at_utc': (result.fetchedAtUtc ?? DateTime.now().toUtc())
            .toIso8601String(),
        'remaining_downloads': result.remainingDownloads,
        'lines': result.lines.map((line) => line.toJson()).toList(),
      };
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(payload),
        flush: true,
      );
    } on FileSystemException {
      // The cache is an optimization; a failed write must not hide fresh lines.
    }
  }

  String? _firstString(List<Object?> values) {
    for (final value in values) {
      if (value is String && value.trim().isNotEmpty) {
        return value.trim();
      }
    }

    return null;
  }
}

class _SubDLSearchResult {
  const _SubDLSearchResult({
    required this.candidates,
    required this.remainingDownloads,
  });

  final List<_SubDLCandidate> candidates;
  final int? remainingDownloads;
}
