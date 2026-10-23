import 'dart:math' as math;

import 'practice_feedback.dart';
import 'practice_speech_service.dart';
import 'vietnamese_tone.dart';

/// Best-effort, on-device analysis of one practice take.
///
/// The comparison is deliberately forgiving: word matching ignores tone marks,
/// while pitch contours are evaluated separately from the recorded audio.
/// Feedback is approximate and is not phoneme-level pronunciation scoring.
class PracticeAnalyzer {
  const PracticeAnalyzer();

  PracticeFeedback analyze({
    required String referenceText,
    required String referenceAudioPath,
    required String userAudioPath,
    required SpeechTranscript referenceTranscript,
    required SpeechTranscript userTranscript,
    required List<PitchFrame> referencePitch,
    required List<PitchFrame> userPitch,
    double? referenceDurationSeconds,
    double? userDurationSeconds,
  }) {
    final referenceTokens = _tokenize(referenceText);
    final userTimedTokens = _timedTokens(userTranscript);
    final alignment = _align(referenceTokens, userTimedTokens);
    final referenceTimings = _referenceTimings(
      referenceTokens,
      _timedTokens(referenceTranscript),
    );

    final unclearWords = <String>[];
    final extraWords = <String>[];

    for (final index in alignment.unmatchedReferenceIndexes) {
      unclearWords.add(referenceTokens[index].original);
    }

    for (final index in alignment.extraUserIndexes) {
      extraWords.add(userTimedTokens[index].token.original);
    }

    final pace = _paceFeedback(
      referenceTokens: referenceTokens,
      alignment: alignment,
      referenceTimings: referenceTimings,
      referencePitch: referencePitch,
      userPitch: userPitch,
      referenceDurationSeconds: referenceDurationSeconds,
      userDurationSeconds: userDurationSeconds,
    );
    final tone = _toneFeedback(
      referenceTokens: referenceTokens,
      alignment: alignment,
      referenceTimings: referenceTimings,
      referencePitch: referencePitch,
      userPitch: userPitch,
    );

    return PracticeFeedback(
      matchedWordCount: alignment.matches.length,
      totalWordCount: referenceTokens.length,
      unclearWords: List<String>.unmodifiable(unclearWords),
      extraWords: List<String>.unmodifiable(extraWords),
      paceRatio: pace.ratio,
      cadenceSummary: pace.summary,
      paceIssues: List<PaceIssue>.unmodifiable(pace.issues),
      toneIssues: List<ToneIssue>.unmodifiable(tone.issues),
      toneGuide: List<ToneGuideItem>.unmodifiable(tone.guide),
      toneCheckedCount: tone.checkedCount,
      toneMatchedCount: tone.matchedCount,
      referenceAudioPath: referenceAudioPath,
      userAudioPath: userAudioPath,
      referenceDurationSeconds: referenceDurationSeconds,
      userDurationSeconds: userDurationSeconds,
      note: userTranscript.usedOnDevice
          ? 'Feedback uses on-device Vietnamese speech recognition and '
                'approximate pitch analysis.'
          : 'Feedback uses best-effort speech recognition and approximate '
                'pitch analysis. Listen to the reference before retrying.',
    );
  }

  List<_TokenInfo> _tokenize(String text) {
    final tokens = <_TokenInfo>[];

    for (final raw in text.split(RegExp(r'\s+'))) {
      final cleaned = _cleanToken(raw);

      if (cleaned.isEmpty) {
        continue;
      }

      tokens.add(
        _TokenInfo(
          original: cleaned,
          folded: foldVietnamese(cleaned),
          tone: toneOf(cleaned),
        ),
      );
    }

    return tokens;
  }

  String _cleanToken(String raw) {
    const punctuation = '.,!?;:…"“”‘’()[]{}<>/\\|@#\$%^&*_+=~`';

    var value = raw;

    while (value.isNotEmpty && punctuation.contains(value[0])) {
      value = value.substring(1);
    }

    while (value.isNotEmpty && punctuation.contains(value[value.length - 1])) {
      value = value.substring(0, value.length - 1);
    }

    while (value.isNotEmpty &&
        (value.startsWith('-') ||
            value.startsWith('–') ||
            value.startsWith('—'))) {
      value = value.substring(1);
    }

    while (value.isNotEmpty &&
        (value.endsWith('-') || value.endsWith('–') || value.endsWith('—'))) {
      value = value.substring(0, value.length - 1);
    }

    return value.trim();
  }

