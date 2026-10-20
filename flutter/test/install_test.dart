import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:linkrunway/linkrunway.dart';
import 'package:test/test.dart';

import 'support.dart';

const matched = {
  'matched': true,
  'method': 'REFERRER',
  'clickId': 'click',
  'clickToken': 'match-token',
  'path': '/welcome',
  'url': 'https://example.com',
  'metadata': {'plan': 'pro'},
};

http.Response pending() => json({'pending': true, 'retryAfterSeconds': 5}, 202);

void main() {
  group('install identity', () {
    test('is created on first use, sent with events and kept across restarts', () async {
      final api = FakeApi((_) => json({'id': 'event'}));
      final storage = RecordingStorage();
      final runway = client(api, storage: storage);
      await runway.attributionToken();
      expect(storage.writes, 0);
      final id = (await runway.installId())!;
      expect(id, matches(uuidShape));
      expect(storage.saved['installId'], id);
      await runway.track(EventType.open);
      expect(api.sent.single.body['installId'], id);
      expect(await client(api, storage: storage).installId(), id);
    });

    test('accepts an injected generator and falls back when it returns something else', () async {
      const upper = '9F1C2D3E-4B5A-4C6D-8E7F-0A1B2C3D4E5F';
      final api = FakeApi((_) => json({}));
      expect(await client(api, randomUuid: () => upper).installId(), upper.toLowerCase());
      expect(await client(api, randomUuid: () => 'nope').installId(), matches(uuidShape));
    });
  });

  group('first-launch match', () {
    test('asks once, saves the click token and answers later calls from storage', () async {
      final api = FakeApi((_) => json(matched));
      final storage = RecordingStorage();
      final runway = client(api, storage: storage, platform: LinkRunwayPlatform.android);
      final results = await Future.wait([
        runway.matchInstall(osVersion: '14', language: 'en_US', referrer: 'lr_token=abc'),
        runway.matchInstall(),
      ]);
      expect(api.sent.single.path, 'installs/match');
      expect(api.sent.single.body, {
        'installId': await runway.installId(),
        'platform': 'android',
        'osVersion': '14',
        'language': 'en-US',
        'referrer': 'lr_token=abc',
        'consent': true,
      });
      final first = results.first!;
      expect((first.matched, first.method, first.cached), (true, MatchMethod.referrer, false));
      expect((first.clickId, first.path, first.url), ('click', '/welcome', 'https://example.com'));
      expect(first.metadata, {'plan': 'pro'});
      expect(identical(results.last, first), isTrue);
      expect(await runway.attributionToken(), 'match-token');
      expect((storage.saved['match']! as Map).containsKey('clickToken'), isFalse);

      final restarted = client(api, storage: storage, platform: LinkRunwayPlatform.android);
      final again = (await restarted.matchInstall())!;
      expect((again.matched, again.cached, again.path), (true, true, '/welcome'));
      expect((await restarted.installMatch())!.cached, isTrue);
      expect(api.sent, hasLength(1));
    });

    test('keeps the token of a link opened since and stores an unmatched answer', () async {
      final api = FakeApi((_) => json(matched));
      final runway = client(api);
      await runway.capture('https://example.com/?lr_token=opened');
      await runway.matchInstall();
      expect(await runway.attributionToken(), 'opened');

      final none = FakeApi((_) => json({'matched': false, 'method': 'NONE'}));
      final other = client(none);
      final first = (await other.matchInstall())!;
      expect((first.matched, first.method, first.cached), (false, MatchMethod.none, false));
      expect((await other.matchInstall())!.cached, isTrue);
      expect(await other.attributionToken(), isNull);
      expect(none.sent, hasLength(1));
    });

    test('drops an answer that arrives after consent was withdrawn', () async {
      final gate = Completer<http.Response>();
      final api = FakeApi((_) => gate.future);
      final storage = RecordingStorage();
      final runway = client(api, storage: storage);
      final waiting = runway.matchInstall();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await runway.setConsent(false);
      await runway.setConsent(true);
      gate.complete(json(matched));
      expect(await waiting, isNull);
      expect(await runway.installMatch(), isNull);
      expect(await runway.attributionToken(), isNull);
    });

    test('leaves out details the API would reject and needs a platform', () async {
      final api = FakeApi((_) => json({'matched': false, 'method': 'NONE'}));
      await client(api).matchInstall(
        osVersion: '17.5.1.2',
        language: 'en-US-u-ca-gregory',
        referrer: 'utm_content=${'x' * 4100}&lr_token=a%2Eb',
      );
      expect(api.sent.single.body, {
        'installId': isA<String>(),
        'platform': 'ios',
        'osVersion': '17.5.1',
        'language': 'en-US',
        'referrer': 'lr_token=a.b',
        'consent': true,
      });
      await client(api).matchInstall(osVersion: 'S', language: 'und', referrer: '');
      expect(api.sent.last.body.keys, ['installId', 'platform', 'consent']);
      expect(() => client(api, platform: null).matchInstall(), throwsStateError);
    });
  });

  group('attestation', () {
    test('is attached to events until it expires and is never stored', () async {
      var now = DateTime.utc(2026, 10, 10, 12);
      final api = FakeApi((_) => json({'id': 'event'}));
      final storage = RecordingStorage();
      final runway = client(api, storage: storage, clock: () => now);
      runway.setAttestation('attested', now.add(const Duration(minutes: 1)));
      await runway.track(EventType.open);
      expect(api.sent.last.body['attestation'], 'attested');
      expect(storage.values[storageKey], isNot(contains('attested')));
      now = now.add(const Duration(minutes: 2));
      await runway.track(EventType.open);
      expect(api.sent.last.body.containsKey('attestation'), isFalse);
    });

    test('is ignored without consent, cleared on withdrawal and rejects unusable input', () async {
      final api = FakeApi((_) => json({'id': 'event'}));
      final runway = client(api, consent: false);
      final later = DateTime.now().add(const Duration(hours: 1));
      runway.setAttestation('early', later);
      await runway.setConsent(true);
      await runway.track(EventType.open);
      expect(api.sent.last.body.containsKey('attestation'), isFalse);
      runway.setAttestation('held', later);
      await runway.setConsent(false);
      await runway.setConsent(true);
      await runway.track(EventType.open);
      expect(api.sent.last.body.containsKey('attestation'), isFalse);
      expect(() => runway.setAttestation('', later), throwsArgumentError);
      expect(() => runway.setAttestation('x' * 2001, later), throwsArgumentError);
    });
  });

  group('ad-network claims', () {
    test(
      'repeat an AdServices claim while the server answers 202, then never send it again',
      () async {
        var calls = 0;
        final api = FakeApi((_) => ++calls < 3 ? pending() : json({'attributed': true}));
        final storage = RecordingStorage();
        final runway = client(api, storage: storage);
        final token = 'a' * 40;
        const quick = Duration(milliseconds: 1);
        final result = (await runway.submitAdServicesToken(token, delay: quick))!;
        expect(result.status, ClaimStatus.submitted);
        expect(result.data, {'attributed': true});
        expect(api.sent, hasLength(3));
        expect(api.sent.first.path, 'claims/apple-ads');
        expect(api.sent.first.body, {
          'installId': await runway.installId(),
          'token': token,
          'consent': true,
        });
        expect((await runway.submitAdServicesToken(token))!.status, ClaimStatus.alreadySubmitted);
        final restarted = client(api, storage: storage);
        expect(
          (await restarted.submitAdServicesToken(token))!.status,
          ClaimStatus.alreadySubmitted,
        );
        expect(api.sent, hasLength(3));
      },
    );

    test('report a claim that stays pending, and submit it again on the next call', () async {
      final api = FakeApi((_) => pending());
      final runway = client(api);
      const quick = Duration(milliseconds: 1);
      final first = (await runway.submitAdServicesToken('a' * 40, delay: quick))!;
      expect((first.status, first.data['retryAfterSeconds']), (ClaimStatus.pending, 5));
      expect(api.sent, hasLength(4));
      await runway.submitAdServicesToken('a' * 40, retries: 0);
      expect(api.sent, hasLength(5));
    });

    test('forward a referrer claim once, without retrying, and skip an empty referrer', () async {
      var calls = 0;
      final api = FakeApi((_) => ++calls == 1 ? pending() : json({'claims': <Object?>[]}));
      final runway = client(api);
      expect(await runway.submitReferrerClaim('app_1', ''), isNull);
      expect((await runway.submitReferrerClaim('app_1', 'gclid=abc'))!.status, ClaimStatus.pending);
      expect(api.sent, hasLength(1));
      expect(
        (await runway.submitReferrerClaim('app_1', 'gclid=abc'))!.status,
        ClaimStatus.submitted,
      );
      expect(api.sent.last.path, 'claims/referrer');
      expect(api.sent.last.body, {
        'installId': await runway.installId(),
        'appId': 'app_1',
        'referrer': 'gclid=abc',
        'consent': true,
      });
      final again = await runway.submitReferrerClaim('app_1', 'gclid=abc');
      expect(again!.status, ClaimStatus.alreadySubmitted);
      expect(api.sent, hasLength(2));
    });

    test('stop when consent is withdrawn between attempts', () async {
      final api = FakeApi((_) => pending());
      final runway = client(api);
      final claim = runway.submitAdServicesToken('a' * 40, delay: const Duration(milliseconds: 30));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await runway.setConsent(false);
      expect(await claim, isNull);
      expect(api.sent, hasLength(1));
    });
  });
}
