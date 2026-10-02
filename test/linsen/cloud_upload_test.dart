import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sylvakru/linsen/cloud_upload.dart';
import 'package:sylvakru/linsen/tuneweave_api.dart';

class TransferApi extends TuneWeaveApi {
  final String storage;
  int publishes = 0, advances = 0;
  bool ready = false, losePublish = false;
  TransferApi(this.storage) : super(Uri.parse('http://127.0.0.1')) {
    credentials['netease'] = 'private-session';
  }
  Map<String, dynamic> get transfer => {
    'transfer_id': '1',
    'state': ready ? 'ready_to_publish' : 'transferring',
    'file_size': 4,
    'offset': ready ? 4 : 0,
    'step': {
      'step_id': 'step1',
      'kind': 'upload',
      'method': 'PUT',
      'url': storage,
      'offset': 0,
      'length': 4,
      'headers': {},
    },
  };
  @override
  Future<dynamic> data(
    String method,
    String path, {
    Map<String, dynamic> query = const {},
    Object? body,
    bool authenticated = true,
  }) async {
    if (path.endsWith('/advance')) {
      advances++;
      ready = true;
      throw const TuneWeaveException('transport_error', 'advance reply lost');
    }
    if (path.endsWith('/complete')) {
      publishes++;
      if (losePublish) {
        throw const TuneWeaveException('transport_error', 'publish reply lost');
      }
      return {};
    }
    return transfer;
  }
}

void main() {
  test(
    'Lost advance response probes server state instead of replaying storage write',
    () async {
      final dir = await Directory.systemTemp.createTemp('linsen-upload-');
      final file = File('${dir.path}/song.mp3');
      await file.writeAsBytes([1, 2, 3, 4]);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var writes = 0;
      final subscription = server.listen((request) async {
        writes++;
        expect(request.headers['x-tuneweave-credential'], isNull);
        expect(await request.fold<List<int>>([], (a, b) => a..addAll(b)), [
          1,
          2,
          3,
          4,
        ]);
        request.response.write('ok');
        await request.response.close();
      });
      final api = TransferApi('http://127.0.0.1:${server.port}/storage');
      final upload = CloudUpload(api, file);
      await upload.run();
      expect(upload.published, false);
      await upload.run();
      expect(upload.published, true);
      expect(writes, 1);
      expect(api.advances, 1);
      expect(api.publishes, 1);
      api.close();
      await subscription.cancel();
      await server.close(force: true);
      await dir.delete(recursive: true);
    },
  );
  test(
    'Unconfirmed publication stays uncertain and is never retried',
    () async {
      final dir = await Directory.systemTemp.createTemp('linsen-upload-');
      final file = File('${dir.path}/song.mp3');
      await file.writeAsBytes([1, 2, 3, 4]);
      final api = TransferApi('https://storage.example')
        ..ready = true
        ..losePublish = true;
      final upload = CloudUpload(api, file);
      await upload.run();
      await upload.run();
      expect(upload.uncertain, true);
      expect(api.publishes, 1);
      api.close();
      await dir.delete(recursive: true);
    },
  );
}