  List<_TimedToken> _timedTokens(SpeechTranscript transcript) {
    final result = <_TimedToken>[];

    if (transcript.segments.isNotEmpty) {
      for (final segment in transcript.segments) {
        final tokens = _tokenize(segment.text);

        if (tokens.isEmpty) {
          continue;
        }

        final share = segment.durationSeconds / tokens.length;

        for (var index = 0; index < tokens.length; index++) {
          result.add(
            _TimedToken(
              token: tokens[index],
              startSeconds: segment.startSeconds + index * share,
              durationSeconds: share,
              confidence: segment.confidence,
            ),
          );
        }
      }

      return result;
    }

    for (final token in _tokenize(transcript.text)) {
      result.add(_TimedToken(token: token));
    }

    return result;
  }

  _Alignment _align(List<_TokenInfo> reference, List<_TimedToken> user) {
    final rows = reference.length + 1;
    final columns = user.length + 1;
    final cost = List<List<int>>.generate(
      rows,
      (_) => List<int>.filled(columns, 0),
    );

    for (var row = 0; row < rows; row++) {
      cost[row][0] = row;
    }

    for (var column = 0; column < columns; column++) {
      cost[0][column] = column;
    }

    for (var row = 1; row < rows; row++) {
      for (var column = 1; column < columns; column++) {
        final isMatch =
            reference[row - 1].folded == user[column - 1].token.folded;
        final diagonal = cost[row - 1][column - 1] + (isMatch ? 0 : 1);
        final deletion = cost[row - 1][column] + 1;
        final insertion = cost[row][column - 1] + 1;
        cost[row][column] = math.min(diagonal, math.min(deletion, insertion));
      }
    }

    final matches = <int, _TimedToken>{};
    final unmatchedReferenceIndexes = <int>[];
    final extraUserIndexes = <int>[];
    var row = reference.length;
    var column = user.length;

    while (row > 0 || column > 0) {
      if (row > 0 && column > 0) {
        final isMatch =
            reference[row - 1].folded == user[column - 1].token.folded;

        if (isMatch && cost[row][column] == cost[row - 1][column - 1]) {
          matches[row - 1] = user[column - 1];
          row--;
          column--;
          continue;
        }

        if (cost[row][column] == cost[row - 1][column - 1] + 1) {
          unmatchedReferenceIndexes.add(row - 1);
          row--;
          column--;
          continue;
        }
      }

      if (row > 0 && cost[row][column] == cost[row - 1][column] + 1) {
        unmatchedReferenceIndexes.add(row - 1);
        row--;
        continue;
      }

      if (column > 0) {
        extraUserIndexes.add(column - 1);
        column--;
        continue;
      }

      if (row > 0) {
        unmatchedReferenceIndexes.add(row - 1);
        row--;
      }
    }

    return _Alignment(
      matches: matches,
      unmatchedReferenceIndexes: unmatchedReferenceIndexes,
      extraUserIndexes: extraUserIndexes,
    );
  }

  Map<int, _TimedToken> _referenceTimings(
    List<_TokenInfo> reference,
    List<_TimedToken> timed,
  ) {
    if (timed.isEmpty) {
      return const <int, _TimedToken>{};
    }

    final alignment = _align(reference, timed);
    return alignment.matches;
  }

  _PaceResult _paceFeedback({
    required List<_TokenInfo> referenceTokens,
    required _Alignment alignment,
    required Map<int, _TimedToken> referenceTimings,
    required List<PitchFrame> referencePitch,
    required List<PitchFrame> userPitch,
    required double? referenceDurationSeconds,
    required double? userDurationSeconds,
  }) {
    final referenceVoiced = _voicedSpan(referencePitch);
    final userVoiced = _voicedSpan(userPitch);
    final referenceSpan = referenceVoiced ?? referenceDurationSeconds;
    final userSpan = userVoiced ?? userDurationSeconds;
    double? ratio;

    if (referenceSpan != null &&
        userSpan != null &&
        referenceSpan > 0.2 &&
        userSpan > 0.2) {
      ratio = userSpan / referenceSpan;
    }

    final issues = <PaceIssue>[];

    for (final entry in alignment.matches.entries) {
      final referenceTiming = referenceTimings[entry.key];
      final userTiming = entry.value;

      if (referenceTiming?.durationSeconds == null ||
          userTiming.durationSeconds == null) {
        continue;
      }

      final referenceDuration = referenceTiming!.durationSeconds!;
      final userDuration = userTiming.durationSeconds!;

      if (referenceDuration < 0.08 || userDuration < 0.05) {
        continue;
      }

      final wordRatio = userDuration / referenceDuration;

      if (wordRatio > 1.7 || wordRatio < 0.58) {
        issues.add(
          PaceIssue(
            text: referenceTokens[entry.key].original,
            ratio: wordRatio,
            userSeconds: userDuration,
            referenceSeconds: referenceDuration,
          ),
        );
      }
    }

    issues.sort((a, b) {
      final aDistance = (math.log(a.ratio)).abs();
      final bDistance = (math.log(b.ratio)).abs();
      return bDistance.compareTo(aDistance);
    });

    final limitedIssues = issues.take(6).toList(growable: false);
    final buffer = StringBuffer();

    if (ratio == null) {
      buffer.write('Not enough voiced audio to compare pace reliably.');
    } else {
      final percent = ((ratio - 1) * 100).round().abs();

      if (percent <= 10) {
        buffer.write('Your overall pace matched the reference closely.');
      } else if (ratio > 1) {
        buffer.write('Your overall pace was about $percent% slower.');
      } else {
        buffer.write('Your overall pace was about $percent% faster.');
      }
    }

    if (limitedIssues.isNotEmpty) {
      final slow = limitedIssues.where((issue) => issue.ratio > 1).length;
      final fast = limitedIssues.length - slow;

      buffer.write(' ');

      if (slow > 0 && fast > 0) {
        buffer.write('$slow word(s) were held longer and $fast shorter.');
      } else if (slow > 0) {
        buffer.write('$slow word(s) were held noticeably longer.');
      } else {
        buffer.write('$fast word(s) were noticeably shorter.');
      }
    }

    return _PaceResult(
      ratio: ratio,
      summary: buffer.toString(),
      issues: limitedIssues,
    );
  }

