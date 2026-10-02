import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sylvakru/linsen/android_export.dart';
import 'package:sylvakru/linsen/tuneweave_api.dart';

void main() {
  late Directory directory;
  late File recording;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('linsen-document-test-');
    recording = await File(
      '${directory.path}/Hello.mp3',
    ).writeAsBytes([1, 2, 3]);
  });
  tearDown(() async => directory.delete(recursive: true));

  test(
    'System save uses media name and streams the local file to the granted URI',
    () async {
      final calls = <String>[];
      final exporter = AndroidDocumentExporter(
        transport: (method, arguments) async {
          calls.add(method);
          if (method == 'pickSave') {
            expect(arguments, {
              'fileName': 'Hello.mp3',
              'mimeType': 'audio/mpeg',
            });
            return 'content://documents/new-song';
          }
          expect(arguments, {
            'sourcePath': recording.path,
            'uri': 'content://documents/new-song',
          });
          return true;
        },
      );
      expect(await exporter.save(recording, validSession: () => true), true);
      expect(calls, ['pickSave', 'copyToUri']);
      expect(await recording.readAsBytes(), [1, 2, 3]);
    },
  );

  test(
    'Account switching while the picker is open discards the new document before any copy',
    () async {
      var valid = true;
      final selected = Completer<Object?>(), opened = Completer<void>();
      final calls = <String>[];
      final exporter = AndroidDocumentExporter(
        transport: (method, arguments) async {
          calls.add(method);
          if (method == 'pickSave') {
            opened.complete();
            return selected.future;
          }
          expect(method, 'discardUri');
          expect(arguments['uri'], 'content://documents/new-song');
          return null;
        },
      );
      final operation = exporter.save(recording, validSession: () => valid);
      final checked = expectLater(
        operation,
        throwsA(
          isA<TuneWeaveException>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      await opened.future;
      valid = false;
      selected.complete('content://documents/new-song');
      await checked;
      expect(calls, ['pickSave', 'discardUri']);
    },
  );

  test(
    'Cancelling the picker writes nothing; invalid grants never reach native copying',
    () async {
      var grants = 0;
      final cancelled = AndroidDocumentExporter(
        transport: (method, arguments) async {
          expect(method, 'pickSave');
          grants++;
          return null;
        },
      );
      expect(await cancelled.save(recording, validSession: () => true), false);
      expect(grants, 1);
      final invalid = AndroidDocumentExporter(
        transport: (method, arguments) async {
          expect(method, 'pickSave');
          return 'file:///arbitrary-path';
        },
      );
      await expectLater(
        invalid.save(recording, validSession: () => true),
        throwsA(isA<TuneWeaveException>()),
      );
      expect(await recording.readAsBytes(), [1, 2, 3]);
    },
  );
}
