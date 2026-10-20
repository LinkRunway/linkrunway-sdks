import 'package:http/http.dart' as http;
import 'package:linkrunway/linkrunway.dart';
import 'package:test/test.dart';

import 'support.dart';

const expired = 'Click token is invalid or expired';

Never offline() => throw http.ClientException('offline');

void main() {
  group('track', () {
    test('sends the event with the click token, the install ID and the SDK user agent', () async {
      final api = FakeApi((_) => json({'id': 'event', 'attributed': true, 'duplicate': false}));
      final at = DateTime.utc(2026, 10, 9, 8, 30, 15, 123, 456);
      final runway = client(api, clock: () => at);
      await runway.capture('https://example.com/?lr_token=signed');
      final result = await runway.track(
        EventType.custom,
        eventId: 'viewed-1',
        name: 'viewed',
        externalUserId: 'user-7',
        metadata: {'plan': 'pro', 'seats': 3},
      );
      expect((result.id, result.attributed, result.duplicate), ('event', true, false));
      expect((result.queued, result.skipped), (false, false));
      final request = api.sent.single;
      expect(request.path, 'track');
      expect(request.body, {
        'eventId': 'viewed-1',
        'type': 'CUSTOM',
        'name': 'viewed',
        'clickToken': 'signed',
        'externalUserId': 'user-7',
        'metadata': {'plan': 'pro', 'seats': 3},
        'occurredAt': '2026-10-09T08:30:15.123Z',
        'installId': await runway.installId(),
        'consent': true,
      });
      expect(request.headers['authorization'], 'Bearer $publishableKey');
      expect(request.headers['user-agent'], 'LinkRunwaySDK/$sdkVersion Flutter');
      expect(
        request.headers['user-agent'],
        matches(r'^LinkRunwaySDK/[0-9.]+ (iOS|Android|tvOS|AndroidTV|ReactNative|Flutter)$'),
      );
      expect(request.headers['content-type'], startsWith('application/json'));
    });

    test('gives an event a UUID and the current time when none are supplied', () async {
      final api = FakeApi((_) => json({'id': 'event'}));
      await client(api).track(EventType.open);
      final body = api.sent.single.body;
      expect(body['eventId'], matches(uuidShape));
      expect(DateTime.parse(body['occurredAt']! as String).isUtc, isTrue);
      expect(body.containsKey('clickToken'), isFalse);
    });

    test('queues a failed event and flushes it once with its original ID and time', () async {
      var online = false;
      final api = FakeApi((_) => online ? json({'id': 'event'}) : offline());
      final storage = RecordingStorage();
      final runway = client(api, storage: storage);
      expect((await runway.track(EventType.open, eventId: 'original')).queued, isTrue);
      final first = api.sent.single.body;
      expect(storage.saved['queue'], [first..remove('consent')]);

      // A restart keeps the queue.
      online = true;
      final restarted = client(api, storage: storage);
      await Future.wait([restarted.flush(), restarted.flush()]);
      expect(api.sent, hasLength(2));
      expect(api.sent.last.body['eventId'], 'original');
      expect(api.sent.last.body['occurredAt'], first['occurredAt']);
      expect(storage.saved['queue'], isEmpty);
    });

    test('retries a busy server, then surfaces what the API refuses', () async {
      var calls = 0;
      final busy = FakeApi((_) => ++calls < 3 ? refuse('Busy', 503) : json({'id': 'event'}));
      expect((await client(busy, retries: 2).track(EventType.open)).id, 'event');
      expect(busy.sent, hasLength(3));

      final invalid = FakeApi((_) => refuse('metadata: Too big'));
      final runway = client(invalid, retries: 2);
      await expectLater(
        runway.track(EventType.open),
        throwsA(
          isA<LinkRunwayException>()
              .having((error) => error.status, 'status', 400)
              .having((error) => error.message, 'message', 'metadata: Too big'),
        ),
      );
      expect(invalid.sent, hasLength(1));
      await runway.flush();
      expect(invalid.sent, hasLength(1));
    });

    test('never counts a non-JSON success as delivered', () async {
      final portal = FakeApi((_) => http.Response('<html>Sign in to Wi-Fi</html>', 200));
      expect((await client(portal).track(EventType.open)).queued, isTrue);
      final missing = FakeApi((_) => http.Response('<html>Not found</html>', 404));
      await expectLater(
        client(missing).track(EventType.open),
        throwsA(isA<LinkRunwayException>().having((error) => error.status, 'status', 404)),
      );
    });
  });

  group('flush', () {
    test('drops an event the API refuses as invalid and keeps a conflict for later', () async {
      var online = false;
      final api = FakeApi((request) {
        if (!online) offline();
        return switch (request.body['eventId']) {
          'invalid' => refuse('Event timestamp is out of range'),
          'conflict' => refuse('Concurrent update', 409),
          _ => json({'id': 'event'}),
        };
      });
      final runway = client(api);
      for (final id in ['invalid', 'conflict', 'fine']) {
        await runway.track(EventType.open, eventId: id);
      }
      online = true;
      await expectLater(runway.flush(), throwsA(isA<LinkRunwayException>()));
      expect(api.sent.skip(3).map((request) => request.body['eventId']), [
        'invalid',
        'conflict',
        'fine',
      ]);
      await expectLater(runway.flush(), throwsA(isA<LinkRunwayException>()));
      expect(api.sent.skip(6).map((request) => request.body['eventId']), ['conflict']);
    });

    test('stops at a failure that would repeat, keeping every event', () async {
      var status = 0;
      final api = FakeApi((_) {
        if (status == 0) offline();
        return status == 200 ? json({'id': 'event'}) : refuse('No', status);
      });
      final runway = client(api);
      await runway.track(EventType.open, eventId: 'a');
      await runway.track(EventType.open, eventId: 'b');
      for (status in [503, 401, 402]) {
        await expectLater(runway.flush(), throwsA(isA<LinkRunwayException>()));
      }
      expect(api.sent, hasLength(5));
      status = 200;
      await runway.flush();
      expect(api.sent.skip(5).map((request) => request.body['eventId']), ['a', 'b']);
    });
  });

  group('a click token the API no longer accepts', () {
    test('costs one retry: the event is delivered without it and the token is forgotten', () async {
      final api = FakeApi(
        (request) => request.body.containsKey('clickToken') ? refuse(expired) : json({'id': 'e'}),
      );
      final storage = RecordingStorage();
      final runway = client(api, storage: storage);
      await runway.capture('https://example.com/?lr_token=stale');
      expect((await runway.track(EventType.open)).id, 'e');
      expect(api.sent.map((request) => request.body['clickToken']), ['stale', null]);
      expect(await runway.attributionToken(), isNull);
      expect(storage.saved.containsKey('clickToken'), isFalse);
      await runway.track(EventType.open);
      expect(api.sent, hasLength(3));
    });

    test('is kept when the event is refused for another reason or the retry fails', () async {
      final invalid = FakeApi((_) => refuse('metadata: Too big'));
      final runway = client(invalid);
      await runway.capture('https://example.com/?lr_token=good');
      await expectLater(runway.track(EventType.open), throwsA(isA<LinkRunwayException>()));
      expect(invalid.sent, hasLength(2));
      expect(await runway.attributionToken(), 'good');

      final flaky = FakeApi(
        (request) => request.body.containsKey('clickToken') ? refuse(expired) : offline(),
      );
      final other = client(flaky);
      await other.capture('https://example.com/?lr_token=stale');
      expect((await other.track(EventType.open)).queued, isTrue);
      expect(await other.attributionToken(), 'stale');
    });
  });
}
