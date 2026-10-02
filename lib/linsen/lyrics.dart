// Copyright 2026 MOPELotus. Linsen additions, Apache-2.0.
import '../base/services/lyric.dart';

ParsedLyrics parseTuneWeaveLyrics(
  Map<String, dynamic> data, {
  Duration? duration,
}) {
  final result = ParsedLyrics();
  final words = data['word_synced'] as String? ?? '';
  final format = data['format'] as String? ?? '';
  final line = RegExp(r'^\[(\d+),(\d+)\](.*)$');
  final yrc = RegExp(r'\((\d+),(\d+),\d+\)([^()]*)');
  final krc = RegExp(r'<(\d+),(\d+),\d+>([^<]*)');
  if (words.isNotEmpty && (format == 'yrc' || format == 'krc')) {
    for (final raw in words.split('\n')) {
      final match = line.firstMatch(raw.trim());
      if (match == null) continue;
      final start = int.parse(match[1]!);
      final tokens = <LyricToken>[];
      for (final word in (format == 'krc' ? krc : yrc).allMatches(match[3]!)) {
        final offset = int.parse(word[1]!) + (format == 'krc' ? start : 0);
        tokens.add(
          LyricToken(
            Duration(milliseconds: offset),
            word[3]!,
            Duration(milliseconds: offset + int.parse(word[2]!)),
          ),
        );
      }
      if (tokens.isNotEmpty) {
        result.lines.add(
          LyricLine(
            Duration(milliseconds: start),
            tokens.map((t) => t.text).join(),
            tokens,
          ),
        );
      }
    }
    result.isKaraoke = result.lines.any((l) => l.tokens.length > 1);
  }
  if (result.lines.isEmpty) {
    final plain = data['plain'] as String? ?? '';
    applyLrcParsing(
      result,
      plain.split('\n'),
      noLyricsMessage: '暂无歌词',
      parseFailedMessage: '暂无歌词',
      songDuration: duration,
    );
    if (plain.trim().isNotEmpty && !RegExp(r'\[\d+:\d+').hasMatch(plain)) {
      result.lines = [LyricLine(Duration.zero, plain.trim(), [])];
    }
  }
  for (final key in ['translated', 'romanized']) {
    final text = data[key] as String? ?? '';
    if (text.isEmpty) continue;
    final secondary = ParsedLyrics();
    applyLrcParsing(
      secondary,
      text.split('\n'),
      noLyricsMessage: '',
      parseFailedMessage: '',
      songDuration: duration,
    );
    for (final line in secondary.lines.where((l) => l.text.isNotEmpty)) {
      for (final primary in result.lines) {
        if (primary.start == line.start) {
          primary.translates.add(line.text);
          break;
        }
      }
    }
  }
  result.lines.sort((a, b) => a.start.compareTo(b.start));
  return result;
}
