// ignore_for_file: prefer_initializing_formals

import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'conversation_http_client.dart';
import 'conversation_line.dart';
import 'subtitle_parser.dart';

class OpenSubtitlesException implements Exception {
  const OpenSubtitlesException(this.message);

  final String message;

  @override
  String toString() => message;
}

class OpenSubtitlesFetchResult {
  const OpenSubtitlesFetchResult({
    required this.lines,
    required this.fromCache,
    this.remainingDownloads,
    this.fetchedAtUtc,
    this.sourceTitle,
  });

  final List<ConversationLine> lines;
  final bool fromCache;
  final int? remainingDownloads;
  final DateTime? fetchedAtUtc;
  final String? sourceTitle;
}

class _SubtitleCandidate {
  const _SubtitleCandidate({
    required this.fileId,
    required this.title,
    required this.year,
    required this.downloadCount,
    required this.rating,
    required this.trusted,
    required this.hd,
    required this.fileName,
  });

  final int fileId;
  final String title;
  final int? year;
  final int downloadCount;
  final double? rating;
  final bool trusted;
  final bool hd;
  final String? fileName;
}

/// Downloads high-download Vietnamese subtitles from OpenSubtitles and turns
/// short groups of adjacent cues into practice passages.
class OpenSubtitlesSource {
  OpenSubtitlesSource({
    ConversationHttpClient? httpClient,
    SubtitleParser? parser,
    Directory? cacheDirectory,
    this.cacheMaxAge = const Duration(days: 7),
    this.maxSearchResults = 30,
  }) : _httpClient = httpClient ?? IoConversationHttpClient(),
       _parser = parser ?? const SubtitleParser(),
       _cacheDirectory = cacheDirectory;

  static const String _baseUrl = 'https://api.opensubtitles.com/api/v1';
  static const String _userAgent =
      'VietnameseShadowing/1.0 (personal language practice)';
  static const String _cacheFileName = 'open_subtitles_cache.json';

  final ConversationHttpClient _httpClient;
  final SubtitleParser _parser;
  final Directory? _cacheDirectory;
  final Duration cacheMaxAge;
  final int maxSearchResults;

  Future<OpenSubtitlesFetchResult> fetchLines({
    required String apiKey,
    int maxSubtitles = 1,
    bool forceRefresh = false,
  }) async {
    final trimmedKey = apiKey.trim();

    if (trimmedKey.isEmpty) {
      throw const OpenSubtitlesException(
        'Add your personal OpenSubtitles API key first.',
      );
    }

    if (!forceRefresh) {
      final cached = await readCachedLines(allowStale: false);

      if (cached != null && cached.lines.isNotEmpty) {
        return cached;
      }
    }

    final candidates = await _search(trimmedKey);

    if (candidates.isEmpty) {
      throw const OpenSubtitlesException(
        'OpenSubtitles returned no high-download Vietnamese subtitles.',
      );
    }

    final requested = maxSubtitles.clamp(1, 3);
    final candidatesToTry = candidates.take(requested).toList(growable: false);
    final lines = <ConversationLine>[];
    final downloadedTitles = <String>[];
    int? remaining;

    for (final candidate in candidatesToTry) {
      final download = await _download(trimmedKey, candidate);
      remaining = download.remainingDownloads ?? remaining;
      downloadedTitles.add(candidate.title);

      final parsed = _parser.parse(
        download.bytes,
        fileName: download.fileName ?? candidate.fileName ?? 'subtitles.srt',
      );
      final passages = _parser.extractPassages(parsed.cues);

      for (var index = 0; index < passages.length; index++) {
        final passage = passages[index];
        lines.add(
          ConversationLine(
            id: 'opensubtitles-${candidate.fileId}-$index',
            displayText: passage.text,
            sourceTitle: _displayTitle(candidate),
            sourceDetail: _sourceDetail(candidate),
            rating: candidate.rating,
            downloadCount: candidate.downloadCount,
            isOnline: true,
          ),
        );
      }
    }

    if (lines.isEmpty) {
      throw const OpenSubtitlesException(
        'No clean conversational Vietnamese lines were found in the '
        'downloaded subtitle. Try another download or use the offline pack.',
      );
    }

    final result = OpenSubtitlesFetchResult(
      lines: List<ConversationLine>.unmodifiable(lines),
      fromCache: false,
      remainingDownloads: remaining,
      fetchedAtUtc: DateTime.now().toUtc(),
      sourceTitle: downloadedTitles.join(', '),
    );

    await _writeCache(result);
    return result;
  }

