import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:linkrunway/linkrunway.dart';
import 'package:test/test.dart';

import 'support.dart';

const resolved = {
  'clickId': 'click',
  'clickToken': 'resolved',
  'path': '/product/1',
  'url': 'https://shop.example.com/p/1',
  'metadata': {'sku': 'A1'},
};

void main() {
  group('without consent', () {
    test('nothing is sent and nothing is stored', () async {
      final api = FakeApi((_) => json({'id': 'event'}));
      final storage = RecordingStorage();
      final runway = client(api, consent: false, storage: storage);
      await runway.capture('https://example.com/?lr_token=signed');
      expect(await runway.attributionToken(), isNull);
      expect(await runway.installId(), isNull);
      expect((await runway.track(EventType.open)).skipped, isTrue);
      expect(await runway.open('$endpoint/l/summer'), isNull);
      expect(await runway.claimReferralCode('ABCDEFGHJKLM', 'claim'), isNull);
      expect(await runway.matchInstall(), isNull);
      expect(await runway.submitAdServicesToken('a' * 40), isNull);
      await runway.flush();
      expect(runway.createShare(linkId: 'link'), throwsStateError);
      expect(runway.createReferralCode(), throwsStateError);
      expect(api.sent, isEmpty);
      expect(storage.values, isEmpty);
      expect(storage.writes, 0);
    });
  });

  group('consent', () {
    test('granted later restores what an earlier launch saved', () async {
      final api = FakeApi((_) => json({'id': 'event'}));
      final storage = RecordingStorage();
      final earlier = client(api, storage: storage);
      await earlier.capture('https://example.com/?lr_token=saved');
      final installId = await earlier.installId();

      final later = client(api, consent: false, storage: storage);
      expect(later.consent, isFalse);
      expect(await later.attributionToken(), isNull);
      await later.setConsent(true);
      expect(later.consent, isTrue);
      expect(await later.attributionToken(), 'saved');
      expect(await later.installId(), installId);
    });

    test('withdrawn erases the token, the install ID and the queue', () async {
      var online = false;
      final api = FakeApi((_) => online ? json({'id': 'event'}) : throw http.ClientException('x'));
      final storage = RecordingStorage();
      final runway = client(api, storage: storage);
      await runway.capture('https://example.com/?lr_token=signed');
      final first = await runway.installId();
      expect((await runway.track(EventType.open)).queued, isTrue);
      expect(storage.saved['queue'], hasLength(1));

      await runway.setConsent(false);
      expect(storage.values, isEmpty);
      expect(await runway.attributionToken(), isNull);
      expect(await runway.installId(), isNull);

      online = true;
      await runway.setConsent(true);
      await runway.flush();
      expect(api.sent, hasLength(1));
      expect(await runway.installId(), isNot(first));
      expect(await runway.attributionToken(), isNull);
    });

    test('withdrawn while a request is pending drops the answer', () async {
      final gate = Completer<http.Response>();
      final api = FakeApi((_) => gate.future);
      final storage = RecordingStorage();
      final runway = client(api, storage: storage);
      final pending = runway.open('$endpoint/l/summer');
      await Future<void>.delayed(Duration.zero);
      // Even a new grant does not adopt an answer that was asked for under the earlier one.
      await runway.setConsent(false);
      await runway.setConsent(true);
      gate.complete(json(resolved));
      expect(await pending, isNull);
      expect(await runway.attributionToken(), isNull);
      expect(storage.values, isEmpty);
    });

    test('performs no write that was still waiting when consent was withdrawn', () async {
      final storage = _SlowStorage();
      final request = Completer<http.Response>();
      final api = FakeApi((_) => request.future);
      final runway = client(api, storage: storage);
      await runway.installId();
      // The event is on the network when a slow write starts; its failure queues another write.
      final tracked = runway.track(EventType.open);
      await Future<void>.delayed(Duration.zero);
      expect(api.sent, hasLength(1));
      storage.hold = Completer<void>();
      final captured = runway.capture('https://example.com/?lr_token=signed');
      await Future<void>.delayed(Duration.zero);
      request.completeError(http.ClientException('offline'));
      await Future<void>.delayed(Duration.zero);
      final withdrawn = runway.setConsent(false);
      storage.hold!.complete();
      await Future.wait([captured, tracked, withdrawn]);
      expect(storage.log, ['write', 'write', 'delete']);
    });

    test('a store that fails leaves the client working in memory', () async {
      final api = FakeApi((_) => json({'id': 'event'}));
      final runway = client(api, storage: _BrokenStorage());
      await runway.capture('https://example.com/?lr_token=signed');
      expect(await runway.attributionToken(), 'signed');
      expect((await runway.track(EventType.open)).id, 'event');
      await runway.setConsent(false);
      expect(await runway.attributionToken(), isNull);
    });
  });

  group('construction', () {
    LinkRunway build(String url, [String key = publishableKey]) =>
        LinkRunway(endpoint: url, publishableKey: key);

    test('requires HTTPS outside local development hosts', () {
      for (final url in ['http://go.example.com', 'ftp://go.example.com', 'go.example.com', '']) {
        expect(() => build(url), throwsArgumentError, reason: url);
      }
      for (final url in [
        'http://localhost:4210',
        'http://127.0.0.1:4210',
        'http://10.0.2.2:4210',
      ]) {
        expect(build(url).consent, isFalse, reason: url);
      }
    });

    test('refuses a server key without repeating it', () {
      expect(
        () => build(endpoint, 'lr_sk_secret_value'),
        throwsA(
          isA<ArgumentError>().having(
            (error) => '$error',
            'message',
            allOf(contains('publishable key'), isNot(contains('secret_value'))),
          ),
        ),
      );
    });
  });
}

/// Records the order of operations; a write waits while [hold] is set and not completed.
final class _SlowStorage implements LinkRunwayStorage {
  final List<String> log = [];
  Completer<void>? hold;

  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {
    log.add('write');
    await hold?.future;
  }

  @override
  Future<void> delete(String key) async => log.add('delete');
}

final class _BrokenStorage implements LinkRunwayStorage {
  @override
  Future<String?> read(String key) => Future.error(StateError('unreadable'));

  @override
  Future<void> write(String key, String value) => Future.error(StateError('read-only'));

  @override
  Future<void> delete(String key) => Future.error(StateError('read-only'));
}
