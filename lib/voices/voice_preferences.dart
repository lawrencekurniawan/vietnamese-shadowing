import '../native/vieneu_ffi.dart';
import 'voice_identity.dart';

/// Native presets exposed by the Generate tab.
///
/// Both are southern male voices. The native catalog may contain additional
/// voices for older library items and portable packages, but new synthesis is
/// intentionally limited to this curated set.
const List<String> preferredVoicePresetNames = <String>['Adam', 'Thái Sơn'];

/// Default voice for a fresh installation.
const String defaultPreferredVoicePresetName = 'Adam';

/// Returns the preferred voices in the requested order.
///
/// Throws when a preferred preset is missing so a catalog regression fails
/// loudly instead of silently falling back to an unrelated voice.
List<VietnameseVoice> selectPreferredVoices(Iterable<VietnameseVoice> voices) {
  final byPresetName = <String, VietnameseVoice>{
    for (final voice in voices) voice.name: voice,
  };

  final missing = preferredVoicePresetNames
      .where((name) => !byPresetName.containsKey(name))
      .toList(growable: false);

  if (missing.isNotEmpty) {
    throw StateError(
      'Missing preferred voice preset(s): ${missing.join(', ')}.',
    );
  }

  return List<VietnameseVoice>.unmodifiable(
    preferredVoicePresetNames.map((name) => byPresetName[name]!),
  );
}

/// Returns the configured default from a curated voice list.
VietnameseVoice defaultPreferredVoice(Iterable<VietnameseVoice> voices) {
  for (final voice in voices) {
    if (voice.name == defaultPreferredVoicePresetName) {
      return voice;
    }
  }

  throw StateError(
    'Missing default voice preset "$defaultPreferredVoicePresetName".',
  );
}

/// Resolves a persisted preference against the curated catalog.
///
/// Preferences saved by older releases can refer to voices that are no longer
/// offered by the Generate tab. Those preferences are ignored and the curated
/// default is used instead. The legacy preset-name preference is still honored
/// when it maps to a curated voice.
VietnameseVoice resolvePreferredVoice({
  required VoiceCatalog catalog,
  required VietnameseVoice defaultVoice,
  String? savedStableId,
  String? legacySavedVoiceId,
}) {
  final savedStableVoice = savedStableId == null
      ? null
      : catalog.byStableId(savedStableId);

  final legacySavedVoice = legacySavedVoiceId == null
      ? null
      : catalog.byStableId(legacySavedVoiceId) ??
            catalog.byPresetName(legacySavedVoiceId);

  return savedStableVoice ?? legacySavedVoice ?? defaultVoice;
}
