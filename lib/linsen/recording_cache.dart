// Copyright 2026 MOPELotus. Linsen additions, Apache-2.0.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The manifest is the commit marker. Partial downloads are never playable.
class RecordingCache {
  final Map<String, Future<void>> _operations = {};
  final Map<String, Future<void>> _downloads = {};
  int generation = 0;
  Future<void>? _clearing;

  Future<void> downloadOnce(String path, Future<void> Function() action) {
    if (_clearing != null) return Future<void>.value();
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
    Map<String, dynamic> manifest, {
    int? expectedGeneration,
  }) => _serial(path, () async {
    if (expectedGeneration != null && expectedGeneration != generation) return;
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

  /// Counts occupied disk space, including orphaned recordings, but excludes
  /// unfinished transfers. Listing races with a completed download are harmless.
  Future<int> size(Directory directory) async {
    if (!await directory.exists()) return 0;
    var bytes = 0;
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is File && !entry.path.endsWith('.part')) {
        try {
          bytes += await entry.length();
        } on FileSystemException {
          // Another operation may have removed this file after listing it.
        }
      }
    }
    return bytes;
  }

  Future<void> clear(Directory directory) {
    if (_clearing case final pending?) return pending;
    generation++;
    final result = _clear(directory);
    _clearing = result;
    unawaited(
      result.then<void>(
        (_) => _clearing = null,
        onError: (Object _, StackTrace _) => _clearing = null,
      ),
    );
    return result;
  }

  Future<void> _clear(Directory directory) async {
    final paths = <String>{..._downloads.keys, ..._operations.keys};
    if (await directory.exists()) {
      await for (final entry in directory.list(followLinks: false)) {
        if (entry is! File) continue;
        final name = entry.path;
        if (name.endsWith('.audio')) paths.add(name);
        if (name.endsWith('.audio.json')) {
          paths.add(name.substring(0, name.length - 5));
        }
        if (name.endsWith('.audio.part')) {
          paths.add(name.substring(0, name.length - 5));
        }
        if (name.endsWith('.audio.json.part')) {
          paths.add(name.substring(0, name.length - 10));
        }
      }
    }
    Object? failure;
    // Serialized against publication: a download committed just before clearing
    // is removed; one finishing afterwards has an obsolete generation ticket.
    for (final path in paths) {
      try {
        await invalidate(path);
        if (!_downloads.containsKey(path)) {
          for (final file in [File('$path.part'), File('$path.json.part')]) {
            if (await file.exists()) await file.delete();
          }
        }
      } on FileSystemException catch (error) {
        failure ??= error;
      }
    }
    if (failure != null) throw failure;
  }
}
