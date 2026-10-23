import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// One timed subtitle cue after markup and speaker labels have been removed.
class SubtitleCue {
  const SubtitleCue({
    required this.startSeconds,
    required this.endSeconds,
    required this.text,
  });

  final double startSeconds;
  final double endSeconds;
  final String text;
}

/// A short, speakable exchange assembled from one or more adjacent cues.
class SubtitlePassage {
  const SubtitlePassage({
    required this.text,
    required this.startSeconds,
    required this.endSeconds,
    required this.score,
    required this.cueCount,
  });

  final String text;
  final double startSeconds;
  final double endSeconds;
  final double score;
  final int cueCount;
}

class SubtitleParseResult {
  const SubtitleParseResult({
    required this.format,
    required this.cues,
    required this.fileName,
  });

  final String format;
  final List<SubtitleCue> cues;
  final String fileName;
}

/// Parses SRT, WebVTT, SSA/ASS, and ZIP-wrapped subtitle downloads.
class SubtitleParser {
  const SubtitleParser();

  static final RegExp _srtTimingPattern = RegExp(
    r'(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})\s*-->\s*'
    r'(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})',
  );

  static final RegExp _htmlTagPattern = RegExp(r'<[^>]*>');
  static final RegExp _assTagPattern = RegExp(r'\{[^}]*\}');
  static final RegExp _parentheticalPattern = RegExp(r'\([^)]{0,30}\)');
  static final RegExp _urlPattern = RegExp(
    r'(https?://|www\.|@[a-z0-9._-]+\.[a-z]{2,})',
    caseSensitive: false,
  );
  static final RegExp _diacriticPattern = RegExp(
    r'[ăâđêôơưàáảãạằắẳẵặầấẩẫậèéẻẽẹềếểễệìíỉĩịòóỏõọồốổỗộờớởỡợùúủũụừứửữựỳýỷỹỵ]',
    caseSensitive: false,
  );

  SubtitleParseResult parse(Uint8List bytes, {String fileName = 'subtitles'}) {
    if (bytes.isEmpty) {
      throw const FormatException('Subtitle download is empty.');
    }

    var resolvedName = fileName;
    var payload = bytes;

    if (_looksLikeZip(bytes)) {
      final archive = ZipDecoder().decodeBytes(bytes);
      ArchiveFile? selected;

      for (final file in archive.files) {
        if (!file.isFile) {
          continue;
        }

        final lower = file.name.toLowerCase();

        if (lower.endsWith('.srt') ||
            lower.endsWith('.vtt') ||
            lower.endsWith('.ass') ||
            lower.endsWith('.ssa')) {
          selected = file;
          break;
        }
      }

      if (selected == null) {
        throw const FormatException(
          'The subtitle ZIP does not contain an SRT, VTT, ASS, or SSA file.',
        );
      }

      payload = selected.readBytes() ?? Uint8List(0);
      resolvedName = selected.name;
    }

    final text = _decodeSubtitleBytes(payload);
    final lower = resolvedName.toLowerCase();

    if (lower.endsWith('.ass') || lower.endsWith('.ssa')) {
      return SubtitleParseResult(
        format: 'ass',
        cues: _cleanCues(_parseAss(text)),
        fileName: resolvedName,
      );
    }

    if (lower.endsWith('.vtt') || text.contains('WEBVTT')) {
      return SubtitleParseResult(
        format: 'vtt',
        cues: _cleanCues(_parseTimedBlocks(text)),
        fileName: resolvedName,
      );
    }

    return SubtitleParseResult(
      format: 'srt',
      cues: _cleanCues(_parseTimedBlocks(text)),
      fileName: resolvedName,
    );
  }

  List<SubtitleCue> _cleanCues(List<SubtitleCue> cues) {
    final cleaned = <SubtitleCue>[];

    for (final cue in cues) {
      final text = _cleanCueText(cue.text, requireFullSentence: false);

      if (text == null) {
        continue;
      }

      cleaned.add(
        SubtitleCue(
          startSeconds: cue.startSeconds,
          endSeconds: cue.endSeconds,
          text: text,
        ),
      );
    }

    return List<SubtitleCue>.unmodifiable(cleaned);
  }

