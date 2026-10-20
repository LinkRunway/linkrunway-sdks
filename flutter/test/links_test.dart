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
  group('click tokens', () {
    test('are captured from a URL and from an install referrer', () async {
      final api = FakeApi((_) => json({}));
      final storage = RecordingStorage();
      final runway = client(api, storage: storage);
      await runway.capture(
        'https://shop.example.com/p/1?lr_click_id=c&lr_token=a.b-c_d&lr_path=%2Fp',
      );
      expect(await runway.attributionToken(), 'a.b-c_d');
      expect(storage.saved['clickToken'], 'a.b-c_d');
      await runway.captureReferrer('utm_source=google-play&lr_token=from%2Dreferrer');
      expect(await runway.attributionToken(), 'from-referrer');
      await runway.capture('myapp://open?lr_token=custom');
      expect(await runway.attributionToken(), 'custom');
      expect(api.sent, isEmpty);
    });

    test('ignore a URL without a usable token', () async {
      final runway = client(FakeApi((_) => json({})));
      await runway.capture('https://example.com/?lr_token=kept');
      for (final url in [
        'https://example.com/',
        'https://example.com/?lr_token=',
        'https://example.com/?lr_token=${'x' * 1501}',
        'https://example.com/?lr_token=%E0%A4%A',
        'not a url',
      ]) {
        await runway.capture(url);
      }
      expect(await runway.attributionToken(), 'kept');
    });
  });

  group('open', () {
    test('resolves a link for the app platform and saves its click token', () async {
      final api = FakeApi((_) => json(resolved));
      final runway = client(api, platform: LinkRunwayPlatform.androidTv);
      final link = (await runway.open('$endpoint/l/summer?s=share'))!;
      expect(api.sent.single.path, 'resolve');
      expect(api.sent.single.body, {
        'url': '$endpoint/l/summer?s=share',
        'platform': 'android',
        'consent': true,
      });
      expect(
        (link.clickId, link.clickToken, link.path, link.url),
        ('click', 'resolved', '/product/1', 'https://shop.example.com/p/1'),
      );
      expect(link.metadata, {'sku': 'A1'});
      expect(link.untracked, isFalse);
      expect(await runway.attributionToken(), 'resolved');

      final web = client(api, platform: null);
      await web.open('$endpoint/l/summer');
      expect(api.sent.last.body['platform'], 'web');
    });

    test('treats an untracked open as successful and leaves the attribution alone', () async {
      final api = FakeApi(
        (_) => json({...resolved, 'clickId': '', 'untracked': true}..remove('clickToken')),
      );
      final runway = client(api);
      await runway.capture('https://example.com/?lr_token=original');
      final link = (await runway.open('$endpoint/l/over-quota'))!;
      expect((link.untracked, link.clickId, link.path), (true, null, '/product/1'));
      expect(await runway.attributionToken(), 'original');
    });

    test('clears the token when the server will not attribute the visit', () async {
      final api = FakeApi((_) => json({...resolved}..remove('clickToken')));
      final runway = client(api);
      await runway.capture('https://example.com/?lr_token=original');
      await runway.open('$endpoint/l/suppressed');
      expect(await runway.attributionToken(), isNull);
    });

    test('surfaces a link the API does not know', () async {
      final api = FakeApi((_) => refuse('Link is unavailable', 404));
      expect(
        client(api).open('$endpoint/l/gone'),
        throwsA(isA<LinkRunwayException>().having((error) => error.status, 'status', 404)),
      );
    });
  });

  group('shares and referral codes', () {
    test('create a tracked share link', () async {
      final api = FakeApi((_) => json({'shareId': 'share', 'url': '$endpoint/l/summer?s=share'}));
      final share = await client(
        api,
      ).createShare(linkId: 'link', externalUserId: 'user-7', channel: 'native_share');
      expect((share.shareId, share.url), ('share', '$endpoint/l/summer?s=share'));
      expect(api.sent.single.path, 'shares');
      expect(api.sent.single.body, {
        'linkId': 'link',
        'externalUserId': 'user-7',
        'channel': 'native_share',
      });
    });

    test('turn an attributed click into a code and claim it on another install', () async {
      final api = FakeApi(
        (request) => switch (request.path) {
          'deferred' => json({'code': 'ABCDEFGHJKLM', 'expiresAt': '2026-10-11T00:00:00.000Z'}),
          _ => json({...resolved, 'clickToken': 'claimed'}),
        },
      );
      final runway = client(api);
      expect(runway.createReferralCode(), throwsStateError);
      await runway.capture('https://example.com/?lr_token=original');
      final code = (await runway.createReferralCode())!;
      expect((code.code, code.expiresAt), ('ABCDEFGHJKLM', DateTime.utc(2026, 10, 11)));
      expect(api.sent.single.body, {'clickToken': 'original', 'consent': true});

      const claimId = 'f507b5b6-17a1-4aab-a61c-aef710eb3b07';
      final link = (await runway.claimReferralCode('ABCDEFGHJKLM', claimId))!;
      expect(api.sent.last.path, 'deferred/claim');
      expect(api.sent.last.body, {'code': 'ABCDEFGHJKLM', 'claimId': claimId, 'consent': true});
      expect(link.path, '/product/1');
      expect(await runway.attributionToken(), 'claimed');
    });
  });
}
