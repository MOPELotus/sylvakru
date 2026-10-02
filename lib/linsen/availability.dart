// Copyright 2026 MOPELotus. Linsen additions, Apache-2.0.
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'tuneweave_api.dart';

enum Playability { unknown, resolving, playable, trial, unavailable }

class ResolvedMedia {
  final Map<String, dynamic> raw;
  ResolvedMedia(this.raw) {
    final uri = Uri.tryParse(raw['url'] as String? ?? '');
    if (uri == null ||
        !const {'https', 'http'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw const TuneWeaveException('invalid_response', '播放地址无效');
    }
  }
  String get url => raw['url'] as String;
  String get reference =>
      raw['resolved_track'] as String? ?? raw['track_ref'] as String? ?? '';
  String get platform =>
      raw['resolved_platform'] as String? ?? reference.split(':').first;
  String get quality => raw['actual_quality'] as String? ?? 'auto';
  int? get bitrate => (raw['bitrate'] as num?)?.toInt();
  int? get durationMs => (raw['duration_ms'] as num?)?.toInt();
  bool get isTrial => raw['trial'] != null;
  Map<String, String> get headers => (raw['headers'] as Map? ?? {}).map(
    (key, value) => MapEntry('$key', '$value'),
  );
  List<String> get backupUrls =>
      List<String>.from(raw['backup_urls'] as List? ?? []);
  DateTime? get expiresAt =>
      DateTime.tryParse(raw['expires_at'] as String? ?? '');
}

class AvailabilityState {
  Playability status = Playability.unknown;
  String? message;
  ResolvedMedia? media;
  DateTime? checkedAt;
  bool get grey => status == Playability.unavailable;
}

/// At most two concurrent full resolver requests; original-platform flags are ignored.
class AvailabilityResolver extends ChangeNotifier {
  final Future<ResolvedMedia> Function(String key) resolve;
  final DateTime Function() now;
  final Map<String, AvailabilityState> _states = {};
  final Map<String, Future<ResolvedMedia>> _pending = {};
  final List<Completer<void>> _waiters = [];
  int _active = 0;
  int _generation = 0;
  AvailabilityResolver(this.resolve, {DateTime Function()? clock})
    : now = clock ?? DateTime.now;
  AvailabilityState state(String key) {
    final result = _states.putIfAbsent(key, AvailabilityState.new);
    final checked = result.checkedAt;
    final ttl = result.grey
        ? const Duration(minutes: 2)
        : const Duration(minutes: 10);
    if (checked != null &&
        (now().difference(checked) >= ttl ||
            (result.media?.expiresAt?.isBefore(
                  now().add(const Duration(seconds: 15)),
                ) ??
                false))) {
      result.status = Playability.unknown;
      result.media = null;
      result.checkedAt = null;
    }
    return result;
  }

  Future<ResolvedMedia> check(String key, {bool refresh = false}) {
    final cached = state(key);
    if (!refresh && cached.media != null) return Future.value(cached.media);
    if (_pending[key] case final future?) return future;
    final epoch = _generation;
    final future = _check(key, epoch);
    _pending[key] = future;
    unawaited(
      future.then<void>(
        (_) {
          if (epoch == _generation) _pending.remove(key);
        },
        onError: (Object _, StackTrace _) {
          if (epoch == _generation) _pending.remove(key);
        },
      ),
    );
    return future;
  }

  Future<ResolvedMedia> _check(String key, int epoch) async {
    if (_active >= 2) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    } else {
      _active++;
    }
    try {
      if (epoch != _generation) {
        throw const TuneWeaveException('cancelled', '解析已取消');
      }
      final entry = state(key)..status = Playability.resolving;
      notifyListeners();
      final media = await resolve(key);
      if (epoch != _generation) {
        throw const TuneWeaveException('cancelled', '解析已取消');
      }
      entry.media = media;
      entry.message = null;
      entry.checkedAt = now();
      entry.status = media.isTrial ? Playability.trial : Playability.playable;
      return media;
    } on TuneWeaveException catch (error) {
      if (epoch == _generation) {
        final entry = state(key);
        entry.media = null;
        entry.message = error.message;
        // Only a complete, affirmative no-source result may grey a row.
        final attempts = error.details['attempts'] as List?;
        final exhausted =
            attempts != null &&
            attempts.isNotEmpty &&
            attempts.every(
              (a) =>
                  a is Map &&
                  const {
                    'no_match',
                    'unavailable',
                    'permission_denied',
                  }.contains(a['status']),
            );
        entry.status = error.code == 'no_playable_source' || exhausted
            ? Playability.unavailable
            : Playability.unknown;
        entry.checkedAt = entry.grey ? now() : null;
      }
      rethrow;
    } finally {
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete();
      } else {
        _active--;
      }
      notifyListeners();
    }
  }

  void invalidate() {
    _generation++;
    _states.clear();
    _pending.clear();
    notifyListeners();
  }
}
