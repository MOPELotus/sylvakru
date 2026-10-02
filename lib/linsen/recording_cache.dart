// Copyright 2026 MOPELotus. Linsen additions, Apache-2.0.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The manifest is the commit marker. Partial downloads are never playable.
class RecordingCache {
  final Map<String, Future<void>> _operations = {};
  final Map<String, Future<void>> _downloads = {};

  Future<void> downloadOnce(String path, Future<void> Function() action) {
    if (_downloads[path] case final pending?) return pending;
    final operation = Future<void>.sync(action);
    _downloads[path] = operation;
    void release() {
      if (identical(_downloads[path], operation)) _downloads.remove(path);
    }

    unawaited(
      operation.then<void>(
        (_) => release(),
        onError: (Object _, StackTrace _) => release(),
      ),
    );
    return operation;
  }

  Future<T> _serial<T>(String path, Future<T> Function() action) {
    final previous = _operations[path] ?? Future<void>.value();
    final result = previous.then((_) => action());
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _operations[path] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_operations[path], tail)) _operations.remove(path);
      }),
    );
    return result;
  }

  Future<Map<String, dynamic>?> read(String path) => _serial(path, () async {
    try {
      final audio = File(path);
      final metadata = File('$path.json');
      if (!await audio.exists() || !await metadata.exists()) return null;
      final length = await audio.length();
      if (length == 0) return null;
      final raw = jsonDecode(await metadata.readAsString());
      if (raw is! Map) return null;
      final manifest = Map<String, dynamic>.from(raw);
      if (manifest['url'] != 'https://cache.invalid/local' ||
          manifest['resolved_track'] is! String ||
          manifest['resolved_platform'] is! String ||
          manifest['actual_quality'] is! String ||
          manifest['trial'] != null ||
          (manifest['bitrate'] != null && manifest['bitrate'] is! num) ||
          (manifest['duration_ms'] != null &&
              manifest['duration_ms'] is! num) ||
          (manifest['cache_size'] != null &&
              manifest['cache_size'] != length)) {
        return null;
      }
      return manifest;
    } on Object {
      // Missing, interrupted and malformed caches all fall back to resolution.
      return null;
    }
  });

  Future<void> invalidate(String path) => _serial(path, () async {
    // Remove the commit marker first. Leave in-flight .part files to their owner.
    for (final file in [File('$path.json'), File(path)]) {
      if (await file.exists()) await file.delete();
    }
  });

  Future<void> publish(
    String path,
    File downloaded,
    Map<String, dynamic> manifest,
  ) => _serial(path, () async {
    final length = await downloaded.length();
    if (length == 0 || manifest['trial'] != null) {
      throw const FormatException(
        'Only complete, full recordings can be cached',
      );
    }
    final metadata = File('$path.json');
    final temporaryMetadata = File('$path.json.part');
    await temporaryMetadata.writeAsString(
      jsonEncode({...manifest, 'cache_size': length}),
      flush: true,
    );
    try {
      if (await metadata.exists()) await metadata.delete();
      final audio = File(path);
      if (await audio.exists()) await audio.delete();
      await downloaded.rename(path);
      // Also works on Windows, where rename cannot replace an existing file.
      await temporaryMetadata.rename(metadata.path);
    } finally {
      if (await temporaryMetadata.exists()) await temporaryMetadata.delete();
    }
  });
}