  /// Turns cues into short passages suitable for TTS and shadowing.
  List<SubtitlePassage> extractPassages(
    List<SubtitleCue> cues, {
    int limit = 40,
  }) {
    final cleaned = <SubtitleCue>[];

    for (final cue in cues) {
      final text = _cleanCueText(cue.text, requireFullSentence: false);

      if (text == null) {
        continue;
      }

      cleaned.add(
        SubtitleCue(
          startSeconds: cue.startSeconds,
          endSeconds: cue.endSeconds,
          text: text,
        ),
      );
    }

    final candidates = <SubtitlePassage>[];
    final seen = <String>{};

    for (var start = 0; start < cleaned.length; start++) {
      for (var count = 3; count >= 1; count--) {
        final end = start + count;

        if (end > cleaned.length) {
          continue;
        }

        final first = cleaned[start];
        final last = cleaned[end - 1];

        if (last.endSeconds - first.startSeconds > 22) {
          continue;
        }

        var gapIsTooLarge = false;

        for (var index = start + 1; index < end; index++) {
          final gap =
              cleaned[index].startSeconds - cleaned[index - 1].endSeconds;

          if (gap > 2.5) {
            gapIsTooLarge = true;
            break;
          }
        }

        if (gapIsTooLarge) {
          continue;
        }

        final text = cleaned
            .sublist(start, end)
            .map((cue) => cue.text.trim())
            .join(' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();

        if (!_isGoodPassage(text)) {
          continue;
        }

        final dedupKey = _dedupKey(text);

        if (!seen.add(dedupKey)) {
          continue;
        }

        final words = text.split(RegExp(r'\s+')).length;
        final lengthScore = 1.0 - ((words - 14).abs() / 30).clamp(0.0, 1.0);
        final windowBonus = count >= 2 ? 0.5 : 0.0;
        final score = lengthScore + windowBonus;

        candidates.add(
          SubtitlePassage(
            text: text,
            startSeconds: first.startSeconds,
            endSeconds: last.endSeconds,
            score: score,
            cueCount: count,
          ),
        );
      }
    }

    candidates.sort((a, b) => b.score.compareTo(a.score));

    return List<SubtitlePassage>.unmodifiable(
      candidates.take(limit).toList(growable: false),
    );
  }

  /// Cleans one cue and returns null when it is not natural spoken Vietnamese.
  String? cleanCueText(String raw) {
    return _cleanCueText(raw, requireFullSentence: true);
  }

  String? _cleanCueText(String raw, {required bool requireFullSentence}) {
    var text = raw
        .replaceAll('\uFEFF', ' ')
        .replaceAll(_htmlTagPattern, ' ')
        .replaceAll(_assTagPattern, ' ')
        .replaceAll(RegExp(r'\\[Nn]'), ' ')
        .replaceAll(RegExp(r'[♪♫]'), ' ')
        .replaceAll(_parentheticalPattern, ' ');

    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();

    if (text.startsWith('-') || text.startsWith('–') || text.startsWith('—')) {
      text = text.substring(1).trim();
    }

    final speakerMatch = RegExp(r'^([^:]{1,24}):\s*').firstMatch(text);

    if (speakerMatch != null) {
      final label = speakerMatch.group(1)!.trim();
      final first = label.isEmpty ? '' : label[0];
      final startsUppercase =
          first.isNotEmpty &&
          first == first.toUpperCase() &&
          first != first.toLowerCase();
      final singleWord = !RegExp(r'\s').hasMatch(label);
      final allCaps = label.isNotEmpty && label == label.toUpperCase();

      if (allCaps || (singleWord && startsUppercase)) {
        text = text.substring(speakerMatch.end).trim();
      }
    }

    if (text.isEmpty || _urlPattern.hasMatch(text)) {
      return null;
    }

    if (text.contains('[') ||
        text.contains(']') ||
        text.contains('{') ||
        text.contains('}') ||
        text.contains('>>') ||
        text.contains('<<')) {
      return null;
    }

    if (text.toUpperCase() == text && RegExp(r'[A-Z]').hasMatch(text)) {
      return null;
    }

    final words = text.split(RegExp(r'\s+')).where((word) {
      return word.replaceAll(RegExp(r'[^\w]', unicode: true), '').isNotEmpty;
    }).toList();

    if (words.length > 32) {
      return null;
    }

    if (requireFullSentence && words.length < 4) {
      return null;
    }

    if (text.length > 190 || (requireFullSentence && text.length < 18)) {
      return null;
    }

    final diacriticCount = _diacriticPattern.allMatches(text).length;

    // Individual cues may be very short interjections such as "Không." or
    // "Vâng." with only one tone mark. Keep those so adjacent cues can be
    // combined before the stricter passage filters run.
    if (diacriticCount < (requireFullSentence ? 2 : 1)) {
      return null;
    }

    final letters = RegExp(
      r'[A-Za-zÀ-ỹ]',
      unicode: true,
    ).allMatches(text).length;

    if (letters < text.length * 0.55) {
      return null;
    }

    return text;
  }

  List<SubtitleCue> _parseTimedBlocks(String text) {
    final normalized = text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll('\uFEFF', '');
    final cues = <SubtitleCue>[];

    for (final block in normalized.split(RegExp(r'\n{2,}'))) {
      final lines = block.split('\n');
      var timingLineIndex = -1;
      RegExpMatch? match;

      for (var index = 0; index < lines.length; index++) {
        final candidate = _srtTimingPattern.firstMatch(lines[index]);

        if (candidate != null) {
          timingLineIndex = index;
          match = candidate;
          break;
        }
      }

      if (match == null || timingLineIndex < 0) {
        continue;
      }

      final textLines = lines
          .sublist(timingLineIndex + 1)
          .join(' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();

      if (textLines.isEmpty) {
        continue;
      }

      cues.add(
        SubtitleCue(
          startSeconds: _timestampSeconds(match, 1),
          endSeconds: _timestampSeconds(match, 5),
          text: textLines,
        ),
      );
    }

    return cues;
  }

  List<SubtitleCue> _parseAss(String text) {
    final normalized = text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll('\uFEFF', '');
    final lines = normalized.split('\n');
    final cues = <SubtitleCue>[];
    var inEvents = false;
    var formatFields = <String>[];

    for (final line in lines) {
      final trimmed = line.trim();

      if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
        inEvents = trimmed.toLowerCase() == '[events]';
        continue;
      }

      if (!inEvents) {
        continue;
      }

      if (trimmed.toLowerCase().startsWith('format:')) {
        formatFields = trimmed
            .substring(trimmed.indexOf(':') + 1)
            .split(',')
            .map((field) => field.trim().toLowerCase())
            .toList();
        continue;
      }

      if (!trimmed.toLowerCase().startsWith('dialogue:')) {
        continue;
      }

      if (formatFields.isEmpty) {
        continue;
      }

      final payload = trimmed.substring(trimmed.indexOf(':') + 1).trim();
      final parts = payload.split(',');

      if (parts.length < formatFields.length) {
        continue;
      }

      final textIndex = formatFields.indexOf('text');

      if (textIndex < 0) {
        continue;
      }

      final startIndex = formatFields.indexOf('start');
      final endIndex = formatFields.indexOf('end');

      if (startIndex < 0 || endIndex < 0) {
        continue;
      }

      final start = _parseAssTimestamp(parts[startIndex].trim());
      final end = _parseAssTimestamp(parts[endIndex].trim());
      final content = parts.sublist(textIndex).join(',').trim();

      if (start == null || end == null || content.isEmpty) {
        continue;
      }

      cues.add(
        SubtitleCue(startSeconds: start, endSeconds: end, text: content),
      );
    }

    return cues;
  }

  double _timestampSeconds(RegExpMatch match, int startGroup) {
    final hours = int.parse(match.group(startGroup)!);
    final minutes = int.parse(match.group(startGroup + 1)!);
    final seconds = int.parse(match.group(startGroup + 2)!);
    final fractionRaw = match.group(startGroup + 3)!;
    final milliseconds = fractionRaw.length == 3
        ? int.parse(fractionRaw)
        : int.parse(fractionRaw.padRight(3, '0'));

    return hours * 3600 + minutes * 60 + seconds + milliseconds / 1000.0;
  }

  double? _parseAssTimestamp(String value) {
    final match = RegExp(r'^(\d{1,2}):(\d{2}):(\d{2})[.](\d{1,3})$')
        .firstMatch(value);

    if (match == null) {
      return null;
    }

    return _timestampSeconds(match, 1);
  }

  String _decodeSubtitleBytes(Uint8List bytes) {
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return _decodeUtf16(bytes.sublist(2), littleEndian: true);
    }

    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return _decodeUtf16(bytes.sublist(2), littleEndian: false);
    }

