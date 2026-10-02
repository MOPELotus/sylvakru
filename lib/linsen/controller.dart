// Copyright 2026 MOPELotus. Linsen additions, Apache-2.0.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:audio_tags_lofty/audio_tags_lofty.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../base/app.dart';
import '../base/data/library.dart';
import '../base/my_audio_metadata.dart';
import '../base/services/lyric.dart';
import '../base/services/picture_service.dart';
import 'availability.dart';
import 'runtime.dart';
import 'scrobble.dart';
import 'lyrics.dart';
import 'recording_cache.dart';
import 'tuneweave_api.dart';

final linsen = LinsenController();
const platformNames = <String, String>{
  'all': '全部平台',
  'netease': '网易云',
  'qq': 'QQ音乐',
  'kugou': '酷狗',
  'kuwo': '酷我',
  'migu': '咪咕',
  'soda': '汽水',
  'bilibili': '哔哩哔哩',
  'local': '本地',
};

class LinsenController extends ChangeNotifier {
  TuneWeaveApi? api;
  late final availability = AvailabilityResolver(_resolve);
  final Map<String, Map<String, dynamic>> entries = {};
  final Map<String, ResolvedMedia> playingMedia = {};
  final _recordings = RecordingCache();
  final _cacheClients = <HttpClient>{};
  Directory get _cacheDirectory =>
      Directory('${appSupportDir.path}/linsen/cache');

  Future<int> recordingCacheSize() => _recordings.size(_cacheDirectory);

  Future<void> clearRecordingCache() async {
    // Cancellation happens synchronously before any filesystem await.
    final cleared = _recordings.clear(_cacheDirectory);
    for (final client in _cacheClients) {
      client.close(force: true);
    }
    availability.invalidate();
    for (final song in library.id2Song.values) {
      if (isOnline(song)) song.cacheExist = false;
    }
    await cleared;
  }

  late final outbox = ScrobbleOutbox(
    file: File('${appSupportDir.path}/linsen/scrobbles.json'),
    api: () => api,
    account: () => neteaseAccountIdentity(api),
    enabled: () => scrobbleEnabled,
  );
  final _secure = const FlutterSecureStorage();
  String? problem;
  String? remoteEndpoint;
  String playbackPlatform = 'auto';
  bool scrobbleEnabled = true;
  Future<void> _writeTail = Future.value();
  File get _file => File('${appSupportDir.path}/linsen/client.json');

  Future<void> initialize() async {
    try {
      if (await _file.exists()) {
        final data = jsonDecode(await _file.readAsString()) as Map;
        remoteEndpoint = data['remote_endpoint'] as String?;
        playbackPlatform = data['playback_platform'] as String? ?? 'auto';
        scrobbleEnabled = data['scrobble_enabled'] != false;
        for (final item in data['entries'] as List? ?? []) {
          final entry = Map<String, dynamic>.from(item as Map);
          entries[entry['id'] as String] = entry;
        }
      }
      await connect(remoteEndpoint);
    } catch (_) {
      problem = '音乐服务启动失败，请在账号与服务中检查配置';
    }
    await outbox.initialize();
    restoreEntries();
    notifyListeners();
  }

  Future<void> connect(String? remote) async {
    Uri endpoint;
    String? token;
    if (remote == null || remote.trim().isEmpty) {
      final runtime = await TuneWeaveRuntime.start(
        '${appSupportDir.path}/linsen/runtime',
      );
      endpoint = Uri.parse(runtime['endpoint'] as String);
      token = runtime['token'] as String;
      remote = null;
    } else {
      endpoint = Uri.parse(remote.trim());
      if (!const {'http', 'https'}.contains(endpoint.scheme) ||
          endpoint.host.isEmpty ||
          endpoint.userInfo.isNotEmpty ||
          endpoint.hasQuery ||
          endpoint.hasFragment) {
        throw const TuneWeaveException('invalid_request', '请输入完整 HTTP(S) 服务地址');
      }
    }
    final next = TuneWeaveApi(
      endpoint,
      runtimeToken: token,
      saveCredential: (platform, value) async {
        if (value == null) {
          await _secure.delete(key: 'linsen.$platform');
          availability.invalidate();
        } else {
          await _secure.write(key: 'linsen.$platform', value: value);
        }
        notifyListeners();
      },
    );
    for (final platform in platformNames.keys.where(
      (p) => p != 'all' && p != 'local',
    )) {
      final value = await _secure.read(key: 'linsen.$platform');
      if (value != null) next.credentials[platform] = value;
    }
    try {
      await next.data('GET', '/healthz', authenticated: false);
    } catch (_) {
      next.close();
      rethrow;
    }
    api?.close();
    api = next;
    remoteEndpoint = remote;
    problem = null;
    availability.invalidate();
    await persist();
    notifyListeners();
  }