  double? _voicedSpan(List<PitchFrame> frames) {
    if (frames.length < 2) {
      return null;
    }

    final start = frames.first.timeSeconds;
    final end = frames.last.timeSeconds;

    if (end <= start) {
      return null;
    }

    return end - start;
  }

  _ToneResult _toneFeedback({
    required List<_TokenInfo> referenceTokens,
    required _Alignment alignment,
    required Map<int, _TimedToken> referenceTimings,
    required List<PitchFrame> referencePitch,
    required List<PitchFrame> userPitch,
  }) {
    final guide = <ToneGuideItem>[];
    final issues = <ToneIssue>[];
    var checked = 0;
    var matched = 0;

    for (var index = 0; index < referenceTokens.length; index++) {
      final token = referenceTokens[index];
      final referenceTiming = referenceTimings[index];
      guide.add(
        ToneGuideItem(
          text: token.original,
          tone: token.tone,
          startSeconds: referenceTiming?.startSeconds,
          durationSeconds: referenceTiming?.durationSeconds,
        ),
      );

      final userTiming = alignment.matches[index];

      if (referenceTiming == null ||
          userTiming == null ||
          referenceTiming.startSeconds == null ||
          referenceTiming.durationSeconds == null ||
          userTiming.startSeconds == null ||
          userTiming.durationSeconds == null) {
        continue;
      }

      final referenceContour = _contour(
        referencePitch,
        referenceTiming.startSeconds!,
        referenceTiming.durationSeconds!,
      );
      final userContour = _contour(
        userPitch,
        userTiming.startSeconds!,
        userTiming.durationSeconds!,
      );

      if (referenceContour == null || userContour == null) {
        continue;
      }

      checked++;
      final expected = token.tone;
      final userShape = _classifyContour(userContour.values);
      final referenceShape = _classifyContour(referenceContour.values);
      final isCompatible = _isCompatible(expected, userShape, userContour);

      if (isCompatible) {
        matched++;
        continue;
      }

      final message = _toneMessage(
        expected: expected,
        observed: userShape,
        reference: referenceShape,
      );
      issues.add(
        ToneIssue(
          text: token.original,
          expected: expected,
          observedContour: userShape,
          message: message,
        ),
      );
    }

    return _ToneResult(
      guide: guide,
      issues: issues,
      checkedCount: checked,
      matchedCount: matched,
    );
  }

  _Contour? _contour(
    List<PitchFrame> frames,
    double startSeconds,
    double durationSeconds,
  ) {
    final selected = <PitchFrame>[];

    for (final frame in frames) {
      if (frame.timeSeconds >= startSeconds - 0.03 &&
          frame.timeSeconds <= startSeconds + durationSeconds + 0.03) {
        selected.add(frame);
      }
    }

    if (selected.length < 3) {
      return null;
    }

    final frequencies = selected.map((frame) => frame.f0Hz).toList()..sort();
    final median = frequencies[frequencies.length ~/ 2];

    if (median <= 0) {
      return null;
    }

    final values = selected
        .map((frame) => 12 * (math.log(frame.f0Hz / median) / math.ln2))
        .toList(growable: false);

    return _Contour(values: values);
  }

