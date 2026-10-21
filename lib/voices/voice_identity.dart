import '../native/vieneu_ffi.dart';

/// Maximum length of the voice component in generated filenames and portable
/// metadata.
const int maxStableVoiceIdLength = 32;

/// Frozen stable IDs for the voices in the shipped VieNeu catalog.
///
/// The native preset/display name remains the synthesis lookup key. Stable IDs
/// are the portable identity used by settings, the future library, and
/// `.vshadow` packages.
///
/// Do not derive these IDs from list position. If a catalog voice is renamed in
/// the future, keep its old ID here as an alias rather than changing the value.
const Map<String, String> stableVoiceIdsByPresetName = <String, String>{
  'Minh Đức': 'minh-duc',
  'Phạm Tuyên': 'pham-tuyen',
  'Thái Sơn': 'thai-son',
  'Xuân Vĩnh': 'xuan-vinh',
  'Thanh Bình': 'thanh-binh',
  'Trúc Ly': 'truc-ly',
  'Ngọc Linh': 'ngoc-linh',
  'Đoan Trang': 'doan-trang',
  'Mai Anh': 'mai-anh',
  'Thục Đoan': 'thuc-doan',
  'Minh Triết': 'minh-triet',
  'Thùy Dung': 'thuy-dung',
  'Quang Sơn': 'quang-son',
  'Ngọc Trân': 'ngoc-tran',
  'Mỹ Duyên': 'my-duyen',
  'Quỳnh Anh': 'quynh-anh',
  'Đức Trí': 'duc-tri',
  'Kim Thanh': 'kim-thanh',
  'Ngọc Huyền': 'ngoc-huyen',
  'Adam': 'adam',
};

/// A stable voice ID paired with the native preset name used for synthesis.
class VoiceIdentity {
  const VoiceIdentity({required this.stableId, required this.presetName});

  final String stableId;
  final String presetName;

  /// Returns `null` when this native preset has no registered stable ID.
  static VoiceIdentity? tryFromPresetName(String presetName) {
    final stableId = stableVoiceIdsByPresetName[presetName];

    if (stableId == null || !isValidStableVoiceId(stableId)) {
      return null;
    }

    return VoiceIdentity(stableId: stableId, presetName: presetName);
  }

  /// Returns `null` for an unknown or malformed stable ID.
  static VoiceIdentity? tryFromStableId(String stableId) {
    if (!isValidStableVoiceId(stableId)) {
      return null;
    }

    for (final entry in stableVoiceIdsByPresetName.entries) {
      if (entry.value == stableId) {
        return VoiceIdentity(stableId: entry.value, presetName: entry.key);
      }
    }

    return null;
  }

  @override
  bool operator ==(Object other) {
    return other is VoiceIdentity &&
        other.stableId == stableId &&
        other.presetName == presetName;
  }

  @override
  int get hashCode => Object.hash(stableId, presetName);

  @override
  String toString() => 'VoiceIdentity($stableId -> $presetName)';
}

/// Stable identity for a voice returned by the native engine.
extension VietnameseVoiceIdentity on VietnameseVoice {
  VoiceIdentity get voiceIdentity {
    final identity = VoiceIdentity.tryFromPresetName(name);

    if (identity == null) {
      throw StateError(
        'No stable voice ID is registered for native preset "$name".',
      );
    }

    return identity;
  }

  String get stableId => voiceIdentity.stableId;
}

/// Builds a validated, immutable view of the voices returned by the native
/// engine and provides safe stable-ID lookup.
class VoiceCatalog {
  VoiceCatalog._(this._voices, this._byStableId, this._byPresetName);

  factory VoiceCatalog.fromVoices(Iterable<VietnameseVoice> voices) {
    final voiceList = voices.toList(growable: false);
    final byStableId = <String, VietnameseVoice>{};
    final byPresetName = <String, VietnameseVoice>{};

    for (final voice in voiceList) {
      final identity = VoiceIdentity.tryFromPresetName(voice.name);

      if (identity == null) {
        throw StateError(
          'No stable voice ID is registered for native preset "${voice.name}".',
        );
      }

      if (byStableId.containsKey(identity.stableId)) {
        throw StateError(
          'Duplicate stable voice ID "${identity.stableId}" in the native '
          'voice catalog.',
        );
      }

      if (byPresetName.containsKey(voice.name)) {
        throw StateError(
          'Duplicate native voice preset "${voice.name}" in the native voice '
          'catalog.',
        );
      }

      byStableId[identity.stableId] = voice;
      byPresetName[voice.name] = voice;
    }

    return VoiceCatalog._(
      List<VietnameseVoice>.unmodifiable(voiceList),
      Map<String, VietnameseVoice>.unmodifiable(byStableId),
      Map<String, VietnameseVoice>.unmodifiable(byPresetName),
    );
  }

  final List<VietnameseVoice> _voices;
  final Map<String, VietnameseVoice> _byStableId;
  final Map<String, VietnameseVoice> _byPresetName;

  List<VietnameseVoice> get voices => _voices;

  VietnameseVoice? byStableId(String stableId) => _byStableId[stableId];

  VietnameseVoice? byPresetName(String presetName) => _byPresetName[presetName];

  VoiceIdentity? identityForStableId(String stableId) =>
      VoiceIdentity.tryFromStableId(stableId);
}

/// True when [value] is a lowercase, hyphen-separated stable voice ID of a
/// permitted length.
bool isValidStableVoiceId(String value) {
  return value.length <= maxStableVoiceIdLength &&
      RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(value);
}

/// The existing display ordering: accent (Bắc → Nam → Trung), then gender, then
/// display name. Extracted so the behavior can be tested independently.
int compareVoicesForDisplay(VietnameseVoice a, VietnameseVoice b) {
  final accentComparison = a.accent.toLowerCase().compareTo(
    b.accent.toLowerCase(),
  );

  if (accentComparison != 0) {
    return accentComparison;
  }

  final genderComparison = a.gender.toLowerCase().compareTo(
    b.gender.toLowerCase(),
  );

  if (genderComparison != 0) {
    return genderComparison;
  }

  return a.name.toLowerCase().compareTo(b.name.toLowerCase());
}
