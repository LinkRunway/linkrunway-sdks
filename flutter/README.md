# Dart and Flutter (`package:linkrunway`)

`package:linkrunway` is a pure Dart client with the same surface as the [JavaScript SDK](../js/sdk/README.md) for apps: consent, click-token capture, link resolution, events with an offline queue and retries, tracked shares, referral codes, the install ID, the first-launch match, ad-network claims and an attestation token setter. It is built on `package:http` and depends on nothing else.

**It has no platform channels and no native code.** It cannot read deep links, the Play install referrer, an AdServices token or a device attestation by itself; the app passes those values in. [Values only native code can read](#values-only-native-code-can-read) shows where they can come from. Install it with `dart pub add linkrunway` (or `flutter pub add linkrunway`). See [Verified and not verified](#verified-and-not-verified) before relying on it.

## Install

```yaml
dependencies:
  linkrunway: ^0.1.0
```

The package requires Dart 3.7 or newer and `http` 1.2.2 or newer. It ignores `.dart_tool/` and does not commit `pubspec.lock`: as a library it leaves the resolved versions to the app.

To check it, run these in this directory with a Dart SDK (Flutter's bundled `dart` works too):

```sh
dart pub get
dart analyze --fatal-infos
dart test
dart format --output=none --set-exit-if-changed .
```

## Setup

```dart
import 'dart:io' show Platform;

import 'package:linkrunway/linkrunway.dart';

final runway = LinkRunway(
  endpoint: 'https://go.example.com',
  publishableKey: 'lr_pk_your_key',
  platform: Platform.isIOS ? LinkRunwayPlatform.ios : LinkRunwayPlatform.android,
  storage: SharedPreferencesStorage(SharedPreferencesAsync()), // below
);

// After your consent flow:
await runway.setConsent(true);
```

| Parameter             | Default         | Purpose                                                                                                                             |
| --------------------- | --------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `endpoint`            | required        | Your link domain. `http` is accepted only for `localhost`, `127.0.0.1` and `10.0.2.2` (the Android emulator's host).                |
| `publishableKey`      | required        | Must start with `lr_pk_`. A server key throws an `ArgumentError` whose message does not contain the key.                            |
| `consent`             | `false`         | Initial consent. Change it with `setConsent`.                                                                                       |
| `platform`            | `null`          | `ios`, `android`, `tvos` or `androidTv`. Used by `matchInstall`, which needs it, and by `open`, which resolves as `web` without it. |
| `storage`             | `MemoryStorage` | A `LinkRunwayStorage`. Without one, state lasts only as long as the process.                                                        |
| `httpClient`          | `http.Client()` | Injected client, for tests or your own configuration. A client you pass is not closed by `close()`.                                 |
| `retries`             | `2` (0 to 5)    | Retries after a network failure, a 429 or a 5xx. The delay starts at `retryDelay` (300 ms), doubles, and is capped at 3.1 s.        |
| `timeout`             | 10 s            | Per attempt.                                                                                                                        |
| `randomUuid`, `clock` | built in        | Sources of the install ID and of event times, for tests. The install ID uses `Random.secure()`.                                     |

Outside a browser build, requests never follow redirects, so the key is only sent to the endpoint, and each request carries `User-Agent: LinkRunwaySDK/0.1.0 Flutter`, which the API recognizes.

### Storage

Implement `LinkRunwayStorage` over the key-value store your app already uses. Each method may answer directly or with a future. This adapter for `shared_preferences` is an example; it was not compiled here, because `shared_preferences` is not a dependency of this package.

```dart
import 'package:linkrunway/linkrunway.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class SharedPreferencesStorage implements LinkRunwayStorage {
  SharedPreferencesStorage(this._preferences);

  final SharedPreferencesAsync _preferences;

  @override
  Future<String?> read(String key) => _preferences.getString(key);

  @override
  Future<void> write(String key, String value) => _preferences.setString(key, value);

  @override
  Future<void> delete(String key) => _preferences.remove(key);
}
```

The client writes one JSON value under `linkrunway:<endpoint origin>:<first 20 characters of the key>`, in the same format as the JavaScript SDK. Storage calls run one at a time in order; a store that fails leaves the client working in memory.

## API

All calls that touch state wait until state saved by an earlier launch has been loaded.

| Call                                                                   | Behaviour                                                                                                                                                                                                            |
| ---------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `setConsent(bool)`                                                     | `true` loads what an earlier launch saved. `false` erases the click token, install ID, queue, stored match and attestation, from memory and storage.                                                                 |
| `capture(url)`, `captureReferrer(referrer)`                            | Save the `lr_token` of a URL or of a Play install referrer. A token that is empty, longer than 1500 characters or not decodable is ignored.                                                                          |
| `attributionToken()`                                                   | The saved token, for your backend. `null` without consent.                                                                                                                                                           |
| `open(url)`                                                            | Resolves a `/l/<key>` link (`POST /v1/resolve`) and saves its token. Returns a `ResolvedLink` (`clickId`, `clickToken`, `path`, `url`, `metadata`, `untracked`). Throws a `LinkRunwayException` for an unknown link. |
| `track(type, {eventId, name, externalUserId, metadata, occurredAt})`   | `type` is `EventType.install`, `open`, `signup` or `custom`; revenue is reported by your backend with a server key. Returns a `TrackingResult` that is delivered, `queued` or `skipped`.                             |
| `flush()`                                                              | Sends the queue in order. Concurrent calls share one pass.                                                                                                                                                           |
| `createShare(linkId: …, externalUserId: …, channel: …)`                | Returns a `SharedLink` (`shareId`, `url`). Throws a `StateError` without consent.                                                                                                                                    |
| `createReferralCode()`, `claimReferralCode(code, claimId)`             | As described in [mobile integration](https://linkrunway.com/resources/mobile). Keep `claimId`, a UUID, stable across retries.                                                                         |
| `installId()`, `installMatch()`, `matchInstall(…)`                     | See [Install identity and first-launch match](#install-identity-and-first-launch-match).                                                                                                                             |
| `submitReferrerClaim(appId, referrer)`, `submitAdServicesToken(token)` | See [Ad-network claims](#ad-network-claims).                                                                                                                                                                         |
| `setAttestation(token, expiresAt)`                                     | See [Device attestation](#device-attestation).                                                                                                                                                                       |
| `close()`                                                              | Closes the HTTP client the instance created.                                                                                                                                                                         |

Without consent no request is made and nothing is stored: `track` returns a skipped result, `createShare` and `createReferralCode` throw a `StateError`, and the other calls return `null`. An answer that arrives after consent was withdrawn is discarded, even if consent was granted again in the meantime.

### Events and the offline queue

`track` sends the event with its ID (a new UUID unless given), its time, the saved click token and the install ID.

- A network failure, a timeout, a 429, a 5xx, or a successful status whose body is not a JSON object puts the event in the queue (the newest 100 events, with their original ID and time) and returns a `queued` result.
- Any other refusal throws a `LinkRunwayException` with the status and the API's message.
- `flush()` drops a queued event the API refuses as invalid (400 or 422), keeps a 409 for the next flush, and stops at any other failure with the queue intact. It then throws the first refusal it met.
- When the API refuses an event because its click token has expired, the event is sent once more without the token. If that is accepted, the token is forgotten, so later events are sent unattributed instead of failing.

Call `flush()` when the app returns to the foreground, for example from `AppLifecycleListener(onResume: …)`.

### Links

The package does not listen for links. Pass each incoming URL to it, for example from the `app_links` package (`getInitialLink()` and `uriLinkStream`; check that package's documentation, as it was not used here):

```dart
final linkPath = RegExp(r'^/l/[A-Za-z0-9_-]+$');

Future<void> handleIncoming(Uri uri) async {
  if (uri.queryParameters.containsKey('lr_token')) {
    await runway.capture(uri.toString()); // the destination of a web redirect
  } else if (uri.host == 'go.example.com' && linkPath.hasMatch(uri.path)) {
    final link = await runway.open(uri.toString());
    if (link != null && allowedRoutes.contains(link.path)) router.go(link.path);
  }
}
```

`path` and `metadata` come from the link's configuration: route only to paths your app allowlists. When the workspace is over its click allowance, `untracked` is `true`: the link still routes, no click was recorded, and the saved token is unchanged.

### Install identity and first-launch match

`installId()` returns a random version 4 UUID, created on first use, saved with the rest of the state, sent with every event, and deleted when consent is withdrawn; a later grant starts a new one. It is not derived from the device.

`matchInstall(osVersion: …, language: …, referrer: …)` asks `POST /v1/installs/match` once which earlier touch led to this install, as described in [attribution](https://linkrunway.com/resources/attribution). The answer is stored, so later calls return it with `cached: true` and make no request; concurrent calls share one request. Its click token is saved unless a token is already held. An OS version or language the API would reject is left out, and a referrer above 4000 characters is reduced to its `lr_token`. It throws a `StateError` when the client was created without `platform`.

Report the install after the match, with a fixed event ID, so the event carries the matched click and repeated calls are one event:

```dart
final match = await runway.matchInstall(
  osVersion: osVersion, // for example from device_info_plus
  language: PlatformDispatcher.instance.locale.toLanguageTag(),
  referrer: referrer, // Android only; see below
);
final installId = await runway.installId();
if (match != null && installId != null) {
  await runway.track(EventType.install, eventId: 'install-$installId');
}
```

An INSTALL sent before the match is stored without the matched click, and later copies with the same ID are duplicates of that first one. If `matchInstall` throws (offline), try again on the next launch before sending INSTALL.

### Ad-network claims

Both run once per install and return a `ClaimResult` with a `status` (`submitted`, `alreadySubmitted` or `pending`) and the server's answer in `data`.

- `submitAdServicesToken(token)` posts Apple's AdServices token. While the server answers 202 (Apple does not know the token yet) the request is repeated three times, five seconds apart, then reported as `pending`. Call it again on a later launch; a token lasts 24 hours.
- `submitReferrerClaim(appId, referrer)` posts the raw Play install referrer. A 202 is reported as `pending` without retrying; `data['retryAfterSeconds']` says when to try again. An empty referrer sends nothing.

What the server verifies is described in [Apple measurement and network claims](https://linkrunway.com/resources/developers).

### Device attestation

`setAttestation(token, expiresAt)` takes the `attestation` and `expiresAt` of the [attestation endpoints](https://linkrunway.com/resources/developers)' answer and attaches the token to every event sent before it expires. It is kept in memory only, ignored without consent, and cleared when consent is withdrawn. The package never calls the attestation endpoints itself. If your app does, treat a 409 from `POST /v1/attest/challenge` as "attestation is off for this app" and stop asking for the session.

## Values only native code can read

These are suggestions for where the values can come from. None of these packages was installed or run with this package; check their own documentation.

- **Deep links**: `app_links`, as above.
- **Play install referrer**: a plugin that wraps Google's Install Referrer library, such as `play_install_referrer`. Pass the raw string to `matchInstall(referrer: …)` and, to let the server verify Google Ads or Meta evidence in it, to `submitReferrerClaim`.
- **AdServices token**: `AAAttribution.attributionToken()` on iOS 14.3 and newer, through a platform channel or a plugin you trust.
- **App Attest and Play Integrity**: a platform channel or plugin that exposes `DCAppAttestService` or the Play Integrity API, and the exchange in [device attestation](https://linkrunway.com/resources/developers).
- **OS version**: `device_info_plus` (`IosDeviceInfo.systemVersion`, `AndroidDeviceInfo.version.release`). `Platform.operatingSystemVersion` is not in the `major.minor` form the API accepts.

## Privacy notes

- No request and no storage write happens before consent, and withdrawal erases what was stored, including a write that was still waiting.
- State is stored in plain text in the store you provide. `shared_preferences` is not encrypted.
- The install ID is random and scoped to one storage entry. No advertising ID, device ID or hardware identifier is read.
- A publishable key is public. Events sent with it are never trusted for revenue or customer identity.

## Verified and not verified

Verified, with the official Dart SDK 3.13.5 (stable, macOS arm64, from Google's archive; the download matched its published SHA-256):

- `dart pub get` resolved `http` 1.6.0, `lints` 5.1.1 and `test` 1.33.0.
- `dart analyze --fatal-infos` reported no issues, with `package:lints/recommended.yaml`, strict casts, inference and raw types, and five more lint rules.
- `dart test` passed 37 tests on the Dart VM, using `MockClient` from `package:http/testing` and in-memory stores. They cover consent gating and erasure, writes waiting at withdrawal, a failing store, endpoint and key checks, link capture and resolution including the untracked result, events and the queue (retries, invalid events, conflicts, expired click tokens, non-JSON successes), shares and referral codes, the install ID, the match cache, attestation expiry, and the 202 claim rules.
- The same analysis and tests passed with `http` 1.2.2, the lowest version allowed.
- `dart format` reported no changes.

Not verified:

- **The package has never run in a Flutter app**, on a device, in a simulator, or in a browser build. The browser check for the user agent header and the behaviour of `package:http` on the web are untested.
- No Dart SDK other than 3.13.5 was used; the 3.7 minimum follows from the formatter settings and was not tested. With every dependency at its lowest allowed version (`dart pub downgrade`), the test runner does not build on Dart 3.13.5, because of old versions of its own dependencies.
- The `shared_preferences` adapter, `app_links` and every other package named above were not compiled or run.
- No test called a running API; the requests were checked against the documented contracts.
- Play Install Referrer, AdServices and App Attest or Play Integrity are not implemented here. They depend entirely on the values your app supplies.
