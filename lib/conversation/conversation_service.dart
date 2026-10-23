// ignore_for_file: prefer_initializing_formals

import 'dart:convert';
import 'dart:typed_data';

import 'builtin_conversation_pack.dart';
import 'conversation_line.dart';
import 'open_subtitles_source.dart';
import 'subdl_source.dart';
import 'subtitle_parser.dart';

enum ConversationOnlineProvider { openSubtitles, subdl }

extension ConversationOnlineProviderDisplay on ConversationOnlineProvider {
  String get label {
    switch (this) {
      case ConversationOnlineProvider.openSubtitles:
        return 'OpenSubtitles';
      case ConversationOnlineProvider.subdl:
        return 'SubDL';
    }
  }

  String get preferenceKey {
    switch (this) {
      case ConversationOnlineProvider.openSubtitles:
        return 'vshadow_opensubtitles_api_key';
      case ConversationOnlineProvider.subdl:
        return 'vshadow_subdl_api_key';
    }
  }
}

class ConversationLoadResult {
  const ConversationLoadResult({
    required this.lines,
    required this.sourceLabel,
    required this.isOnline,
    this.isLocal = false,
    this.warning,
    this.fromCache = false,
    this.remainingDownloads,
  });

  final List<ConversationLine> lines;
  final String sourceLabel;
  final bool isOnline;
  final bool isLocal;
  final String? warning;
  final bool fromCache;
  final int? remainingDownloads;
}

class ConversationImportException implements Exception {
  const ConversationImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Coordinates online sources, local imports, and the offline fallback.
class ConversationService {
  ConversationService({
    OpenSubtitlesSource? openSubtitles,
    SubDLSource? subdl,
    SubtitleParser? subtitleParser,
    List<ConversationLine> builtinLines = builtinConversationLines,
  }) : _openSubtitles = openSubtitles,
       _subdl = subdl,
       _subtitleParser = subtitleParser ?? const SubtitleParser(),
       _builtinLines = List<ConversationLine>.unmodifiable(builtinLines);

  final OpenSubtitlesSource? _openSubtitles;
  final SubDLSource? _subdl;
  final SubtitleParser _subtitleParser;
  final List<ConversationLine> _builtinLines;

  List<ConversationLine> get builtinLines => _builtinLines;

  ConversationLoadResult loadBuiltin({String? note}) {
    return ConversationLoadResult(
      lines: _builtinLines,
      sourceLabel: 'Offline conversation pack',
      isOnline: false,
      warning: note,
    );
  }

  ConversationLoadResult loadLocalSubtitle({
    required String fileName,
    required Uint8List bytes,
  }) {
    if (bytes.isEmpty) {
      throw const ConversationImportException('The subtitle file is empty.');
    }

    final parsed = _subtitleParser.parse(bytes, fileName: fileName);
    final passages = _subtitleParser.extractPassages(parsed.cues);

    if (passages.isEmpty) {
      throw const ConversationImportException(
        'No clean conversational Vietnamese lines were found in that file. '
        'Try a subtitle with accented Vietnamese dialogue.',
      );
    }

    final title = _localSourceTitle(fileName);
    final lines = <ConversationLine>[];

    for (var index = 0; index < passages.length; index++) {
      final passage = passages[index];
      lines.add(
        ConversationLine(
          id: 'local-$index-${_shortHash(fileName, passage.text)}',
          displayText: passage.text,
          sourceTitle: title,
          sourceDetail: 'Imported subtitle · local file · personal study',
          isOnline: false,
        ),
      );
    }

    return ConversationLoadResult(
      lines: List<ConversationLine>.unmodifiable(lines),
      sourceLabel: 'Imported subtitle',
      isOnline: false,
      isLocal: true,
      warning:
          'Imported ${lines.length} line(s) from $fileName. '
          'The file stays on this device.',
    );
  }

  Future<ConversationLoadResult> loadOnline({
    ConversationOnlineProvider provider =
        ConversationOnlineProvider.openSubtitles,
    required String apiKey,
    String? filmName,
    bool forceRefresh = false,
  }) async {
    if (provider == ConversationOnlineProvider.openSubtitles) {
      return _loadOpenSubtitles(apiKey: apiKey, forceRefresh: forceRefresh);
    }

    return _loadSubDL(
      apiKey: apiKey,
      filmName: filmName,
      forceRefresh: forceRefresh,
    );
  }

