import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:audio_tags_lofty/audio_tags_lofty.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sylvakru/base/my_audio_metadata.dart';
import 'package:sylvakru/base/services/lyric.dart';
import 'package:sylvakru/linsen/availability.dart';
import 'package:sylvakru/linsen/controller.dart';
import 'package:sylvakru/linsen/tuneweave_api.dart';

void main() {
  late HttpServer server;
  late TuneWeaveApi api;
  late LinsenController controller;
  late MyAudioMetadata song;
  late Completer<void> lyricsStarted, releaseLyrics;
  late Uri? lyricRequest;
  final media = {
    'url': 'https://audio.example/full.mp3',
    'resolved_track': 'qq:2',
    'resolved_platform': 'qq',
    'actual_quality': 'high',
    'duration_ms': 180000,
  };
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    api = TuneWeaveApi(Uri.parse('http://127.0.0.1:${server.port}'));
    controller = LinsenController()..api = api;
    controller.entries['occurrence'] = {
      'id': 'occurrence',
      'source_ref': 'netease:1',
    };
    song = MyAudioMetadata(AudioMetadata(title: 'Hello'), id: 'occurrence');
    lyricsStarted = Completer<void>();
    releaseLyrics = Completer<void>();
    lyricRequest = null;
    server.listen((request) async {
      try {
        dynamic data;
        if (request.uri.path.endsWith('/lyrics')) {
          lyricRequest = request.uri;
          lyricsStarted.complete();
          await releaseLyrics.future;
          data = {'plain': '[00:00.00]Actual recording lyrics'};
        } else {
          data = {'stream': media};
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'ok': true, 'data': data}));
        await request.response.close();
      } on IOException {
        /* A cancelled session can disconnect the mock. */
      }
    });
  });
  tearDown(() async {
    if (!releaseLyrics.isCompleted) releaseLyrics.complete();
    api.close();
    controller.dispose();
    await server.close(force: true);
  });

  test(
    'Media resolution returns before lyrics; deferred request follows actual recording',
    () async {
      final resolved = await controller
          .resolveSong(song)
          .timeout(const Duration(seconds: 2));
      expect(resolved?.reference, 'qq:2');
      expect(lyricRequest, isNull);
      expect(song.parsedLyrics!.lines.single.text, '暂无歌词');
      final loading = controller.loadSongLyrics(song, resolved!);
      await lyricsStarted.future;
      expect(song.parsedLyrics!.lines.single.text, '暂无歌词');
      expect(Uri.decodeComponent(lyricRequest!.path), '/v1/tracks/qq:2/lyrics');
      releaseLyrics.complete();
      expect(await loading, true);
      expect(song.parsedLyrics!.lines.first.text, 'Actual recording lyrics');
    },
  );

  test('A delayed lyric cannot overwrite a newer resolved recording', () async {
    final resolved = (await controller.resolveSong(song))!;
    final loading = controller.loadSongLyrics(song, resolved);
    await lyricsStarted.future;
    controller.playingMedia[song.id] = ResolvedMedia({
      ...media,
      'resolved_track': 'qq:3',
    });
    final latest = ParsedLyrics()
      ..lines.add(LyricLine(Duration.zero, 'New recording', []));
    song.parsedLyrics = latest;
    releaseLyrics.complete();
    expect(await loading, false);
    expect(identical(song.parsedLyrics, latest), true);
  });

  test(
    'Account invalidation discards deferred lyrics without replacing current metadata',
    () async {
      final resolved = (await controller.resolveSong(song))!;
      final placeholder = song.parsedLyrics;
      final loading = controller.loadSongLyrics(song, resolved);
      await lyricsStarted.future;
      api.invalidate();
      releaseLyrics.complete();
      expect(await loading, false);
      expect(identical(song.parsedLyrics, placeholder), true);
    },
  );

  test(
    'Empty optional offline lyrics retain valid audio and a safe placeholder',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'linsen-empty-lyrics-',
      );
      try {
        song.cachePath = '${directory.path}/recording.audio';
        song.cacheExist = true;
        await File(song.cachePath!).writeAsBytes([1, 2]);
        await File('${song.cachePath}.json').writeAsString(
          jsonEncode({
            ...media,
            'url': 'https://cache.invalid/local',
            'cache_size': 2,
            'lyrics': {'lines': [], 'is_karaoke': false},
          }),
        );
        expect(
          (await controller.resolveSong(song))?.url,
          'https://cache.invalid/local',
        );
        expect(song.parsedLyrics!.lines.single.text, '暂无歌词');
        expect(lyricRequest, isNull);
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
