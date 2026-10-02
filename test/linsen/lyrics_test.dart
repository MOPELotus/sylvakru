import 'package:flutter_test/flutter_test.dart';
import 'package:sylvakru/linsen/lyrics.dart';

void main() {
  test('QRC XML word times use the actual recording timeline', () {
    final result = parseTuneWeaveLyrics({
      'format': 'qrc',
      'word_synced':
          '<QrcInfos><Lyric_1 LyricContent="[1000,1200]你(1000,500)好(1500,700)"/></QrcInfos>',
    });
    expect(result.lines.single.text, '你好');
    expect(result.lines.single.tokens.last.start.inMilliseconds, 1500);
    expect(result.lines.single.tokens.last.end!.inMilliseconds, 2200);
  });
  test('YRC absolute word time, translations and romanization', () {
    final result = parseTuneWeaveLyrics({
      'format': 'yrc',
      'word_synced': '[1000,2000](1000,500,0)你(1500,800,0)好',
      'translated': '[00:01.000]Hello',
      'romanized': '[00:01.000]ni hao',
    });
    expect(result.isKaraoke, true);
    expect(result.lines.single.text, '你好');
    expect(result.lines.single.tokens[1].start.inMilliseconds, 1500);
    expect(result.lines.single.translates, ['Hello', 'ni hao']);
  });
  test('KRC relative word time and plain fallback', () {
    final result = parseTuneWeaveLyrics({
      'format': 'krc',
      'word_synced': '[5000,1000]<0,300,0>你<300,500,0>好',
    });
    expect(result.lines.single.tokens[1].start.inMilliseconds, 5300);
    expect(
      parseTuneWeaveLyrics({'plain': 'Hello\nworld'}).lines.single.text,
      'Hello\nworld',
    );
  });
}
