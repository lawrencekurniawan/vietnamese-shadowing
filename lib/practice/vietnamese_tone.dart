/// The six Vietnamese tones represented by the writing system.
enum VietnameseTone { ngang, huyen, sac, hoi, nga, nang }

extension VietnameseToneDisplay on VietnameseTone {
  String get label {
    switch (this) {
      case VietnameseTone.ngang:
        return 'ngang';
      case VietnameseTone.huyen:
        return 'huyền';
      case VietnameseTone.sac:
        return 'sắc';
      case VietnameseTone.hoi:
        return 'hỏi';
      case VietnameseTone.nga:
        return 'ngã';
      case VietnameseTone.nang:
        return 'nặng';
    }
  }

  String get arrow {
    switch (this) {
      case VietnameseTone.ngang:
        return '→';
      case VietnameseTone.huyen:
        return '↘';
      case VietnameseTone.sac:
        return '↗';
      case VietnameseTone.hoi:
        return '↘↗';
      case VietnameseTone.nga:
        return '↗~';
      case VietnameseTone.nang:
        return '↘•';
    }
  }

  String get expectedContour {
    switch (this) {
      case VietnameseTone.ngang:
        return 'level';
      case VietnameseTone.huyen:
        return 'falling';
      case VietnameseTone.sac:
        return 'rising';
      case VietnameseTone.hoi:
        return 'dipping';
      case VietnameseTone.nga:
        return 'rising';
      case VietnameseTone.nang:
        return 'falling';
    }
  }
}

const Map<String, VietnameseTone> _toneCharacters = <String, VietnameseTone>{
  'à': VietnameseTone.huyen,
  'á': VietnameseTone.sac,
  'ả': VietnameseTone.hoi,
  'ã': VietnameseTone.nga,
  'ạ': VietnameseTone.nang,
  'ằ': VietnameseTone.huyen,
  'ắ': VietnameseTone.sac,
  'ẳ': VietnameseTone.hoi,
  'ẵ': VietnameseTone.nga,
  'ặ': VietnameseTone.nang,
  'ầ': VietnameseTone.huyen,
  'ấ': VietnameseTone.sac,
  'ẩ': VietnameseTone.hoi,
  'ẫ': VietnameseTone.nga,
  'ậ': VietnameseTone.nang,
  'è': VietnameseTone.huyen,
  'é': VietnameseTone.sac,
  'ẻ': VietnameseTone.hoi,
  'ẽ': VietnameseTone.nga,
  'ẹ': VietnameseTone.nang,
  'ề': VietnameseTone.huyen,
  'ế': VietnameseTone.sac,
  'ể': VietnameseTone.hoi,
  'ễ': VietnameseTone.nga,
  'ệ': VietnameseTone.nang,
  'ì': VietnameseTone.huyen,
  'í': VietnameseTone.sac,
  'ỉ': VietnameseTone.hoi,
  'ĩ': VietnameseTone.nga,
  'ị': VietnameseTone.nang,
  'ò': VietnameseTone.huyen,
  'ó': VietnameseTone.sac,
  'ỏ': VietnameseTone.hoi,
  'õ': VietnameseTone.nga,
  'ọ': VietnameseTone.nang,
  'ồ': VietnameseTone.huyen,
  'ố': VietnameseTone.sac,
  'ổ': VietnameseTone.hoi,
  'ỗ': VietnameseTone.nga,
  'ộ': VietnameseTone.nang,
  'ờ': VietnameseTone.huyen,
  'ớ': VietnameseTone.sac,
  'ở': VietnameseTone.hoi,
  'ỡ': VietnameseTone.nga,
  'ợ': VietnameseTone.nang,
  'ù': VietnameseTone.huyen,
  'ú': VietnameseTone.sac,
  'ủ': VietnameseTone.hoi,
  'ũ': VietnameseTone.nga,
  'ụ': VietnameseTone.nang,
  'ừ': VietnameseTone.huyen,
  'ứ': VietnameseTone.sac,
  'ử': VietnameseTone.hoi,
  'ữ': VietnameseTone.nga,
  'ự': VietnameseTone.nang,
  'ỳ': VietnameseTone.huyen,
  'ý': VietnameseTone.sac,
  'ỷ': VietnameseTone.hoi,
  'ỹ': VietnameseTone.nga,
  'ỵ': VietnameseTone.nang,
};

/// Returns the tone written on [token]. A syllable without a tone mark is
/// ngang.
VietnameseTone toneOf(String token) {
  for (final character in token.toLowerCase().split('')) {
    final tone = _toneCharacters[character];

    if (tone != null) {
      return tone;
    }
  }

  return VietnameseTone.ngang;
}

/// Folds Vietnamese diacritics for forgiving word matching. Tone information is
/// evaluated separately from the audio contour.
String foldVietnamese(String value) {
  var result = value.toLowerCase();

  const groups = <String, String>{
    'a': 'àáảãạăằắẳẵặâầấẩẫậ',
    'e': 'èéẻẽẹêềếểễệ',
    'i': 'ìíỉĩị',
    'o': 'òóỏõọôồốổỗộơờớởỡợ',
    'u': 'ùúủũụưừứửữự',
    'y': 'ỳýỷỹỵ',
  };

  groups.forEach((base, characters) {
    for (final character in characters.split('')) {
      result = result.replaceAll(character, base);
    }
  });

  return result.replaceAll('đ', 'd');
}
