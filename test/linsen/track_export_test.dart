import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sylvakru/linsen/track_export.dart';
import 'package:sylvakru/linsen/tuneweave_api.dart';

void main() {
  late Directory directory;
  late HttpServer server;
  late TuneWeaveApi api;
  late TrackExporter exporter;
  late Future<void> Function(HttpRequest) transfer;
  late Map<String, dynamic> grant;
  late List<Uri> authorizations;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('linsen-export-test-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    api = TuneWeaveApi(Uri.parse('http://127.0.0.1:${server.port}'));
    exporter = TrackExporter();
    authorizations = [];
    grant = {
      'available': true,
      'url': 'http://127.0.0.1:${server.port}/audio',
      'format': 'flac',
      'size': 4,
      'headers': {'X-Media-Token': 'recording'},
    };
    transfer = (request) async {
      expect(request.headers.value('X-Media-Token'), 'recording');
      request.response.add([1, 2, 3, 4]);
      await request.response.close();
    };
    server.listen((request) async {
      try {
        if (request.uri.path == '/audio') {
          await transfer(request);
        } else {
          authorizations.add(request.uri);
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'ok': true, 'data': grant}));
          await request.response.close();
        }
      } on IOException {
        // Cancelled clients can disconnect while this mock is writing.
      }
    });
  });
  tearDown(() async {
    api.close();
    await server.close(force: true);
    await directory.delete(recursive: true);
  });
  Future<File?> export({
    bool cloud = false,
    String title = 'Hello',
    int? generation,
    Future<bool> Function()? confirm,
  }) => exporter.export(
    api: api,
    generation: generation ?? api.generation,
    reference: 'netease:123',
    cloud: cloud,
    preferredPlatform: 'qq',
    directory: directory,
    title: title,
    confirmOverwrite: confirm ?? () async => true,
  );

  test(
    'Authorized export sends fallback, unblock and preference, preserving media headers',
    () async {
      final file = await export();
      expect(await file!.readAsBytes(), [1, 2, 3, 4]);
      expect(authorizations.single.queryParameters, {
        'quality': 'auto',
        'fallback': 'true',
        'unblock': 'true',
        'playback_platform': 'qq',
      });
      expect(
        Uri.decodeComponent(authorizations.single.path),
        '/v1/tracks/netease:123/download',
      );
      expect(await directory.list().length, 1);
    },
  );

  test(
    'Cloud export uses its account download contract without stream parameters',
    () async {
      final file = await export(cloud: true, title: 'CON');
      expect(file!.path.endsWith('/_CON.flac'), true);
      expect(
        Uri.decodeComponent(authorizations.single.path),
        '/v1/account/cloud/tracks/netease:123/download',
      );
      expect(authorizations.single.query, isEmpty);
    },
  );

  test(
    'Cancelled session cannot authorize or replace an existing file',
    () async {
      final ticket = api.generation;
      api.invalidate();
      await expectLater(
        export(generation: ticket),
        throwsA(isA<TuneWeaveException>()),
      );
      expect(authorizations, isEmpty);
      final old = await File('${directory.path}/Hello.flac').writeAsBytes([9]);
      await expectLater(
        export(
          confirm: () async {
            api.invalidate();
            return true;
          },
        ),
        throwsA(isA<TuneWeaveException>()),
      );
      expect(await old.readAsBytes(), [9]);
      expect(await directory.list().length, 1);
    },
  );

  test(
    'Same destination is locked while transferring; cancellation leaves old file intact',
    () async {
      final old = await File('${directory.path}/Hello.flac').writeAsBytes([9]);
      final started = Completer<void>(), finish = Completer<void>();
      transfer = (request) async {
        request.response.add([1, 2]);
        await request.response.flush();
        started.complete();
        await finish.future;
        request.response.add([3, 4]);
        await request.response.close();
      };
      final first = export();
      await started.future;
      await expectLater(
        export(),
        throwsA(
          isA<TuneWeaveException>().having((e) => e.code, 'code', 'conflict'),
        ),
      );
      final checked = expectLater(
        first,
        throwsA(
          isA<TuneWeaveException>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      api.invalidate();
      finish.complete();
      await checked;
      expect(await old.readAsBytes(), [9]);
      expect(await directory.list().length, 1);
      transfer = (request) async {
        request.response.add([1, 2, 3, 4]);
        await request.response.close();
      };
      await export();
      expect(await old.readAsBytes(), [1, 2, 3, 4]);
    },
  );

  test(
    'Empty, truncated or unavailable grants cannot overwrite a user file',
    () async {
      final old = await File('${directory.path}/Hello.flac').writeAsBytes([9]);
      for (final body in [
        <int>[],
        [1, 2],
      ]) {
        transfer = (request) async {
          request.response.add(body);
          await request.response.close();
        };
        await expectLater(export(), throwsA(isA<TuneWeaveException>()));
        expect(await old.readAsBytes(), [9]);
        expect(await directory.list().length, 1);
      }
      grant['available'] = false;
      await expectLater(export(), throwsA(isA<TuneWeaveException>()));
      expect(await old.readAsBytes(), [9]);
    },
  );

  test(
    'User edits during transfer are preserved and overwrite cancellation creates no partial',
    () async {
      final old = await File('${directory.path}/Hello.flac').writeAsBytes([9]);
      await expectLater(export(confirm: () async => false), completion(isNull));
      expect(await directory.list().length, 1);
      transfer = (request) async {
        await old.writeAsBytes([8, 8]);
        request.response.add([1, 2, 3, 4]);
        await request.response.close();
      };
      await expectLater(
        export(),
        throwsA(
          isA<TuneWeaveException>().having((e) => e.code, 'code', 'conflict'),
        ),
      );
      expect(await old.readAsBytes(), [8, 8]);
      expect(await directory.list().length, 1);
    },
  );
  test(
    'A same-name directory is preserved and cannot be replaced with a recording',
    () async {
      final folder = await Directory('${directory.path}/Hello.flac').create();
      final original = await File(
        '${folder.path}/keep.txt',
      ).writeAsString('keep');
      await expectLater(
        export(confirm: () async => fail('directory overwrite prompt')),
        throwsA(
          isA<TuneWeaveException>().having((e) => e.code, 'code', 'conflict'),
        ),
      );
      expect(await original.readAsString(), 'keep');
      expect(await directory.list().length, 1);
    },
  );
}
