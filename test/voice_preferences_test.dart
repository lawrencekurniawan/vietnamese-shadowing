import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vietnamese_shadowing/native/vieneu_ffi.dart';
import 'package:vietnamese_shadowing/voices/voice_preferences.dart';

void main() {
  late List<VietnameseVoice> catalogVoices;

  setUpAll(() {
    final catalogFile = File('assets/vieneu/voices_v3_turbo.json');
    final decoded =
        jsonDecode(catalogFile.readAsStringSync()) as Map<String, dynamic>;
    final presets = decoded['presets'] as Map<String, dynamic>;

    catalogVoices = presets.entries
        .map((entry) {
          final preset = entry.value as Map<String, dynamic>;

          return VietnameseVoice(
            id: entry.key,
            name: entry.key,
            description: preset['description'] as String,
            gender: preset['gender'] as String,
            accent: preset['region'] as String,
            style: preset['style'] as String,
          );
        })
        .toList(growable: false);
  });

  test('the shipped catalog contains the curated southern male voices', () {
    final curated = selectPreferredVoices(catalogVoices);

    expect(curated.map((voice) => voice.name), ['Adam', 'Thái Sơn']);

    for (final voice in curated) {
      expect(voice.accent, 'Nam');
      expect(voice.gender, 'male');
    }
  });

  test('the default curated voice is Adam', () {
    final curated = selectPreferredVoices(catalogVoices);

    expect(defaultPreferredVoice(curated).name, 'Adam');
    expect(defaultPreferredVoicePresetName, 'Adam');
  });

  test('non-curated voices are ignored', () {
    final curated = selectPreferredVoices(catalogVoices);

    expect(curated, hasLength(2));
    expect(curated.any((voice) => voice.name == 'Mai Anh'), isFalse);
  });

  test('a missing preferred voice fails loudly', () {
    final onlyAdam = catalogVoices.where((voice) => voice.name == 'Adam');

    expect(
      () => selectPreferredVoices(onlyAdam),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Thái Sơn'),
        ),
      ),
    );
  });

  test('a missing default voice fails loudly', () {
    final noAdam = catalogVoices.where((voice) => voice.name != 'Adam');

    expect(
      () => defaultPreferredVoice(noAdam),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Adam'),
        ),
      ),
    );
  });
}