  Future<void> persist() {
    final content = jsonEncode({
      'remote_endpoint': remoteEndpoint,
      'playback_platform': playbackPlatform,
      'scrobble_enabled': scrobbleEnabled,
      'entries': entries.values.toList(),
    });
    _writeTail = _writeTail.catchError((Object _) {}).then((_) async {
      await _file.parent.create(recursive: true);
      final temporary = File('${_file.path}.tmp');
      await temporary.writeAsString(content, flush: true);
      if (Platform.isWindows && await _file.exists()) await _file.delete();
      await temporary.rename(_file.path);
    });
    return _writeTail;
  }

  TuneWeaveApi get service =>
      api ?? (throw const TuneWeaveException('service_unavailable', '音乐服务未连接'));
  bool isOnline(MyAudioMetadata song) => entries.containsKey(song.id);
  void restoreEntries() {
    for (final entry in entries.values) {
      _register(entry);
    }
  }

  MyAudioMetadata _register(Map<String, dynamic> entry) {
    final snapshot = entry['snapshot'] as Map? ?? {};
    final song = MyAudioMetadata(
      AudioMetadata(
        title: snapshot['title'] as String? ?? '未命名歌曲',
        artist: (snapshot['artists'] as List? ?? []).join('/'),
        album: snapshot['album'] as String?,
        duration: snapshot['duration_ms'] == null
            ? null
            : Duration(milliseconds: (snapshot['duration_ms'] as num).toInt()),
      ),
      id: entry['id'] as String,
      path: entry['source_ref'] as String,
    );
    song.picture = MyPicture.form(snapshot['cover_url'] as String? ?? '');
    final cacheIdentity = entry['cloud'] == true
        ? '${entry['account_identity']}:${entry['source_ref']}'
        : entry['source_ref'] as String;
    final hash = sha256.convert(utf8.encode(cacheIdentity));
    song.cachePath = '${appSupportDir.path}/linsen/cache/$hash.audio';
    song.cacheExist =
        File(song.cachePath!).existsSync() &&
        File('${song.cachePath}.json').existsSync();
    library.id2Song[song.id] = song;
    return song;
  }

  Future<MyAudioMetadata> materialize(
    Map<String, dynamic> track, {
    bool cloud = false,
  }) async {
    final reference = track['ref'] as String;
    if (cloud) {
      // Cloud identity is account-private and must never be replaced by matched_track_ref.
      final owner = await neteaseAccountIdentity(api);
      if (owner == null) {
        throw const TuneWeaveException('authentication_required', '请登录网易云云盘账号');
      }
      final id = 'cloud:$owner:$reference';
      final entry = <String, dynamic>{
        'id': id,
        'source_ref': reference,
        'cloud': true,
        'account_identity': owner,
        'snapshot': {
          'title': track['name'],
          'artists': (track['artists'] as List? ?? [])
              .map((e) => e['name'])
              .toList(),
          'album': (track['album'] as Map?)?['name'],
          'duration_ms': track['duration_ms'],
        },
      };
      entries[id] = entry;
      await persist();
      return _register(entry);
    }
    final result = await service.data(
      'POST',
      '/v1/uni/materialize/items',
      body: {
        'items': [
          {'ref': reference, 'kind': 'track'},
        ],
      },
    );
    final entry = Map<String, dynamic>.from(
      (result['items'] as List).single as Map,
    );
    entries[entry['id'] as String] = entry;
    await persist();
    return _register(entry);
  }

  Future<ResolvedMedia> _resolve(String key) async {
    final entry = entries[key];
    if (entry == null) {
      for (final candidate in entries.values) {
        if (candidate['source_ref'] != key) continue;
        final cached = library.id2Song[candidate['id']];
        if (cached != null && cached.cacheExist && candidate['cloud'] != true) {
          final manifest = await _recordings.read(cached.cachePath!);
          if (manifest != null) return ResolvedMedia(manifest);
          _setCacheFlags(cached.cachePath!, false);
        }
      }
      final data = await service.data(
        'GET',
        '/v1/tracks/${Uri.encodeComponent(key)}/stream',
        query: {
          'quality': 'auto',
          'fallback': true,
          'unblock': true,
          if (playbackPlatform != 'auto') 'playback_platform': playbackPlatform,
        },
      );
      return ResolvedMedia(Map<String, dynamic>.from(data as Map));
    }
    if (entry['cloud'] == true) {
      if (entry['account_identity'] != await neteaseAccountIdentity(api)) {
        throw const TuneWeaveException(
          'authentication_required',
          '该云盘歌曲属于另一账号',
        );
      }
      final data = await service.data(
        'GET',
        '/v1/account/cloud/tracks/${Uri.encodeComponent(entry['source_ref'] as String)}/download',
      );
      return ResolvedMedia(Map<String, dynamic>.from(data as Map));
    }
    final data = await service.data(
      'POST',
      '/v1/uni/items/stream',
      body: {
        'item': entry,
        'quality': 'auto',
        'fallback': true,
        'unblock': true,
        if (playbackPlatform != 'auto') 'playback_platform': playbackPlatform,
      },
    );
    return ResolvedMedia(Map<String, dynamic>.from(data['stream'] as Map));
  }