  /// Reads cached online lines. A stale cache is returned only when
  /// [allowStale] is true, which lets the UI fall back during an outage.
  Future<OpenSubtitlesFetchResult?> readCachedLines({
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
      final fetchedAtRaw = map['fetched_at_utc'];
      final fetchedAt = fetchedAtRaw is String
          ? DateTime.tryParse(fetchedAtRaw)
          : null;

      if (fetchedAt == null || !fetchedAt.isUtc) {
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

      return OpenSubtitlesFetchResult(
        lines: List<ConversationLine>.unmodifiable(lines),
        fromCache: true,
        remainingDownloads: map['remaining_downloads'] is int
            ? map['remaining_downloads'] as int
            : null,
        fetchedAtUtc: fetchedAt,
        sourceTitle: map['source_title'] is String
            ? map['source_title'] as String
            : null,
      );
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<List<_SubtitleCandidate>> _search(String apiKey) async {
    final parameters = SplayTreeMap<String, String>.from(<String, String>{
      'ai_translated': 'exclude',
      'languages': 'vi',
      'machine_translated': 'exclude',
      'order_by': 'download_count',
      'order_direction': 'desc',
      'page': '1',
      'per_page': '$maxSearchResults',
      'type': 'movie',
    });
    final uri = Uri.https(
      'api.opensubtitles.com',
      '/api/v1/subtitles',
      parameters,
    );
    final response = await _httpClient.get(uri, headers: _apiHeaders(apiKey));

    if (response.statusCode != 200) {
      throw OpenSubtitlesException(_statusMessage(response));
    }

    final decoded = _decodeJson(response);

    if (decoded == null) {
      throw const OpenSubtitlesException(
        'OpenSubtitles returned an unreadable search response.',
      );
    }

    final data = decoded['data'];

    if (data is! List) {
      return const <_SubtitleCandidate>[];
    }

    final candidates = <_SubtitleCandidate>[];

    for (final raw in data) {
      if (raw is! Map) {
        continue;
      }

      final item = raw.cast<String, dynamic>();
      final attributes = item['attributes'];

      if (attributes is! Map) {
        continue;
      }

      final attributesMap = attributes.cast<String, dynamic>();

      if (attributesMap['ai_translated'] == true ||
          attributesMap['machine_translated'] == true ||
          attributesMap['foreign_parts_only'] == true) {
        continue;
      }

      final feature = attributesMap['feature_details'];
      final featureMap = feature is Map
          ? feature.cast<String, dynamic>()
          : const <String, dynamic>{};
      final title = _firstString(<Object?>[
        featureMap['title'],
        featureMap['movie_name'],
        attributesMap['release'],
      ]);

      if (title == null) {
        continue;
      }

      final files = attributesMap['files'];

      if (files is! List || files.isEmpty) {
        continue;
      }

      int? fileId;
      String? fileName;

      for (final rawFile in files) {
        if (rawFile is! Map) {
          continue;
        }

        final file = rawFile.cast<String, dynamic>();

        if (file['file_id'] is num) {
          fileId = (file['file_id'] as num).toInt();
          fileName = file['file_name'] is String
              ? file['file_name'] as String
              : null;
        }

        if (file['cd_number'] == 1 && fileId != null) {
          break;
        }
      }

      if (fileId == null) {
        continue;
      }

      final downloadCount = attributesMap['download_count'] is num
          ? (attributesMap['download_count'] as num).toInt()
          : 0;
      final rating = attributesMap['ratings'] is num
          ? (attributesMap['ratings'] as num).toDouble()
          : null;
      final year = featureMap['year'] is num
          ? (featureMap['year'] as num).toInt()
          : null;

      candidates.add(
        _SubtitleCandidate(
          fileId: fileId,
          title: title,
          year: year,
          downloadCount: downloadCount,
          rating: rating,
          trusted: attributesMap['from_trusted'] == true,
          hd: attributesMap['hd'] == true,
          fileName: fileName,
        ),
      );
    }

    candidates.sort((a, b) {
      final aScore = _qualityScore(a);
      final bScore = _qualityScore(b);
      return bScore.compareTo(aScore);
    });

    return candidates;
  }

  Future<_DownloadResult> _download(
    String apiKey,
    _SubtitleCandidate candidate,
  ) async {
    final uri = Uri.parse('$_baseUrl/download');
    final response = await _httpClient.post(
      uri,
      headers: <String, String>{
        ..._apiHeaders(apiKey),
        'Content-Type': 'application/json',
      },
      body: jsonEncode(<String, dynamic>{'file_id': candidate.fileId}),
    );

    if (response.statusCode != 200) {
      throw OpenSubtitlesException(_downloadStatusMessage(response));
    }

    final decoded = _decodeJson(response);
    final link = decoded?['link'];

    if (link is! String || link.isEmpty) {
      throw const OpenSubtitlesException(
        'OpenSubtitles did not return a subtitle download link.',
      );
    }

    final remaining = decoded?['remaining'] is num
        ? (decoded!['remaining'] as num).toInt()
        : null;
    final fileName = decoded?['file_name'] is String
        ? decoded!['file_name'] as String
        : candidate.fileName;
    final downloadResponse = await _httpClient.get(
      Uri.parse(link),
      headers: <String, String>{'User-Agent': _userAgent, 'Accept': '*/*'},
    );

    if (downloadResponse.statusCode < 200 ||
        downloadResponse.statusCode >= 300) {
      throw OpenSubtitlesException(
        'Subtitle download failed (HTTP ${downloadResponse.statusCode}).',
      );
    }

    return _DownloadResult(
      bytes: downloadResponse.bodyBytes,
      fileName: fileName,
      remainingDownloads: remaining,
    );
  }

  Map<String, String> _apiHeaders(String apiKey) {
    return <String, String>{
      'Api-Key': apiKey,
      'User-Agent': _userAgent,
      'Accept': 'application/json',
    };
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
    final message = _errorMessage(response);

    switch (response.statusCode) {
      case 401:
        return 'OpenSubtitles rejected the API key. Check your personal key.';
      case 403:
        return 'OpenSubtitles denied access. Check your API key and quota.';
      case 406:
        return 'OpenSubtitles could not satisfy the search filters.';
      case 429:
        return 'OpenSubtitles rate limit reached. Try again later.';
      default:
        return message ??
            'OpenSubtitles search failed (HTTP ${response.statusCode}).';
    }
  }

  String _downloadStatusMessage(ConversationHttpResponse response) {
    final message = _errorMessage(response);

    switch (response.statusCode) {
      case 401:
        return 'OpenSubtitles rejected the API key. Check your personal key.';
      case 403:
        return 'OpenSubtitles denied the download. Check your API key and quota.';
      case 406:
        return 'OpenSubtitles could not download this subtitle.';
      case 429:
        return 'The OpenSubtitles download quota is used up for today. '
            'Use the offline pack or try again later.';
      default:
        return message ??
            'OpenSubtitles download failed (HTTP ${response.statusCode}).';
    }
  }

  String? _errorMessage(ConversationHttpResponse response) {
    final decoded = _decodeJson(response);
    final message = decoded?['message'];

    if (message is String && message.trim().isNotEmpty) {
      return message.trim();
    }

    return null;
  }

  Future<void> _writeCache(OpenSubtitlesFetchResult result) async {
    final directory = _cacheDirectory;

    if (directory == null) {
      return;
    }

    try {
      await directory.create(recursive: true);
      final file = File('${directory.path}/$_cacheFileName');
      final payload = <String, dynamic>{
        'fetched_at_utc': (result.fetchedAtUtc ?? DateTime.now().toUtc())
            .toIso8601String(),
        'remaining_downloads': result.remainingDownloads,
        'source_title': result.sourceTitle,
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

  double _qualityScore(_SubtitleCandidate candidate) {
    final downloads = candidate.downloadCount;
    final rating = candidate.rating ?? 0;
    return log(downloads + 1) * 2.2 +
        rating * 0.7 +
        (candidate.trusted ? 1.0 : 0.0) +
        (candidate.hd ? 0.2 : 0.0);
  }

  String _displayTitle(_SubtitleCandidate candidate) {
    final year = candidate.year;

    if (year == null) {
      return candidate.title;
    }

    return '${candidate.title} ($year)';
  }

  String _sourceDetail(_SubtitleCandidate candidate) {
    final parts = <String>[
      'OpenSubtitles',
      '${_formatCount(candidate.downloadCount)} downloads',
    ];

    if (candidate.rating != null && candidate.rating! > 0) {
      parts.add('${candidate.rating!.toStringAsFixed(1)}/10');
    }

    if (candidate.trusted) {
      parts.add('trusted uploader');
    }

    return parts.join(' · ');
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

  String? _firstString(List<Object?> values) {
    for (final value in values) {
      if (value is String && value.trim().isNotEmpty) {
        return value.trim();
      }
    }

    return null;
  }
}

class _DownloadResult {
  const _DownloadResult({
    required this.bytes,
    required this.fileName,
    required this.remainingDownloads,
  });

  final Uint8List bytes;
  final String? fileName;
  final int? remainingDownloads;
}
