import 'dart:typed_data';

import '../library/wav_info.dart';

/// Extracts a time range from a PCM WAV file so a single word or phrase can be
/// replayed from the reference recording.
class WavSegmentExtractor {
  const WavSegmentExtractor._();

  static Uint8List extract({
    required Uint8List bytes,
    required double startSeconds,
    required double durationSeconds,
  }) {
    if (!startSeconds.isFinite || startSeconds < 0) {
      throw const FormatException('WAV segment start is invalid.');
    }

    if (!durationSeconds.isFinite || durationSeconds <= 0) {
      throw const FormatException('WAV segment duration is invalid.');
    }

    final info = WavInfo.parse(bytes);
    final data = ByteData.sublistView(bytes);
    var offset = 12;
    int? fmtStart;
    int? fmtSize;
    int? dataStart;
    int? dataSize;

    while (offset + 8 <= bytes.length) {
      final chunkId = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final chunkSize = data.getUint32(offset + 4, Endian.little);
      final chunkDataStart = offset + 8;

      if (chunkSize > bytes.length - chunkDataStart) {
        throw const FormatException('WAV chunk exceeds file size.');
      }

      if (chunkId == 'fmt ') {
        fmtStart = offset;
        fmtSize = chunkSize;
      } else if (chunkId == 'data') {
        dataStart = chunkDataStart;
        dataSize = chunkSize;
        break;
      }

      offset = chunkDataStart + chunkSize;

      if (offset.isOdd) {
        offset++;
      }
    }

    if (fmtStart == null ||
        fmtSize == null ||
        dataStart == null ||
        dataSize == null) {
      throw const FormatException('WAV file is missing required chunks.');
    }

    final blockAlign = info.channels * (info.bitDepth ~/ 8);
    final totalFrames = dataSize ~/ blockAlign;
    final startFrame = (startSeconds * info.sampleRate).floor().clamp(
      0,
      totalFrames,
    );
    final requestedFrames = (durationSeconds * info.sampleRate).ceil();
    final endFrame = (startFrame + requestedFrames).clamp(
      startFrame,
      totalFrames,
    );

    if (endFrame <= startFrame) {
      throw const FormatException('WAV segment is empty.');
    }

    final sourceOffset = dataStart + startFrame * blockAlign;
    final segmentBytes = (endFrame - startFrame) * blockAlign;
    final fmtChunkBytes = 8 + fmtSize;
    final hasPadding = segmentBytes.isOdd;
    final output = Uint8List(
      12 + fmtChunkBytes + 8 + segmentBytes + (hasPadding ? 1 : 0),
    );
    final outputData = ByteData.sublistView(output);
    var writeOffset = 0;

    void writeAscii(String value) {
      for (final unit in value.codeUnits) {
        output[writeOffset++] = unit;
      }
    }

    writeAscii('RIFF');
    outputData.setUint32(4, output.length - 8, Endian.little);
    writeOffset = 8;
    writeAscii('WAVE');
    output.setRange(writeOffset, writeOffset + fmtChunkBytes, bytes, fmtStart);
    writeOffset += fmtChunkBytes;
    writeAscii('data');
    outputData.setUint32(writeOffset, segmentBytes, Endian.little);
    writeOffset += 4;
    output.setRange(
      writeOffset,
      writeOffset + segmentBytes,
      bytes,
      sourceOffset,
    );

    if (hasPadding) {
      output[output.length - 1] = 0;
    }

    return output;
  }
}
