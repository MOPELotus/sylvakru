// Copyright 2026 MOPELotus. Linsen additions, Apache-2.0.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'availability.dart';
import 'tuneweave_api.dart';

/// Each opening is a separate listen; monotonic time excludes pause, buffering and seek.
class ListenSession {
  final ResolvedMedia media;
  final String account;
  final int durationMs;
  final Stopwatch clock = Stopwatch();
  ListenSession(this.media, this.account, this.durationMs);
  void playing(bool value) {
    if (value) {
      clock.start();
    } else {
      clock.stop();
    }
  }

  int get playedMs => clock.elapsedMilliseconds.clamp(0, durationMs);
}

class ScrobbleOutbox {
  final File file;
  final TuneWeaveApi? Function() api;
  final Future<String?> Function() account;
  final bool Function() enabled;
  ListenSession? session;
  bool suspended = false;
  int _sessionGeneration = 0;
  final List<Map<String, dynamic>> tasks = [];
  Future<void> _tail = Future.value();
  bool _sending = false;
  Future<void>? _drainFuture;
  ScrobbleOutbox({
    required this.file,
    required this.api,
    required this.account,
    required this.enabled,
  });

  Future<void> initialize() async {
    if (await file.exists()) {
      tasks.addAll(
        (jsonDecode(await file.readAsString()) as List).map(
          (e) => Map<String, dynamic>.from(e as Map),
        ),
      );
      for (final task in tasks) {
        if (task['state'] == 'sending') task['state'] = 'uncertain';
      }
      await save();
    }
    unawaited(drain());
  }

  Future<void> start(ResolvedMedia? media, int? durationMs) async {
    await finish();
    final generation = _sessionGeneration;
    if (suspended ||
        !enabled() ||
        media == null ||
        media.platform != 'netease' ||
        !media.reference.startsWith('netease:') ||
        media.bitrate == null ||
        media.bitrate! <= 0 ||
        durationMs == null ||
        durationMs <= 0 ||
        !const {
          'standard',
          'high',
          'lossless',
          'hires',
          'higher',
          'surround',
          'spatial',
          'dolby',
          'master',
          'vivid',
        }.contains(media.quality)) {
      return;
    }
    final owner = await account();
    if (owner != null && !suspended && generation == _sessionGeneration) {
      session = ListenSession(media, owner, durationMs);
    }
  }

  void playing(bool value) => session?.playing(value);
  Future<void> finish() async {
    _sessionGeneration++;
    final listen = session;
    session = null;
    if (listen == null) return;
    listen.playing(false);
    if (listen.playedMs == 0) return;
    tasks.add({
      'id': '${DateTime.now().microsecondsSinceEpoch}-${tasks.length}',
      'state': 'pending',
      'account': listen.account,
      'ref': listen.media.reference,
      'body': {
        'played_ms': listen.playedMs,
        'duration_ms': listen.durationMs,
        'bitrate': listen.media.bitrate,
        'quality': listen.media.quality,
      },
    });
    await save();
    unawaited(drain());
  }

  Future<void> save() {
    final content = jsonEncode(tasks);
    _tail = _tail.catchError((Object _) {}).then((_) async {
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(content, flush: true);
      if (Platform.isWindows && await file.exists()) await file.delete();
      await temporary.rename(file.path);
    });
    return _tail;
  }

  Future<void> drain() => _drainFuture ??= _drain().whenComplete(() {
    _drainFuture = null;
  });

  Future<void> _drain() async {
    if (_sending || suspended || !enabled()) return;
    _sending = true;
    try {
      for (final task in tasks.where((t) => t['state'] == 'pending').toList()) {
        if (suspended) break;
        final client = api();
        if (client == null ||
            client.credentials['netease'] == null ||
            await account() != task['account']) {
          continue;
        }
        final epoch = client.generation;
        final credential = client.credentials['netease'];
        if (suspended) break;
        // Persist before sending: after a crash or timeout we cannot know delivery.
        task['state'] = 'sending';
        await save();
        if (suspended ||
            epoch != client.generation ||
            credential != client.credentials['netease']) {
          task['state'] = 'pending';
          await save();
          continue;
        }
        try {
          final response = await client.data(
            'POST',
            '/v1/tracks/${Uri.encodeComponent(task['ref'] as String)}/scrobble',
            query: {'platform': 'netease'},
            body: task['body'],
          );
          task['state'] = response['accepted'] == true ? 'sent' : 'uncertain';
        } on TuneWeaveException catch (error) {
          task['state'] =
              error.details['delivery_may_have_occurred'] == false &&
                  error.details['start_accepted'] != true
              ? 'pending'
              : 'uncertain';
        } catch (_) {
          task['state'] = 'uncertain';
        }
        await save();
      }
    } finally {
      _sending = false;
    }
  }
}

/// Identity survives credential rotations, but a new login gets a new identity.
Future<String?> neteaseAccountIdentity(TuneWeaveApi? client) async {
  if (client?.credentials['netease'] == null) return null;
  const secure = FlutterSecureStorage();
  var identity = await secure.read(key: 'linsen.netease.identity');
  if (identity == null) {
    identity = sha256
        .convert(
          utf8.encode(
            '${DateTime.now().microsecondsSinceEpoch}:${client!.credentials['netease']}',
          ),
        )
        .toString();
    await secure.write(key: 'linsen.netease.identity', value: identity);
  }
  return identity;
}
