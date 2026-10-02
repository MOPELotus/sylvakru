import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sylvakru/linsen/recording_cache.dart';

void main() {
  late Directory directory;
  late RecordingCache cache;
  late String path;
  Map<String, dynamic> manifest(String source) => {
    'url': 'https://cache.invalid/local',
    'resolved_track': source,
    'resolved_platform': source.split(':').first,
    'actual_quality': 'high',
    'bitrate': 320000,
    'duration_ms': 180000,
    'lyrics': {'is_karaoke': false, 'lines': []},
  };
  Future<File> download(List<int> bytes) async =>
      File('$path.part').writeAsBytes(bytes, flush: true);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('linsen-cache-test-');
    path = '${directory.path}/recording.audio';
    cache = RecordingCache();
  });
  tearDown(() async => directory.delete(recursive: true));

  test(
    'Published pair preserves actual source and detects later truncation',
    () async {
      await cache.publish(path, await download([1, 2, 3, 4]), manifest('qq:1'));
      final result = await cache.read(path);
      expect(result?['resolved_track'], 'qq:1');
      expect(result?['cache_size'], 4);
      await File(path).writeAsBytes([1, 2]);
      expect(await cache.read(path), isNull);
    },
  );

  test(
    'Crash leftovers and missing or malformed manifests stay uncommitted',
    () async {
      await download([1, 2, 3]);
      expect(await cache.read(path), isNull);
      await File(path).writeAsBytes([1, 2, 3]);
      expect(await cache.read(path), isNull);
      for (final contents in [
        '{broken',
        '[]',
        '{"url": "https://audio.example/"}',
      ]) {
        await File('$path.json').writeAsString(contents);
        expect(await cache.read(path), isNull);
      }
    },
  );

  test(
    'Old full cache remains usable; trial, empty and mistyped metadata do not',
    () async {
      await File(path).writeAsBytes([1, 2, 3]);
      await File('$path.json').writeAsString(jsonEncode(manifest('netease:1')));
      expect(await cache.read(path), isNotNull);
      for (final changes in [
        {
          'trial': {'end_ms': 30000},
        },
        {'bitrate': '320000'},
        {'duration_ms': []},
        {'cache_size': 5},
      ]) {
        await File(
          '$path.json',
        ).writeAsString(jsonEncode({...manifest('netease:1'), ...changes}));
        expect(await cache.read(path), isNull);
      }
      await File('$path.json').writeAsString(jsonEncode(manifest('netease:1')));
      await File(path).writeAsBytes([]);
      expect(await cache.read(path), isNull);
    },
  );

  test(
    'Duplicate queue occurrences share one download and a later retry is allowed',
    () async {
      final gate = Completer<void>();
      var requests = 0;
      Future<void> action() async {
        requests++;
        await gate.future;
      }

      final first = cache.downloadOnce(path, action);
      final second = cache.downloadOnce(path, action);
      expect(identical(first, second), true);
      expect(requests, 1);
      gate.complete();
      await Future.wait([first, second]);
      await cache.downloadOnce(path, () async {
        requests++;
      });
      expect(requests, 2);
    },
  );

  test('Failed shared download releases ownership for a retry', () async {
    final gate = Completer<void>();
    final first = cache.downloadOnce(path, () => gate.future);
    final second = cache.downloadOnce(
      path,
      () async => fail('duplicate download'),
    );
    final checked = Future.wait([
      expectLater(first, throwsA(isA<IOException>())),
      expectLater(second, throwsA(isA<IOException>())),
    ]);
    gate.completeError(const FileSystemException('interrupted'));
    await checked;
    await cache.downloadOnce(path, () async {});
  });

  test(
    'Replacement publishes current source; invalidation keeps an active partial',
    () async {
      await cache.publish(path, await download([1, 2]), manifest('qq:1'));
      await cache.publish(
        path,
        await download([3, 4, 5]),
        manifest('netease:2'),
      );
      expect((await cache.read(path))?['resolved_track'], 'netease:2');
      await download([9]);
      await cache.invalidate(path);
      expect(await cache.read(path), isNull);
      expect(await File(path).exists(), false);
      expect(await File('$path.json').exists(), false);
      expect(await File('$path.part').readAsBytes(), [9]);
    },
  );

  test(
    'An empty or trial publication cannot replace a committed full recording',
    () async {
      await cache.publish(path, await download([1]), manifest('qq:1'));
      await expectLater(
        cache.publish(path, await download([]), manifest('qq:2')),
        throwsFormatException,
      );
      await expectLater(
        cache.publish(path, await download([2]), {
          ...manifest('qq:2'),
          'trial': {},
        }),
        throwsFormatException,
      );
      expect((await cache.read(path))?['resolved_track'], 'qq:1');
    },
  );
}
