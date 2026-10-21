import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vietnamese_shadowing/native/vieneu_ffi.dart';
import 'package:vietnamese_shadowing/voices/voice_identity.dart';

void main() {
  late List<String> presetNames;
  late List<VietnameseVoice> voices;
  late VoiceCatalog catalog;

  setUpAll(() {
    final catalogFile = File('assets/vieneu/voices_v3_turbo.json');
    final decoded =
        jsonDecode(catalogFile.readAsStringSync()) as Map<String, dynamic>;
    final presets = decoded['presets'] as Map<String, dynamic>;

    presetNames = presets.keys.cast<String>().toList();
    voices = presetNames.map((name) {
      final preset = presets[name] as Map<String, dynamic>;

      return VietnameseVoice(
        id: name,
        name: name,
        description: preset['description'] as String,
        gender: preset['gender'] as String,
        accent: preset['region'] as String,
        style: preset['style'] as String,
      );
    }).toList();

    catalog = VoiceCatalog.fromVoices(voices);
  });

  test('every catalog voice has a stable ID', () {
    expect(presetNames, hasLength(20));

    for (final name in presetNames) {
      final identity = VoiceIdentity.tryFromPresetName(name);

      expect(identity, isNotNull, reason: 'missing stable ID for $name');
      expect(isValidStableVoiceId(identity!.stableId), isTrue);
      expect(identity.stableId.length, lessThanOrEqualTo(32));
    }
  });

  test('stable IDs are unique and independent of list position', () {
    final ids = <String>[];
    final reversedCatalog = VoiceCatalog.fromVoices(
      voices.reversed.toList(growable: false),
    );

    for (final name in presetNames) {
      final stableId = VoiceIdentity.tryFromPresetName(name)!.stableId;
      ids.add(stableId);

      expect(reversedCatalog.byPresetName(name)?.stableId, stableId);
    }

    expect(ids.toSet(), hasLength(ids.length));

    for (final name in presetNames.reversed) {
      expect(
        VoiceIdentity.tryFromPresetName(name)!.stableId,
        stableVoiceIdsByPresetName[name],
      );
    }
  });

  test('stable ID and native preset round trip', () {
    for (final name in presetNames) {
      final identity = VoiceIdentity.tryFromPresetName(name)!;
      final roundTripped = VoiceIdentity.tryFromStableId(identity.stableId);

      expect(roundTripped, identity);
      expect(catalog.byStableId(identity.stableId)?.name, name);
      expect(catalog.byStableId(identity.stableId)?.id, name);
      expect(catalog.byPresetName(name)?.stableId, identity.stableId);
    }
  });

  test('the mapping contains no invented catalog entries', () {
    expect(stableVoiceIdsByPresetName.keys.toSet(), presetNames.toSet());
  });

  test('existing native preset names remain unchanged', () {
    for (final voice in catalog.voices) {
      expect(voice.id, voice.name);
      expect(voice.id, isIn(presetNames));
    }
  });

  test('display order remains Bắc, then Nam, then Trung', () {
    final sorted = catalog.voices.toList()..sort(compareVoicesForDisplay);

    final expectedRegions = <String>[];
    for (final region in const ['Bắc', 'Nam', 'Trung']) {
      final count = voices.where((voice) => voice.accent == region).length;
      expectedRegions.addAll(List<String>.filled(count, region));
    }

    expect(sorted.map((voice) => voice.accent), expectedRegions);
  });

  test('unknown preset and stable IDs fail safely', () {
    expect(VoiceIdentity.tryFromPresetName('Unknown voice'), isNull);
    expect(VoiceIdentity.tryFromStableId('unknown-voice'), isNull);
    expect(VoiceIdentity.tryFromStableId('Minh Đức'), isNull);
    expect(catalog.byStableId('unknown-voice'), isNull);
    expect(catalog.byPresetName('Unknown voice'), isNull);
  });

  test('unknown native voice metadata cannot produce a stable ID', () {
    const unknownVoice = VietnameseVoice(
      id: 'Unknown voice',
      name: 'Unknown voice',
      description: 'Unknown',
      gender: 'female',
      accent: 'Bắc',
      style: 'tu_nhien',
    );

    expect(() => unknownVoice.stableId, throwsStateError);
    expect(() => VoiceCatalog.fromVoices([unknownVoice]), throwsStateError);
  });

  test('duplicate native voices fail catalog validation', () {
    expect(
      () => VoiceCatalog.fromVoices([voices.first, voices.first]),
      throwsStateError,
    );
  });

  test('stable ID format rejects malformed values', () {
    expect(isValidStableVoiceId('minh-duc'), isTrue);
    expect(isValidStableVoiceId('Minh-duc'), isFalse);
    expect(isValidStableVoiceId('-minh-duc'), isFalse);
    expect(isValidStableVoiceId('minh-duc-'), isFalse);
    expect(isValidStableVoiceId('minh--duc'), isFalse);
    expect(isValidStableVoiceId(List<String>.filled(33, 'a').join()), isFalse);
  });
}
