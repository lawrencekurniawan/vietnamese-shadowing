import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vietnamese_shadowing/library/wav_info.dart';
import 'package:vietnamese_shadowing/practice/wav_segment_extractor.dart';

Uint8List wavBytes({int seconds = 1}) {
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

  for (var frame = 0; frame < sampleRate * seconds; frame++) {
    data.setInt16(44 + frame * blockAlign, (frame % 1000) - 500, Endian.little);
  }

  return bytes;
}

void main() {
  test('extracts a PCM range into a standalone WAV', () {
    final source = wavBytes(seconds: 1);
    final segment = WavSegmentExtractor.extract(
      bytes: source,
      startSeconds: 0.25,
      durationSeconds: 0.5,
    );
    final info = WavInfo.parse(segment);

    expect(info.sampleRate, 8000);
    expect(info.channels, 1);
    expect(info.bitDepth, 16);
    expect(info.dataBytes, 8000);
    expect(info.durationSeconds, closeTo(0.5, 0.001));

    final sourceData = ByteData.sublistView(source);
    final segmentData = ByteData.sublistView(segment);
    expect(
      segmentData.getInt16(44, Endian.little),
      sourceData.getInt16(44 + 2000 * 2, Endian.little),
    );
  });

  test('clamps a segment that runs past the end of the file', () {
    final segment = WavSegmentExtractor.extract(
      bytes: wavBytes(seconds: 1),
      startSeconds: 0.8,
      durationSeconds: 2,
    );
    final info = WavInfo.parse(segment);

    expect(info.durationSeconds, closeTo(0.2, 0.001));
  });

  test('rejects invalid ranges', () {
    final source = wavBytes(seconds: 1);

    expect(
      () => WavSegmentExtractor.extract(
        bytes: source,
        startSeconds: -1,
        durationSeconds: 0.5,
      ),
      throwsFormatException,
    );
    expect(
      () => WavSegmentExtractor.extract(
        bytes: source,
        startSeconds: 0.2,
        durationSeconds: 0,
      ),
      throwsFormatException,
    );
  });
}
