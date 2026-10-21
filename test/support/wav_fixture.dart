import 'dart:io';
import 'dart:typed_data';

Uint8List buildTestWav({
  int sampleRate = 24000,
  int channels = 1,
  int bitDepth = 16,
  int sampleFrames = 2400,
  int audioFormat = 1,
}) {
  final bytesPerSample = bitDepth ~/ 8;
  final blockAlign = channels * bytesPerSample;
  final dataBytes = sampleFrames * blockAlign;
  final byteRate = sampleRate * blockAlign;
  final bytes = Uint8List(44 + dataBytes);
  final data = ByteData.sublistView(bytes);

  void writeAscii(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes[offset + i] = value.codeUnitAt(i);
    }
  }

  writeAscii(0, 'RIFF');
  data.setUint32(4, 36 + dataBytes, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, audioFormat, Endian.little);
  data.setUint16(22, channels, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, byteRate, Endian.little);
  data.setUint16(32, blockAlign, Endian.little);
  data.setUint16(34, bitDepth, Endian.little);
  writeAscii(36, 'data');
  data.setUint32(40, dataBytes, Endian.little);

  return bytes;
}

Future<File> writeTestWavFile(
  String path, {
  int sampleRate = 24000,
  int channels = 1,
  int bitDepth = 16,
  int sampleFrames = 2400,
  int audioFormat = 1,
}) async {
  final file = File(path);
  await file.writeAsBytes(
    buildTestWav(
      sampleRate: sampleRate,
      channels: channels,
      bitDepth: bitDepth,
      sampleFrames: sampleFrames,
      audioFormat: audioFormat,
    ),
  );
  return file;
}