  Future<ResolvedMedia?> resolveSong(
    MyAudioMetadata song, {
    bool refresh = false,
  }) async {
    if (!isOnline(song)) return null;
    if (song.cacheExist && !refresh) {
      if (entries[song.id]?['cloud'] == true &&
          entries[song.id]?['account_identity'] !=
              await neteaseAccountIdentity(api)) {
        throw const TuneWeaveException(
          'authentication_required',
          '该云盘缓存属于另一账号',
        );
      }
      final raw = await _recordings.read(song.cachePath!);
      if (raw != null) {
        song.parsedLyrics = null;
        if (raw['lyrics'] is Map) {
          try {
            final lyrics = raw['lyrics'] as Map;
            final parsed = ParsedLyrics();
            parsed.isKaraoke = lyrics['is_karaoke'] == true;
            parsed.lines = (lyrics['lines'] as List)
                .map((line) => LyricLine.fromMap(line as Map))
                .toList();
            song.parsedLyrics = parsed;
          } catch (_) {
            // Invalid optional lyrics must not hide a valid offline recording.
          }
        }
        if (song.parsedLyrics == null || song.parsedLyrics!.lines.isEmpty) {
          song.parsedLyrics = _emptyLyrics();
        }
        playingMedia[song.id] = ResolvedMedia(raw);
        return playingMedia[song.id];
      }
      await invalidateCachedSong(song);
    }
    final media = await availability.check(song.id, refresh: refresh);
    playingMedia[song.id] = media;
    song.parsedLyrics = _emptyLyrics();
    notifyListeners();
    return media;
  }

  ParsedLyrics _emptyLyrics() =>
      ParsedLyrics()..lines.add(LyricLine(Duration.zero, '暂无歌词', []));

  Future<bool> loadSongLyrics(MyAudioMetadata song, ResolvedMedia media) async {
    final client = service;
    final generation = client.generation;
    final parsed = await _lyricsFor(song, media, client: client);
    if (!identical(api, client) ||
        client.generation != generation ||
        !identical(playingMedia[song.id], media)) {
      return false;
    }
    song.parsedLyrics = parsed;
    notifyListeners();
    return true;
  }

  // Fetch lyrics for the actual resolved recording, never for an unrelated origin.
  Future<ParsedLyrics> _lyricsFor(
    MyAudioMetadata song,
    ResolvedMedia media, {
    TuneWeaveApi? client,
  }) async {
    client ??= service;
    ParsedLyrics? parsed;
    try {
      dynamic data;
      if (entries[song.id]?['cloud'] == true) {
        final profile = await client.data(
          'GET',
          '/v1/account/profile',
          query: {'platform': 'netease'},
        );
        final uid = (profile['user']['ref'] as String)
            .split(':')
            .skip(1)
            .join(':');
        final sid = (entries[song.id]!['source_ref'] as String)
            .split(':')
            .skip(1)
            .join(':');
        data = await client.data(
          'GET',
          '/v1/account/cloud/lyrics',
          query: {'platform': 'netease', 'uid': uid, 'sid': sid},
        );
      } else if (media.reference.isNotEmpty) {
        data = await client.data(
          'GET',
          '/v1/tracks/${Uri.encodeComponent(media.reference)}/lyrics',
        );
      }
      if (data is Map) {
        parsed = parseTuneWeaveLyrics(
          Map<String, dynamic>.from(data),
          duration: media.durationMs == null
              ? song.duration
              : Duration(milliseconds: media.durationMs!),
        );
      }
    } catch (_) {
      /* Lyrics failure must not prevent playback. */
    }
    return parsed == null || parsed.lines.isEmpty ? _emptyLyrics() : parsed;
  }

  void _setCacheFlags(String path, bool exists) {
    for (final candidate in library.id2Song.values) {
      if (candidate.cachePath == path && isOnline(candidate)) {
        candidate.cacheExist = exists;
      }
    }
  }

