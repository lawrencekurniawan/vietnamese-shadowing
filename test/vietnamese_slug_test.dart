import 'package:flutter_test/flutter_test.dart';
import 'package:vietnamese_shadowing/text/vietnamese_slug.dart';

void main() {
  test('folds Vietnamese diacritics and đ to ASCII', () {
    expect(foldVietnameseToAscii('Đặng Thùy Dung'), 'dang thuy dung');
    expect(foldVietnameseToAscii('Mỹ Duyên'), 'my duyen');
    expect(vietnameseSlug('Đặng Thùy Dung'), 'dang-thuy-dung');
  });

  test('uses lowercase ASCII letters, digits, and single hyphens', () {
    expect(
      vietnameseSlug('  Xin chào, thế giới! 2026  '),
      'xin-chao-the-gioi-2026',
    );
    expect(vietnameseSlug('A---B___C'), 'a-b-c');
  });

  test('falls back to audio when no usable characters remain', () {
    expect(vietnameseSlug('!!! 😀 ...'), 'audio');
    expect(vietnameseSlug('---'), 'audio');
    expect(vietnameseSlug('', fallback: 'untitled'), 'untitled');
  });

  test('truncates to the requested length without a trailing hyphen', () {
    final longText = List<String>.filled(70, 'a').join();

    expect(
      vietnameseSlug(longText, maxLength: 60),
      List<String>.filled(60, 'a').join(),
    );
    expect(vietnameseSlug('ab cde', maxLength: 3), 'ab');
    expect(vietnameseSlug('abc def', maxLength: 2), 'ab');
  });

  test('removes path separators and traversal-like input', () {
    expect(vietnameseSlug('../../etc/passwd'), 'etc-passwd');
    expect(vietnameseSlug(r'..\..\windows\system32'), 'windows-system32');
  });

  test('rejects a non-positive maximum length', () {
    expect(() => vietnameseSlug('text', maxLength: 0), throwsArgumentError);
  });
}
