import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vietnamese_shadowing/practice/practice_assessment_service.dart';
import 'package:vietnamese_shadowing/practice/practice_speech_service.dart';

Uint8List _wavBytes({int seconds = 1}) {
  const sampleRate = 8000;
  const channels = 1;
  const bitDepth = 16;
  final blockAlign = channels * (bitDepth ~/ 8);
  final dataSize = sampleRate * seconds * blockAlign;
  final bytes = Uint8List(44 + dataSize);
  final data = ByteData.sublistView(bytes);

  void writeAscii(int offset, String value) {
    for (var index = 0; index < value.length; index++) {
      bytes[offset + index] = value.codeUnitAt(index);
    }
  }

  writeAscii(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, channels, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * blockAlign, Endian.little);
  data.setUint16(32, blockAlign, Endian.little);
  data.setUint16(34, bitDepth, Endian.little);
  writeAscii(36, 'data');
  data.setUint32(40, dataSize, Endian.little);

  return bytes;
}

class _FakeSpeechService implements PracticeSpeechService {
  final List<String> transcribedPaths = <String>[];
  int pitchCalls = 0;

  @override
  Future<SpeechTranscript> transcribe(
    String path, {
    String locale = 'vi-VN',
  }) async {
    transcribedPaths.add(path);

    if (path.endsWith('reference.wav')) {
      return SpeechTranscript(
        text: 'Chào bạn hôm nay',
        segments: const <SpeechSegment>[
          SpeechSegment(
            text: 'Chào bạn hôm nay',
            startSeconds: 0,
            durationSeconds: 1,
          ),
        ],
        usedOnDevice: true,
      );
    }

    return SpeechTranscript(
      text: 'chao ban hom nay',
      segments: const <SpeechSegment>[
        SpeechSegment(
          text: 'chao ban hom nay',
          startSeconds: 0,
          durationSeconds: 1,
        ),
      ],
      usedOnDevice: true,
    );
  }

  @override
  Future<List<PitchFrame>> extractPitch(String path) async {
    pitchCalls++;
    final frames = <PitchFrame>[];

    for (var time = 0.05; time <= 0.95; time += 0.025) {
      frames.add(PitchFrame(timeSeconds: time, f0Hz: 150));
    }

    return frames;
  }
}

void main() {
  test('assesses a take and caches transcription and pitch by path', () async {
    final directory = await Directory.systemTemp.createTemp('vshadow-assess-');
    addTearDown(() => directory.delete(recursive: true));
    final referencePath = '${directory.path}/reference.wav';
    final userPath = '${directory.path}/take.wav';
    await File(referencePath).writeAsBytes(_wavBytes());
    await File(userPath).writeAsBytes(_wavBytes());

    final speech = _FakeSpeechService();
    final service = PracticeAssessmentService(speechService: speech);

    final feedback = await service.assess(
      referenceText: 'Chào bạn hôm nay',
      referenceAudioPath: referencePath,
      userAudioPath: userPath,
    );

    expect(feedback.matchedWordCount, 4);
    expect(feedback.totalWordCount, 4);
    expect(feedback.wordAccuracy, 1);
    expect(feedback.paceRatio, closeTo(1, 0.001));
    expect(feedback.toneCheckedCount, 4);
    expect(feedback.toneMatchedCount, 4);
    expect(feedback.note, contains('on-device'));
    expect(feedback.referenceAudioPath, referencePath);
    expect(feedback.userAudioPath, userPath);
    expect(speech.transcribedPaths, <String>[referencePath, userPath]);
    expect(speech.pitchCalls, 2);

    final second = await service.assess(
      referenceText: 'Chào bạn hôm nay',
      referenceAudioPath: referencePath,
      userAudioPath: userPath,
    );

    expect(second.matchedWordCount, 4);
    expect(speech.transcribedPaths, <String>[referencePath, userPath]);
    expect(speech.pitchCalls, 2);
  });

  test('rejects a take when the reference text is empty', () async {
    final directory = await Directory.systemTemp.createTemp('vshadow-assess-');
    addTearDown(() => directory.delete(recursive: true));
    final referencePath = '${directory.path}/reference.wav';
    final userPath = '${directory.path}/take.wav';
    await File(referencePath).writeAsBytes(_wavBytes());
    await File(userPath).writeAsBytes(_wavBytes());
    final service = PracticeAssessmentService(
      speechService: _FakeSpeechService(),
    );

    expect(
      () => service.assess(
        referenceText: '   ',
        referenceAudioPath: referencePath,
        userAudioPath: userPath,
      ),
      throwsA(isA<PracticeAssessmentException>()),
    );
  });
}