    try {
      return utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      return latin1.decode(bytes);
    }
  }

  String _decodeUtf16(Uint8List bytes, {required bool littleEndian}) {
    final codeUnits = <int>[];

    for (var offset = 0; offset + 1 < bytes.length; offset += 2) {
      final value = littleEndian
          ? bytes[offset] | (bytes[offset + 1] << 8)
          : (bytes[offset] << 8) | bytes[offset + 1];
      codeUnits.add(value);
    }

    return String.fromCharCodes(codeUnits);
  }

  bool _looksLikeZip(Uint8List bytes) {
    return bytes.length >= 4 &&
        bytes[0] == 0x50 &&
        bytes[1] == 0x4B &&
        bytes[2] == 0x03 &&
        bytes[3] == 0x04;
  }

  bool _isGoodPassage(String text) {
    if (text.length < 20 || text.length > 220) {
      return false;
    }

    final words = text.split(RegExp(r'\s+')).length;

    if (words < 5 || words > 38) {
      return false;
    }

    if (_diacriticPattern.allMatches(text).length < 2) {
      return false;
    }

    if (_urlPattern.hasMatch(text)) {
      return false;
    }

    return true;
  }

  String _dedupKey(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'[.,!?;:…"“”‘’\-–—]'), '')
        .trim();
  }
}
