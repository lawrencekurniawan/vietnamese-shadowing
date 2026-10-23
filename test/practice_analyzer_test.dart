import 'package:flutter_test/flutter_test.dart';
import 'package:vietnamese_shadowing/practice/practice_analyzer.dart';
import 'package:vietnamese_shadowing/practice/practice_speech_service.dart';
import 'package:vietnamese_shadowing/practice/vietnamese_tone.dart';

List<PitchFrame> _levelPitch({
  double start = 0.05,
  double end = 1.95,
  double hz = 150,
}) {
  final frames = <PitchFrame>[];
  var time = start;

  while (time <= end) {
    frames.add(PitchFrame(timeSeconds: time, f0Hz: hz));
    time += 0.1;
  }

  return frames;
}

List<PitchFrame> _contourPitch({
  required double start,
  required double end,
  required double fromHz,
  required double toHz,
}) {
  final frames = <PitchFrame>[];
  const steps = 8;

  for (var index = 0; index <= steps; index++) {
    final fraction = index / steps;
    frames.add(
      PitchFrame(
        timeSeconds: start + (end - start) * fraction,
        f0Hz: fromHz + (toHz - fromHz) * fraction,
      ),
    );
  }

  return frames;
}

void main() {
  const analyzer = PracticeAnalyzer();
  const referenceText = 'Chào bạn hôm nay';

  test('matches words without tone marks and accepts level contours', () {
    final transcript = SpeechTranscript(
      text: referenceText,
      segments: const <SpeechSegment>[
        SpeechSegment(text: referenceText, startSeconds: 0, durationSeconds: 2),
      ],
      usedOnDevice: true,
    );
    final userTranscript = SpeechTranscript(
      text: 'chao ban hom nay',
      segments: const <SpeechSegment>[
        SpeechSegment(
          text: 'chao ban hom nay',
          startSeconds: 0,
          durationSeconds: 2,
        ),
      ],
      usedOnDevice: true,
    );
    final pitch = _levelPitch();

    final feedback = analyzer.analyze(
      referenceText: referenceText,
      referenceAudioPath: 'reference.wav',
      userAudioPath: 'take.wav',
      referenceTranscript: transcript,
      userTranscript: userTranscript,
      referencePitch: pitch,
      userPitch: pitch,
      referenceDurationSeconds: 2,
      userDurationSeconds: 2,
    );

    expect(feedback.matchedWordCount, 4);
    expect(feedback.totalWordCount, 4);
    expect(feedback.unclearWords, isEmpty);
    expect(feedback.extraWords, isEmpty);
    expect(feedback.wordAccuracy, 1);
    expect(feedback.paceRatio, closeTo(1, 0.001));
    expect(feedback.toneCheckedCount, 4);
    expect(feedback.toneMatchedCount, 4);
    expect(feedback.toneGuide, hasLength(4));
    expect(feedback.toneGuide.first.tone, VietnameseTone.huyen);
    expect(feedback.note, contains('on-device'));
  });

  test('reports missing words and a rising huyền contour', () {
    const userText = 'chao';
    final referenceTranscript = SpeechTranscript(
      text: 'Chào',
      segments: const <SpeechSegment>[
        SpeechSegment(text: 'Chào', startSeconds: 0, durationSeconds: 0.5),
      ],
    );
    final userTranscript = SpeechTranscript(
      text: userText,
      segments: const <SpeechSegment>[
        SpeechSegment(text: userText, startSeconds: 0, durationSeconds: 0.5),
      ],
    );

    final feedback = analyzer.analyze(
      referenceText: referenceText,
      referenceAudioPath: 'reference.wav',
      userAudioPath: 'take.wav',
      referenceTranscript: referenceTranscript,
      userTranscript: userTranscript,
      referencePitch: _contourPitch(start: 0, end: 0.5, fromHz: 200, toHz: 120),
      userPitch: _contourPitch(start: 0, end: 0.5, fromHz: 120, toHz: 200),
      referenceDurationSeconds: 0.5,
      userDurationSeconds: 0.5,
    );

    expect(feedback.matchedWordCount, 1);
    expect(feedback.unclearWords, containsAll(<String>['bạn', 'hôm', 'nay']));
    expect(feedback.toneCheckedCount, 1);
    expect(feedback.toneMatchedCount, 0);
    expect(feedback.toneIssues, hasLength(1));
    expect(feedback.toneIssues.first.text, 'Chào');
    expect(feedback.toneIssues.first.observedContour, 'rising');
    expect(feedback.toneIssues.first.message, contains('rose'));
  });
}