  Future<void> invalidateCachedSong(MyAudioMetadata song) async {
    final path = song.cachePath;
    if (!isOnline(song) || path == null) return;
    _setCacheFlags(path, false);
    availability.invalidate();
    try {
      await _recordings.invalidate(path);
    } catch (_) {
      // A locked file must not prevent trying an online replacement.
    } finally {
      await library.refreshCacheSize();
    }
  }

  Future<void> cacheSong(MyAudioMetadata song) {
    if (!isOnline(song) || song.cachePath == null) return Future<void>.value();
    return _recordings.downloadOnce(song.cachePath!, () => _cacheSong(song));
  }

  Future<void> _cacheSong(MyAudioMetadata song) async {
    final path = song.cachePath!;
    final cacheGeneration = _recordings.generation;
    if (await _recordings.read(path) != null) {
      if (cacheGeneration == _recordings.generation) _setCacheFlags(path, true);
      return;
    }
    _setCacheFlags(path, false);
    final temporary = File('$path.part');
    final client = service;
    final generation = client.generation;
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    _cacheClients.add(http);
    bool cancelled() =>
        generation != client.generation ||
        cacheGeneration != _recordings.generation;
    try {
      final media = await availability.check(song.id);
      if (media.isTrial) return;
      final parsed = await _lyricsFor(song, media, client: client);
      if (cancelled()) return;
      await temporary.parent.create(recursive: true);
      // No other in-process download owns this path; reclaim crash leftovers.
      if (await temporary.exists()) await temporary.delete();
      await temporary.create(exclusive: true);
      final request = await http.getUrl(Uri.parse(media.url));
      request.followRedirects = false;
      for (final header in media.headers.entries) {
        request.headers.set(header.key, header.value);
      }
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != 200) return;
      final sink = temporary.openWrite();
      try {
        await for (final bytes in response.timeout(
          const Duration(seconds: 30),
        )) {
          if (cancelled()) {
            throw const TuneWeaveException('cancelled', '缓存已取消');
          }
          sink.add(bytes);
        }
      } finally {
        await sink.close();
      }
      if (cancelled() || await temporary.length() == 0) {
        return;
      }
      final manifest = <String, dynamic>{
        'url': 'https://cache.invalid/local',
        'resolved_track': media.reference,
        'resolved_platform': media.platform,
        'actual_quality': media.quality,
        'bitrate': media.bitrate,
        'duration_ms': media.durationMs,
        'lyrics': {
          'is_karaoke': parsed.isKaraoke,
          'lines': parsed.lines.map((line) => line.toMap()).toList(),
        },
        if (media.isTrial) 'trial': media.raw['trial'],
      };
      await _recordings.publish(
        path,
        temporary,
        manifest,
        expectedGeneration: cacheGeneration,
      );
      if (!cancelled()) _setCacheFlags(path, true);
    } catch (_) {
      /* A cache failure does not interrupt playback. */
    } finally {
      http.close(force: true);
      _cacheClients.remove(http);
      if (await temporary.exists()) await temporary.delete();
      await library.refreshCacheSize();
    }
  }

  Future<void> prepareLogin(String platform) async {
    if (platform == 'netease') {
      outbox.suspended = true;
      await outbox.finish();
      await _secure.delete(key: 'linsen.netease.identity');
    }
    service.invalidate();
  }

  Future<void> completeLogin(String platform) async {
    if (platform == 'netease') {
      outbox.suspended = true;
      await outbox.finish();
      await _secure.delete(key: 'linsen.netease.identity');
      outbox.suspended = false;
    }
    service.invalidate();
    availability.invalidate();
    notifyListeners();
  }

  Future<void> logout(String platform) async {
    if (platform == 'netease') {
      outbox.suspended = true;
      await outbox.finish();
    }
    service.invalidate();
    service.credentials.remove(platform);
    await _secure.delete(key: 'linsen.$platform');
    if (platform == 'netease') {
      await _secure.delete(key: 'linsen.netease.identity');
    }
    availability.invalidate();
    notifyListeners();
  }

  Future<void> importCookie(String platform, String value) async {
    await prepareLogin(platform);
    await service.data(
      'POST',
      '/v1/auth/import',
      authenticated: false,
      body: {
        'platform': platform,
        'credential_mode': 'client',
        'credential': {'kind': 'cookie', 'value': value},
      },
    );
    await completeLogin(platform);
  }

  Future<void> setPlaybackPlatform(String value) async {
    playbackPlatform = value;
    availability.invalidate();
    await persist();
    notifyListeners();
  }
}
