/// Folds Vietnamese (and common Latin) diacritics to plain ASCII and builds
/// safe, lowercase, hyphen-separated slugs.
///
/// This is intentionally pure Dart so it can be reused by voice identity,
/// WAV export naming, and tests without loading Flutter assets or native code.
library;

const Map<String, String> _asciiFolds = <String, String>{
  // Vietnamese a
  'à': 'a',
  'á': 'a',
  'ạ': 'a',
  'ả': 'a',
  'ã': 'a',
  'â': 'a',
  'ầ': 'a',
  'ấ': 'a',
  'ậ': 'a',
  'ẩ': 'a',
  'ẫ': 'a',
  'ă': 'a',
  'ằ': 'a',
  'ắ': 'a',
  'ặ': 'a',
  'ẳ': 'a',
  'ẵ': 'a',
  // Vietnamese e
  'è': 'e',
  'é': 'e',
  'ẹ': 'e',
  'ẻ': 'e',
  'ẽ': 'e',
  'ê': 'e',
  'ề': 'e',
  'ế': 'e',
  'ệ': 'e',
  'ể': 'e',
  'ễ': 'e',
  // Vietnamese i
  'ì': 'i',
  'í': 'i',
  'ị': 'i',
  'ỉ': 'i',
  'ĩ': 'i',
  // Vietnamese o
  'ò': 'o',
  'ó': 'o',
  'ọ': 'o',
  'ỏ': 'o',
  'õ': 'o',
  'ô': 'o',
  'ồ': 'o',
  'ố': 'o',
  'ộ': 'o',
  'ổ': 'o',
  'ỗ': 'o',
  'ơ': 'o',
  'ờ': 'o',
  'ớ': 'o',
  'ợ': 'o',
  'ở': 'o',
  'ỡ': 'o',
  // Vietnamese u
  'ù': 'u',
  'ú': 'u',
  'ụ': 'u',
  'ủ': 'u',
  'ũ': 'u',
  'ư': 'u',
  'ừ': 'u',
  'ứ': 'u',
  'ự': 'u',
  'ử': 'u',
  'ữ': 'u',
  // Vietnamese y
  'ỳ': 'y',
  'ý': 'y',
  'ỵ': 'y',
  'ỷ': 'y',
  'ỹ': 'y',
  // Vietnamese d
  'đ': 'd',
  // Common non-Vietnamese Latin letters that may appear in user text.
  'ä': 'a',
  'å': 'a',
  'æ': 'ae',
  'ç': 'c',
  'ë': 'e',
  'î': 'i',
  'ï': 'i',
  'ñ': 'n',
  'ö': 'o',
  'ø': 'o',
  'œ': 'oe',
  'ß': 'ss',
  'ü': 'u',
  'ÿ': 'y',
};

/// Converts diacritics and `đ`/`Đ` to ASCII without changing word boundaries.
String foldVietnameseToAscii(String input) {
  final lower = input.toLowerCase();
  final buffer = StringBuffer();

  for (final rune in lower.runes) {
    final character = String.fromCharCode(rune);
    buffer.write(_asciiFolds[character] ?? character);
  }

  // Handle decomposed input such as "e" followed by a combining acute accent.
  return buffer.toString().replaceAll(RegExp(r'[\u0300-\u036f]'), '');
}

/// Builds a filename-safe slug using lowercase ASCII letters, digits, and
/// single hyphens.
///
/// The result is at most [maxLength] characters and never starts or ends with a
/// hyphen. If the input contains no usable characters, [fallback] is used after
/// applying the same normalization rules.
String vietnameseSlug(
  String input, {
  int maxLength = 60,
  String fallback = 'audio',
}) {
  if (maxLength < 1) {
    throw ArgumentError.value(maxLength, 'maxLength', 'must be at least 1');
  }

  final slug = _compactSlug(input);

  if (slug.isNotEmpty) {
    return _truncateSlug(slug, maxLength);
  }

  return _truncateSlug(_compactSlug(fallback), maxLength);
}

String _compactSlug(String input) {
  return foldVietnameseToAscii(input)
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'-+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
}

String _truncateSlug(String slug, int maxLength) {
  if (slug.length <= maxLength) {
    return slug;
  }

  return slug.substring(0, maxLength).replaceAll(RegExp(r'-+$'), '');
}
