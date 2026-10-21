import 'dart:io';
import 'dart:typed_data';

/// Basic PCM WAV format information required by the local library and
/// `.vshadow` package validation.
class WavInfo {
  const WavInfo({
    required this.sampleRate,
    required this.channels,
    required this.bitDepth,
    required this.byteRate,
    required this.dataBytes,
  });

  final int sampleRate;
  final int channels;
  final int bitDepth;
  final int byteRate;
  final int dataBytes;

  double get durationSeconds => dataBytes / byteRate;

  static Future<WavInfo> readFile(String path) async {
    final bytes = await File(path).readAsBytes();
    return parse(bytes);
  }

  static WavInfo parse(Uint8List bytes) {
    if (bytes.length < 44) {
      throw const FormatException('WAV file is too small.');
    }

    if (String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
      throw const FormatException('Not a valid RIFF/WAVE file.');
    }

    final data = ByteData.sublistView(bytes);
    var offset = 12;

    int? audioFormat;
    int? channels;
    int? sampleRate;
    int? byteRate;
    int? blockAlign;
    int? bitDepth;
    int? dataBytes;

    while (offset + 8 <= bytes.length) {
      final chunkId = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final chunkSize = data.getUint32(offset + 4, Endian.little);
      final chunkDataStart = offset + 8;

      if (chunkSize > bytes.length - chunkDataStart) {
        throw const FormatException('WAV chunk exceeds file size.');
      }

      if (chunkId == 'fmt ') {
        if (chunkSize < 16) {
          throw const FormatException('Invalid WAV fmt chunk.');
        }

        audioFormat = data.getUint16(chunkDataStart, Endian.little);
        channels = data.getUint16(chunkDataStart + 2, Endian.little);
        sampleRate = data.getUint32(chunkDataStart + 4, Endian.little);
        byteRate = data.getUint32(chunkDataStart + 8, Endian.little);
        blockAlign = data.getUint16(chunkDataStart + 12, Endian.little);
        bitDepth = data.getUint16(chunkDataStart + 14, Endian.little);
      } else if (chunkId == 'data') {
        dataBytes = chunkSize;
        break;
      }

      offset = chunkDataStart + chunkSize;

      if (offset.isOdd) {
        offset++;
      }
    }

    if (audioFormat == null ||
        channels == null ||
        sampleRate == null ||
        byteRate == null ||
        blockAlign == null ||
        bitDepth == null ||
        dataBytes == null) {
      throw const FormatException('WAV file is missing required chunks.');
    }

    if (audioFormat != 1) {
      throw FormatException('Unsupported WAV audio format: $audioFormat.');
    }

    if (channels < 1 || channels > 8) {
      throw FormatException('Invalid WAV channel count: $channels.');
    }

    if (sampleRate < 8000 || sampleRate > 384000) {
      throw FormatException('Invalid WAV sample rate: $sampleRate.');
    }

    if (!<int>{8, 16, 24, 32}.contains(bitDepth)) {
      throw FormatException('Invalid WAV bit depth: $bitDepth.');
    }

    if (byteRate <= 0) {
      throw const FormatException('Invalid WAV byte rate.');
    }

    final expectedBlockAlign = channels * (bitDepth ~/ 8);

    if (blockAlign != expectedBlockAlign) {
      throw const FormatException('Invalid WAV block alignment.');
    }

    if (dataBytes <= 0 || dataBytes % blockAlign != 0) {
      throw const FormatException('Invalid WAV data chunk size.');
    }

    final expectedByteRate = sampleRate * blockAlign;

    if (byteRate != expectedByteRate) {
      throw const FormatException('Invalid WAV byte rate.');
    }

    return WavInfo(
      sampleRate: sampleRate,
      channels: channels,
      bitDepth: bitDepth,
      byteRate: byteRate,
      dataBytes: dataBytes,
    );
  }
}
