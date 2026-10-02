import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sylvakru/linsen/tuneweave_api.dart';

void main() {
  test(
    'Repeated credentials and runtime authentication; rotation on errors',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final api = TuneWeaveApi(
        Uri.parse('http://127.0.0.1:${server.port}'),
        runtimeToken: 'device-secret',
      );
      api.credentials.addAll({'netease': 'old-n', 'qq': 'old-q'});
      final served = server.first.then((request) async {
        expect(request.headers['x-tuneweave-credential'], ['old-n', 'old-q']);
        expect(
          request.headers.value('x-linsen-runtime-token'),
          'device-secret',
        );
        request.response.headers.set(
          'X-TuneWeave-Updated-Credential',
          'netease=new-n',
        );
        request.response.write(
          jsonEncode({
            'ok': false,
            'error': {'code': 'rate_limited', 'message': 'later'},
          }),
        );
        await request.response.close();
      });
      await expectLater(
        api.request('GET', '/v1/search', query: {'q': 'a'}),
        throwsA(isA<TuneWeaveException>()),
      );
      expect(api.credentials['netease'], 'new-n');
      await served;
      api.close();
      await server.close(force: true);
    },
  );
  test(
    'Changing backend/account cancels old result and rejects stale credentials',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final api = TuneWeaveApi(Uri.parse('http://127.0.0.1:${server.port}'));
      final request = api.request('GET', '/v1/platforms');
      final expectation = expectLater(
        request,
        throwsA(isA<TuneWeaveException>()),
      );
      final incoming = await server.first;
      api.invalidate();
      incoming.response.write(
        jsonEncode({
          'ok': true,
          'data': {},
          'meta': {
            'caller_credential': {'platform': 'netease', 'value': 'stale'},
          },
        }),
      );
      await incoming.response.close();
      await expectation;
      expect(api.credentials, isEmpty);
      api.close();
      await server.close(force: true);
    },
  );
}
