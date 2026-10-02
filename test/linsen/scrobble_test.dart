import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sylvakru/linsen/scrobble.dart';
import 'package:sylvakru/linsen/availability.dart';
import 'package:sylvakru/linsen/tuneweave_api.dart';

class FakeApi extends TuneWeaveApi {
  final sent = <Map<String, dynamic>>[];
  bool uncertain = false;
  FakeApi() : super(Uri.parse('http://127.0.0.1')) {
    credentials['netease'] = 'session';
  }
  @override
  Future<dynamic> data(
    String method,
    String path, {
    Map<String, dynamic> query = const {},
    Object? body,
    bool authenticated = true,
  }) async {
    sent.add(Map<String, dynamic>.from(body as Map));
    if (uncertain) {
      throw const TuneWeaveException('transport_error', 'reply lost');
    }
    return {'accepted': true};
  }
}

void main() {
  test(
    'Only actual NetEase sources report; pauses excluded and delivery stays bounded',
    () async {
      final dir = await Directory.systemTemp.createTemp('linsen-outbox-');
      final api = FakeApi();
      final outbox = ScrobbleOutbox(
        file: File('${dir.path}/outbox.json'),
        api: () => api,
        account: () async => 'account1',
        enabled: () => true,
      );
      final media = ResolvedMedia({
        'url': 'https://audio.example/a',
        'resolved_platform': 'netease',
        'resolved_track': 'netease:1',
        'actual_quality': 'high',
        'bitrate': 320000,
      });
      await outbox.start(media, 5);
      outbox.playing(true);
      await Future<void>.delayed(const Duration(milliseconds: 15));
      outbox.playing(false);
      await outbox.finish();
      await outbox.drain();
      expect(api.sent.single['played_ms'], 5);
      expect(outbox.tasks.single['state'], 'sent');
      await outbox.start(
        ResolvedMedia({
          ...media.raw,
          'resolved_platform': 'qq',
          'resolved_track': 'qq:1',
        }),
        5,
      );
      expect(outbox.session, isNull);
      api.close();
      await dir.delete(recursive: true);
    },
  );
  test(
    'Uncertain sends are never automatically replayed; original account is retained',
    () async {
      final dir = await Directory.systemTemp.createTemp('linsen-outbox-');
      final file = File('${dir.path}/tasks.json');
      await file.writeAsString(
        jsonEncode([
          {
            'id': 'a',
            'state': 'sending',
            'account': 'a',
            'ref': 'netease:1',
            'body': {},
          },
          {
            'id': 'b',
            'state': 'pending',
            'account': 'b',
            'ref': 'netease:2',
            'body': {},
          },
        ]),
      );
      final api = FakeApi();
      final outbox = ScrobbleOutbox(
        file: file,
        api: () => api,
        account: () async => 'a',
        enabled: () => true,
      );
      await outbox.initialize();
      await outbox.drain();
      expect(outbox.tasks[0]['state'], 'uncertain');
      expect(outbox.tasks[1]['state'], 'pending');
      expect(api.sent, isEmpty);
      api.close();
      await dir.delete(recursive: true);
    },
  );
}
