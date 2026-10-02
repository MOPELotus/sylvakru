import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:sylvakru/linsen/availability.dart';
import 'package:sylvakru/linsen/tuneweave_api.dart';

ResolvedMedia media({bool trial = false}) => ResolvedMedia({
  'url': 'https://audio.example/song',
  'resolved_platform': 'qq',
  'resolved_track': 'qq:1',
  if (trial) 'trial': {'end_ms': 30000},
});
void main() {
  test('Exhausted chains with transport failures stay unknown', () async {
    final resolver = AvailabilityResolver((_) async {
      throw const TuneWeaveException('no_playable_source', 'unresolved', {
        'attempts': [
          {'status': 'unavailable'},
          {'status': 'upstream_error'},
        ],
      });
    });
    await expectLater(resolver.check('1'), throwsA(isA<TuneWeaveException>()));
    expect(resolver.state('1').grey, false);
  });
  test(
    'Confirmed negative results avoid requests until their TTL expires',
    () async {
      var now = DateTime(2026), calls = 0;
      final resolver = AvailabilityResolver((_) async {
        calls++;
        throw const TuneWeaveException('resource_not_found', 'none', {
          'attempts': [
            {'status': 'no_match'},
            {'status': 'unavailable'},
          ],
        });
      }, clock: () => now);
      await expectLater(
        resolver.check('1'),
        throwsA(isA<TuneWeaveException>()),
      );
      await expectLater(
        resolver.check('1'),
        throwsA(isA<TuneWeaveException>()),
      );
      expect(calls, 1);
      now = now.add(const Duration(minutes: 2));
      await expectLater(
        resolver.check('1'),
        throwsA(isA<TuneWeaveException>()),
      );
      expect(calls, 2);
    },
  );
  test(
    'Fallback media stays playable regardless of origin entitlement',
    () async {
      final resolver = AvailabilityResolver((_) async => media());
      expect(resolver.state('netease:1').grey, false);
      await resolver.check('netease:1');
      expect(resolver.state('netease:1').status, Playability.playable);
      expect(resolver.state('netease:1').media!.platform, 'qq');
    },
  );
  test(
    'Transient failure stays unknown; affirmative resolver exhaustion greys',
    () async {
      var code = 'transport_error';
      final resolver = AvailabilityResolver(
        (_) async => throw TuneWeaveException(code, 'error'),
      );
      await expectLater(
        resolver.check('1'),
        throwsA(isA<TuneWeaveException>()),
      );
      expect(resolver.state('1').grey, false);
      code = 'no_playable_source';
      await expectLater(
        resolver.check('1'),
        throwsA(isA<TuneWeaveException>()),
      );
      expect(resolver.state('1').grey, true);
    },
  );
  test(
    'At most two checks, duplicate requests shared, stale results ignored',
    () async {
      final gates = <Completer<ResolvedMedia>>[];
      final resolver = AvailabilityResolver((_) {
        final gate = Completer<ResolvedMedia>();
        gates.add(gate);
        return gate.future;
      });
      final first = resolver.check('1');
      expect(identical(first, resolver.check('1')), true);
      final second = resolver.check('2');
      final third = resolver.check('3');
      final results = Future.wait(
        [first, second, third].map(
          (f) => f.then<Object>((value) => value, onError: (Object e) => e),
        ),
      );
      expect(gates.length, 2);
      resolver.invalidate();
      gates[0].complete(media());
      gates[1].complete(media());
      await results;
      expect(resolver.state('1').status, Playability.unknown);
      expect(gates.length, 2);
    },
  );
  test(
    'Trial labelled separately and negative cache expires in two minutes',
    () async {
      var now = DateTime(2026), code = '';
      final resolver = AvailabilityResolver((_) async {
        if (code.isNotEmpty) throw TuneWeaveException(code, 'none');
        return media(trial: true);
      }, clock: () => now);
      await resolver.check('1');
      expect(resolver.state('1').status, Playability.trial);
      expect(resolver.state('1').grey, false);
      code = 'no_playable_source';
      await expectLater(
        resolver.check('2'),
        throwsA(isA<TuneWeaveException>()),
      );
      now = now.add(const Duration(minutes: 2));
      expect(resolver.state('2').grey, false);
    },
  );
}
