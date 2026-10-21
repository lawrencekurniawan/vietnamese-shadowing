import 'package:flutter_test/flutter_test.dart';
import 'package:vietnamese_shadowing/library/wav_export_filename.dart';

void main() {
  final timestamp = DateTime(2026, 10, 20, 21, 30, 45);

  test('builds the documented filename convention', () {
    final filename = buildWavExportFilename(
      text: 'Xin chào, thế giới!',
      stableVoiceId: 'minh-duc',
      exportedAt: timestamp,
    );

    expect(filename, 'xin-chao-the-gioi_minh-duc_2026-10-20_213045.wav');
  });

  test('folds Vietnamese diacritics in the text slug', () {
    final filename = buildWavExportFilename(
      text: 'Đặng Thùy Dung',
      stableVoiceId: 'thuy-dung',
      exportedAt: timestamp,
    );

    expect(filename, 'dang-thuy-dung_thuy-dung_2026-10-20_213045.wav');
  });

  test('falls back to audio when the text slug is empty', () {
    final filename = buildWavExportFilename(
      text: '!!! 😀 ...',
      stableVoiceId: 'adam',
      exportedAt: timestamp,
    );

    expect(filename, 'audio_adam_2026-10-20_213045.wav');
  });

  test('adds collision suffixes starting at -2', () {
    final base = buildWavExportFilename(
      text: 'Xin chào',
      stableVoiceId: 'adam',
      exportedAt: timestamp,
    );

    expect(
      applyWavCollisionSuffix(base, 1),
      'xin-chao_adam_2026-10-20_213045-2.wav',
    );
    expect(
      applyWavCollisionSuffix(base, 2),
      'xin-chao_adam_2026-10-20_213045-3.wav',
    );
    expect(
      buildWavExportFilename(
        text: 'Xin chào',
        stableVoiceId: 'adam',
        exportedAt: timestamp,
        collisionIndex: 3,
      ),
      'xin-chao_adam_2026-10-20_213045-4.wav',
    );
  });

  test('limits the text slug to 60 characters', () {
    final filename = buildWavExportFilename(
      text: List<String>.filled(80, 'a').join(),
      stableVoiceId: 'adam',
      exportedAt: timestamp,
    );

    expect(filename.split('_').first.length, 60);
  });

  test('limits the voice component to 32 characters', () {
    final filename = buildWavExportFilename(
      text: 'Text',
      stableVoiceId: List<String>.filled(40, 'v').join(),
      exportedAt: timestamp,
    );

    expect(filename.split('_')[1].length, 32);
  });

  test('never emits path separators or traversal components', () {
    final filename = buildWavExportFilename(
      text: '../..',
      stableVoiceId: '../../evil',
      exportedAt: timestamp,
    );

    expect(filename.contains('/'), isFalse);
    expect(filename.contains(r'\'), isFalse);
    expect(filename.contains('..'), isFalse);
  });

  test('rejects invalid collision arguments', () {
    expect(() => applyWavCollisionSuffix('audio.wav', -1), throwsArgumentError);
    expect(() => applyWavCollisionSuffix('audio.mp3', 1), throwsArgumentError);
    expect(
      () => applyWavCollisionSuffix('../audio.wav', 1),
      throwsArgumentError,
    );
    expect(
      () => applyWavCollisionSuffix(r'..\audio.wav', 1),
      throwsArgumentError,
    );
    expect(
      () => buildWavExportFilename(
        text: 'Text',
        stableVoiceId: 'adam',
        exportedAt: timestamp,
        collisionIndex: -1,
      ),
      throwsArgumentError,
    );
  });
}