  Future<ConversationLoadResult> _loadOpenSubtitles({
    required String apiKey,
    required bool forceRefresh,
  }) async {
    final source = _openSubtitles;

    if (source == null) {
      return loadBuiltin(
        note:
            'OpenSubtitles is not configured. '
            'Import a subtitle file or use the offline pack.',
      );
    }

    if (apiKey.trim().isEmpty) {
      return loadBuiltin(
        note:
            'Add a personal OpenSubtitles API key to fetch high-download '
            'movie subtitle lines. The offline pack is ready to use now.',
      );
    }

    try {
      final result = await source.fetchLines(
        apiKey: apiKey,
        maxSubtitles: 1,
        forceRefresh: forceRefresh,
      );
      final cacheNote = result.fromCache
          ? 'Using cached OpenSubtitles lines. Use "Download new" for a fresh '
                'pick.'
          : 'Downloaded a high-download Vietnamese subtitle.';
      final quotaNote = result.remainingDownloads == null
          ? ''
          : ' ${result.remainingDownloads} downloads left today.';
      final sourceNote = result.sourceTitle == null
          ? ''
          : ' Source: ${result.sourceTitle}.';

      return ConversationLoadResult(
        lines: result.lines,
        sourceLabel: 'OpenSubtitles',
        isOnline: true,
        fromCache: result.fromCache,
        remainingDownloads: result.remainingDownloads,
        warning: '$cacheNote$sourceNote$quotaNote',
      );
    } catch (error) {
      final cached = await source.readCachedLines(allowStale: true);

      if (cached != null && cached.lines.isNotEmpty) {
        return ConversationLoadResult(
          lines: cached.lines,
          sourceLabel: 'OpenSubtitles · cached',
          isOnline: true,
          fromCache: true,
          remainingDownloads: cached.remainingDownloads,
          warning:
              'Live OpenSubtitles download failed: $error. '
              'Showing previously cached lines.',
        );
      }

      return loadBuiltin(
        note:
            'OpenSubtitles failed: $error. '
            'Import a subtitle file or use the offline pack instead.',
      );
    }
  }

  Future<ConversationLoadResult> _loadSubDL({
    required String apiKey,
    required String? filmName,
    required bool forceRefresh,
  }) async {
    final source = _subdl;

    if (source == null) {
      return loadBuiltin(
        note:
            'SubDL is not configured. Import a subtitle file or use the '
            'offline pack.',
      );
    }

    if (apiKey.trim().isEmpty) {
      return loadBuiltin(
        note:
            'Add a personal SubDL API key to search Vietnamese subtitles, '
            'or import a subtitle file.',
      );
    }

    final query = filmName?.trim();

    try {
      final result = await source.fetchLines(
        apiKey: apiKey,
        filmName: query,
        maxSubtitles: 1,
        forceRefresh: forceRefresh,
      );
      final cacheNote = result.fromCache
          ? 'Using cached SubDL lines for "${result.query}". '
                'Use "Download new" for a fresh pick.'
          : 'Downloaded a SubDL Vietnamese subtitle for "${result.query}".';
      final quotaNote = result.remainingDownloads == null
          ? ''
          : ' ${result.remainingDownloads} downloads left.';

      return ConversationLoadResult(
        lines: result.lines,
        sourceLabel: 'SubDL',
        isOnline: true,
        fromCache: result.fromCache,
        remainingDownloads: result.remainingDownloads,
        warning: '$cacheNote$quotaNote',
      );
    } catch (error) {
      final cached = query == null
          ? null
          : await source.readCachedLines(query: query, allowStale: true);

      if (cached != null && cached.lines.isNotEmpty) {
        return ConversationLoadResult(
          lines: cached.lines,
          sourceLabel: 'SubDL · cached',
          isOnline: true,
          fromCache: true,
          remainingDownloads: cached.remainingDownloads,
          warning:
              'Live SubDL download failed: $error. '
              'Showing previously cached lines for "${cached.query}".',
        );
      }

      return loadBuiltin(
        note:
            'SubDL failed: $error. '
            'Import a subtitle file or use the offline pack instead.',
      );
    }
  }

  String _localSourceTitle(String fileName) {
    var title = fileName;
    final slash = title.lastIndexOf(RegExp(r'[/\\]'));

    if (slash >= 0) {
      title = title.substring(slash + 1);
    }

    title = title.replaceFirst(
      RegExp(r'\.(srt|vtt|ass|ssa|zip)$', caseSensitive: false),
      '',
    );

    return title.trim().isEmpty ? 'Imported subtitle' : title.trim();
  }

  String _shortHash(String fileName, String text) {
    final bytes = utf8.encode('$fileName\n$text');
    var hash = 0x811C9DC5;

    for (final byte in bytes) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }

    return hash.toRadixString(16).padLeft(8, '0');
  }
}