  String _classifyContour(List<double> values) {
    if (values.length < 3) {
      return 'unclear';
    }

    final quarter = values.length ~/ 4;
    final edgeCount = quarter < 1 ? 1 : quarter;
    final startMean = _mean(values.take(edgeCount));
    final endStart = values.length - edgeCount;
    final endMean = _mean(values.skip(endStart));
    final range = values.reduce(math.max) - values.reduce(math.min);
    final minimum = values.reduce(math.min);
    final minimumIndex = values.indexOf(minimum);
    final relativeMinimum = minimumIndex / (values.length - 1);
    final dip =
        relativeMinimum > 0.18 &&
        relativeMinimum < 0.82 &&
        (math.max(startMean, endMean) - minimum) > 1.0 &&
        (endMean - minimum) > 0.7;
    final delta = endMean - startMean;

    if (dip && range > 2.0) {
      return 'dipping';
    }

    if (delta > 1.4 && range > 2.0) {
      return 'rising';
    }

    if (delta < -1.4 && range > 2.0) {
      return 'falling';
    }

    if (range < 3.0) {
      return 'level';
    }

    return 'unclear';
  }

  bool _isCompatible(
    VietnameseTone expected,
    String observed,
    _Contour contour,
  ) {
    final range =
        contour.values.reduce(math.max) - contour.values.reduce(math.min);

    switch (expected) {
      case VietnameseTone.ngang:
        return observed == 'level' || observed == 'unclear' || range < 4.5;
      case VietnameseTone.huyen:
      case VietnameseTone.nang:
        return observed != 'rising';
      case VietnameseTone.sac:
      case VietnameseTone.nga:
        return observed != 'falling';
      case VietnameseTone.hoi:
        return observed == 'dipping' ||
            observed == 'unclear' ||
            observed == 'level';
    }
  }

  String _toneMessage({
    required VietnameseTone expected,
    required String observed,
    required String reference,
  }) {
    final expectedShape = expected.expectedContour;
    final observedLabel = _shapeLabel(observed);
    final referenceLabel = _shapeLabel(reference);

    if (observed == 'level' && expectedShape != 'level') {
      return 'Expected ${expected.label} (${expected.arrow}); '
          'your pitch stayed too level.';
    }

    if (expectedShape == 'falling' && observed == 'rising') {
      return 'Expected ${expected.label} (${expected.arrow}); '
          'your pitch rose instead of falling.';
    }

    if (expectedShape == 'rising' && observed == 'falling') {
      return 'Expected ${expected.label} (${expected.arrow}); '
          'your pitch fell instead of rising.';
    }

    if (expectedShape == 'level' && observed != 'level') {
      return 'Expected ${expected.label} (${expected.arrow}); '
          'your pitch moved $observedLabel.';
    }

    if (reference != 'unclear' && reference != observed) {
      return 'The model contour was $referenceLabel; '
          'yours was $observedLabel.';
    }

    return 'The contour did not clearly match ${expected.label} '
        '(${expected.arrow}); listen to the highlighted word again.';
  }

  String _shapeLabel(String shape) {
    switch (shape) {
      case 'rising':
        return 'rising';
      case 'falling':
        return 'falling';
      case 'dipping':
        return 'dipping then rising';
      case 'level':
        return 'level';
      default:
        return 'unclear';
    }
  }

  double _mean(Iterable<double> values) {
    var sum = 0.0;
    var count = 0;

    for (final value in values) {
      sum += value;
      count++;
    }

    return count == 0 ? 0 : sum / count;
  }
}

class _TokenInfo {
  const _TokenInfo({
    required this.original,
    required this.folded,
    required this.tone,
  });

  final String original;
  final String folded;
  final VietnameseTone tone;
}

class _TimedToken {
  const _TimedToken({
    required this.token,
    this.startSeconds,
    this.durationSeconds,
    this.confidence,
  });

  final _TokenInfo token;
  final double? startSeconds;
  final double? durationSeconds;
  final double? confidence;
}

class _Alignment {
  const _Alignment({
    required this.matches,
    required this.unmatchedReferenceIndexes,
    required this.extraUserIndexes,
  });

  final Map<int, _TimedToken> matches;
  final List<int> unmatchedReferenceIndexes;
  final List<int> extraUserIndexes;
}

class _PaceResult {
  const _PaceResult({
    required this.ratio,
    required this.summary,
    required this.issues,
  });

  final double? ratio;
  final String summary;
  final List<PaceIssue> issues;
}

class _ToneResult {
  const _ToneResult({
    required this.guide,
    required this.issues,
    required this.checkedCount,
    required this.matchedCount,
  });

  final List<ToneGuideItem> guide;
  final List<ToneIssue> issues;
  final int checkedCount;
  final int matchedCount;
}

class _Contour {
  const _Contour({required this.values});

  final List<double> values;
}
