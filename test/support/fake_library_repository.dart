import 'dart:io';
import 'dart:typed_data';

import 'package:vietnamese_shadowing/library/library_ids.dart';
import 'package:vietnamese_shadowing/library/library_metadata.dart';
import 'package:vietnamese_shadowing/library/library_repository.dart';
import 'package:vietnamese_shadowing/library/wav_info.dart';

class FakeLibraryRepository extends LibraryRepository {
  FakeLibraryRepository({required super.applicationSupportDirectory});

  final List<LibraryItemMetadata> items = <LibraryItemMetadata>[];
  final Map<String, String> audioPaths = <String, String>{};

  int saveFromWavCalls = 0;
  int saveAudioBytesCalls = 0;

  @override
  Future<void> initialize() async {}

  @override
  Future<List<LibraryItemMetadata>> list() async {
    return List<LibraryItemMetadata>.unmodifiable(items);
  }

  @override
  File audioFile(String itemId) {
    return File(audioPaths[itemId] ?? '/fake-library/$itemId.wav');
  }

  @override
  Future<LibraryItemMetadata?> read(String itemId) async {
    for (final item in items) {
      if (item.itemId == itemId) {
        return item;
      }
    }

    return null;
  }

  @override
  Future<LibraryItemMetadata> saveFromWavFile({
    required String title,
    required String originalText,
    required String normalizedText,
    required VoiceMetadata voice,
    required String sourceWavPath,
    DateTime? createdAtUtc,
  }) async {
    saveFromWavCalls++;
    return saveAudioBytes(
      title: title,
      originalText: originalText,
      normalizedText: normalizedText,
      voice: voice,
      audioBytes: buildFakeWavBytes(),
      createdAtUtc: createdAtUtc,
      sourceWavPath: sourceWavPath,
    );
  }

  @override
  Future<LibraryItemMetadata> saveAudioBytes({
    required String title,
    required String originalText,
    required String normalizedText,
    required VoiceMetadata voice,
    required List<int> audioBytes,
    DateTime? createdAtUtc,
    String? itemId,
    String? sourceWavPath,
  }) async {
    saveAudioBytesCalls++;

    final resolvedItemId = itemId ?? generateLibraryItemId();
    final wavInfo = WavInfo.parse(Uint8List.fromList(audioBytes));
    final item = LibraryItemMetadata(
      itemId: resolvedItemId,
      title: title.trim(),
      originalText: originalText.trim(),
      normalizedText: normalizedText.trim(),
      voice: voice,
      createdAtUtc: (createdAtUtc ?? DateTime.now()).toUtc(),
      audio: AudioMetadata(
        sampleRate: wavInfo.sampleRate,
        channels: wavInfo.channels,
        bitDepth: wavInfo.bitDepth,
        durationSeconds: wavInfo.durationSeconds,
      ),
    );

    items.insert(0, item);

    if (sourceWavPath != null) {
      audioPaths[item.itemId] = sourceWavPath;
    }

    return item;
  }

  @override
  Future<void> rename(String itemId, String title) async {
    final index = items.indexWhere((item) => item.itemId == itemId);

    if (index < 0) {
      throw StateError('Library item not found: $itemId');
    }

    final item = items[index];
    items[index] = LibraryItemMetadata(
      itemId: item.itemId,
      title: title.trim(),
      originalText: item.originalText,
      normalizedText: item.normalizedText,
      voice: item.voice,
      createdAtUtc: item.createdAtUtc,
      audio: item.audio,
    );
  }

  @override
  Future<void> delete(String itemId) async {
    items.removeWhere((item) => item.itemId == itemId);
    audioPaths.remove(itemId);
  }

  @override
  Future<bool> itemExists(String itemId) async {
    return items.any((item) => item.itemId == itemId);
  }
}

Uint8List buildFakeWavBytes({int sampleFrames = 48000}) {
  final dataBytes = sampleFrames * 2;
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
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 48000, Endian.little);
  data.setUint32(28, 96000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  writeAscii(36, 'data');
  data.setUint32(40, dataBytes, Endian.little);

  return bytes;
}
