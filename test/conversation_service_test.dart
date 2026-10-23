import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vietnamese_shadowing/conversation/conversation_service.dart';

void main() {
  test('imports a local subtitle without network or API keys', () {
    final service = ConversationService();
    final bytes = Uint8List.fromList(
      utf8.encode('''
1
00:00:01,000 --> 00:00:03,000
Chào bạn, hôm nay bạn có khỏe không?

2
00:00:03,100 --> 00:00:06,000
Mình khỏe, cảm ơn bạn rất nhiều.
'''),
    );

    final result = service.loadLocalSubtitle(
      fileName: 'Phim Việt Nam.vi.srt',
      bytes: bytes,
    );

    expect(result.isLocal, isTrue);
    expect(result.isOnline, isFalse);
    expect(result.sourceLabel, 'Imported subtitle');
    expect(result.lines, isNotEmpty);
    expect(result.lines.every((line) => line.isOnline), isFalse);
    expect(result.lines.first.sourceTitle, contains('Phim Việt Nam'));
    expect(result.lines.first.sourceDetail, contains('local file'));
    expect(result.warning, contains('Phim Việt Nam.vi.srt'));
  });

  test('rejects a local file with no usable Vietnamese dialogue', () {
    final service = ConversationService();
    final bytes = Uint8List.fromList(
      utf8.encode('''
1
00:00:01,000 --> 00:00:03,000
[MUSIC]
'''),
    );

    expect(
      () => service.loadLocalSubtitle(fileName: 'silent.srt', bytes: bytes),
      throwsA(isA<ConversationImportException>()),
    );
  });

  test('falls back to the offline pack for both online providers', () async {
    final service = ConversationService();

    final openSubtitles = await service.loadOnline(
      provider: ConversationOnlineProvider.openSubtitles,
      apiKey: '',
    );
    final subdl = await service.loadOnline(
      provider: ConversationOnlineProvider.subdl,
      apiKey: '',
    );

    expect(openSubtitles.isOnline, isFalse);
    expect(openSubtitles.lines, service.builtinLines);
    expect(openSubtitles.warning, contains('OpenSubtitles'));

    expect(subdl.isOnline, isFalse);
    expect(subdl.lines, service.builtinLines);
    expect(subdl.warning, contains('SubDL'));
  });
}
