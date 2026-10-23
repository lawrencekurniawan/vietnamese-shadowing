import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vietnamese_shadowing/conversation/subtitle_parser.dart';

void main() {
  const parser = SubtitleParser();

  test('parses SRT cues and removes markup', () {
    final bytes = Uint8List.fromList(
      utf8.encode('''
1
00:00:01,000 --> 00:00:03,000
<i>Chào bạn</i>, hôm nay bạn có khỏe không?

2
00:00:03,100 --> 00:00:05,200
{\\an8}Mình khỏe, cảm ơn bạn rất nhiều.

3
00:00:05,300 --> 00:00:07,000
[MUSIC]

4
00:00:07,100 --> 00:00:09,000
JOHN: THIS IS ALL CAPS
'''),
    );

    final result = parser.parse(bytes, fileName: 'movie.srt');

    expect(result.format, 'srt');
    expect(result.cues, hasLength(2));
    expect(result.cues.first.text, contains('Chào bạn'));
    expect(result.cues.first.text, isNot(contains('<i>')));
    expect(result.cues[1].text, isNot(contains('{\\an8}')));
  });

  test('strips uppercase Vietnamese speaker labels', () {
    final bytes = Uint8List.fromList(
      utf8.encode('''
1
00:00:01,000 --> 00:00:03,000
LÂM: Chào bạn, hôm nay trời đẹp quá.

2
00:00:03,100 --> 00:00:05,000
Nam: Mình muốn đi cà phê một chút.
'''),
    );

    final result = parser.parse(bytes, fileName: 'speakers.srt');

    expect(result.cues.first.text, 'Chào bạn, hôm nay trời đẹp quá.');
    expect(result.cues.last.text, 'Mình muốn đi cà phê một chút.');
  });

  test('keeps short dialogue cues for later passage assembly', () {
    final bytes = Uint8List.fromList(
      utf8.encode('''
1
00:00:01,000 --> 00:00:02,000
Đi thôi.

2
00:00:02,100 --> 00:00:03,000
Không sao đâu.
'''),
    );

    final result = parser.parse(bytes, fileName: 'short.srt');

    expect(result.cues, hasLength(2));
    expect(result.cues.first.text, 'Đi thôi.');
    expect(result.cues.last.text, 'Không sao đâu.');
  });

  test('keeps one-mark interjections for later passage assembly', () {
    final bytes = Uint8List.fromList(
      utf8.encode('''
1
00:00:01,000 --> 00:00:02,000
Không.

2
00:00:02,100 --> 00:00:04,000
Mình hiểu rồi, cảm ơn bạn.
'''),
    );

    final result = parser.parse(bytes, fileName: 'short.srt');

    expect(result.cues.first.text, 'Không.');
    expect(parser.extractPassages(result.cues), isNotEmpty);
  });

  test('combines short cues into a valid passage', () {
    const cues = <SubtitleCue>[
      SubtitleCue(startSeconds: 1, endSeconds: 2, text: 'Đi thôi.'),
      SubtitleCue(startSeconds: 2.1, endSeconds: 3, text: 'Không sao đâu.'),
      SubtitleCue(
        startSeconds: 3.1,
        endSeconds: 5,
        text: 'Mình đi cà phê nhé.',
      ),
    ];

    final passages = parser.extractPassages(cues);

    expect(passages, isNotEmpty);
    expect(
      passages.any(
        (passage) =>
            passage.text.contains('Đi thôi') &&
            passage.text.contains('Không sao đâu') &&
            passage.text.contains('Mình đi cà phê'),
      ),
      isTrue,
    );
  });

  test('combines adjacent cues into a short passage', () {
    const cues = <SubtitleCue>[
      SubtitleCue(
        startSeconds: 1,
        endSeconds: 3,
        text: 'Chào bạn, hôm nay bạn có khỏe không?',
      ),
      SubtitleCue(
        startSeconds: 3.1,
        endSeconds: 5,
        text: 'Mình khỏe, cảm ơn bạn rất nhiều.',
      ),
      SubtitleCue(startSeconds: 5.1, endSeconds: 6, text: '[MUSIC]'),
      SubtitleCue(startSeconds: 8, endSeconds: 10, text: 'toi di hoc moi ngay'),
    ];

    final passages = parser.extractPassages(cues);

    expect(passages, isNotEmpty);
    expect(
      passages.any(
        (passage) =>
            passage.text.contains('Chào bạn') &&
            passage.text.contains('Mình khỏe'),
      ),
      isTrue,
    );
    expect(passages.any((passage) => passage.text.contains('MUSIC')), isFalse);
    expect(
      passages.any((passage) => passage.text.contains('toi di hoc')),
      isFalse,
    );
  });

  test('rejects unaccented, all-caps, and URL text', () {
    expect(parser.cleanCueText('toi di hoc moi ngay'), isNull);
    expect(parser.cleanCueText('THIS IS A LONG ALL CAPS LINE'), isNull);
    expect(
      parser.cleanCueText('Xem thêm tại https://example.com ngay bây giờ'),
      isNull,
    );
  });

  test('parses WebVTT with dotted timestamps', () {
    final bytes = Uint8List.fromList(
      utf8.encode('''
WEBVTT

00:00:01.000 --> 00:00:03.000
Chào bạn, hôm nay trời đẹp quá.

00:00:03.100 --> 00:00:05.000
Mình muốn đi cà phê một chút.
'''),
    );

    final result = parser.parse(bytes, fileName: 'movie.vtt');

    expect(result.format, 'vtt');
    expect(result.cues, hasLength(2));
    expect(result.cues.last.startSeconds, closeTo(3.1, 0.001));
  });

  test('parses ASS dialogue text', () {
    final bytes = Uint8List.fromList(
      utf8.encode('''
[Script Info]
Title: Test

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\\i1}Chào bạn, hôm nay bạn khỏe không?
Dialogue: 0,0:00:03.10,0:00:05.00,Default,,0,0,0,,Mình khỏe, cảm ơn bạn.
'''),
    );

    final result = parser.parse(bytes, fileName: 'movie.ass');

    expect(result.format, 'ass');
    expect(result.cues, hasLength(2));
    expect(result.cues.first.text, contains('Chào bạn'));
    expect(result.cues.first.text, isNot(contains('{\\i1}')));
  });

  test('unwraps ZIP-wrapped subtitle downloads', () {
    final archive = Archive()
      ..add(
        ArchiveFile.string('movie.vi.srt', '''
1
00:00:01,000 --> 00:00:03,000
Chào bạn, hôm nay bạn có khỏe không?

2
00:00:03,100 --> 00:00:05,000
Mình khỏe, cảm ơn bạn rất nhiều.
'''),
      );
    final zip = ZipEncoder().encodeBytes(archive);

    final result = parser.parse(zip, fileName: 'download.zip');

    expect(result.format, 'srt');
    expect(result.fileName, 'movie.vi.srt');
    expect(result.cues, hasLength(2));
  });
}
