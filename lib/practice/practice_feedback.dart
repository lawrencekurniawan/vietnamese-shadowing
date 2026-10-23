import 'vietnamese_tone.dart';

class ToneGuideItem {
  const ToneGuideItem({
    required this.text,
    required this.tone,
    this.startSeconds,
    this.durationSeconds,
  });

  final String text;
  final VietnameseTone tone;
  final double? startSeconds;
  final double? durationSeconds;

  bool get canPlay => startSeconds != null && durationSeconds != null;
}

class ToneIssue {
  const ToneIssue({
    required this.text,
    required this.expected,
    required this.observedContour,
    required this.message,
  });

  final String text;
  final VietnameseTone expected;
  final String observedContour;
  final String message;
}

class PaceIssue {
  const PaceIssue({
    required this.text,
    required this.ratio,
    required this.userSeconds,
    required this.referenceSeconds,
  });

  final String text;
  final double ratio;
  final double userSeconds;
  final double referenceSeconds;
}

class PracticeFeedback {
  const PracticeFeedback({
    required this.matchedWordCount,
    required this.totalWordCount,
    required this.unclearWords,
    required this.extraWords,
    required this.paceRatio,
    required this.cadenceSummary,
    required this.paceIssues,
    required this.toneIssues,
    required this.toneGuide,
    required this.toneCheckedCount,
    required this.toneMatchedCount,
    required this.referenceAudioPath,
    required this.userAudioPath,
    this.referenceDurationSeconds,
    this.userDurationSeconds,
    this.note,
  });

  final int matchedWordCount;
  final int totalWordCount;
  final List<String> unclearWords;
  final List<String> extraWords;
  final double? paceRatio;
  final String cadenceSummary;
  final List<PaceIssue> paceIssues;
  final List<ToneIssue> toneIssues;
  final List<ToneGuideItem> toneGuide;
  final int toneCheckedCount;
  final int toneMatchedCount;
  final String referenceAudioPath;
  final String userAudioPath;
  final double? referenceDurationSeconds;
  final double? userDurationSeconds;
  final String? note;

  double get wordAccuracy {
    if (totalWordCount == 0) {
      return 0;
    }

    return matchedWordCount / totalWordCount;
  }

  String get wordAccuracyLabel =>
      '${(wordAccuracy * 100).round()}% words recognized';
}
