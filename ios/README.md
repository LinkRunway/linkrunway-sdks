# iOS and tvOS SDK

LinkRunway for iOS is a Swift package with no dependencies: Swift 6 language mode, iOS 15+, tvOS 15+, macOS 12+. This page describes version 0.2.1. [Mobile integration](https://linkrunway.com/resources/mobile) covers link domains, Associated Domains, and referral codes.

Three rules hold on every path. Nothing is stored or sent until your app calls `setConsent(true)`. Only a publishable key (`lr_pk_…`) is accepted. The endpoint must be HTTPS (or `localhost`).

Nothing here has run on a physical device. Read [What was verified](#what-was-verified) before relying on it.

## Install

Add the package in Xcode (File → Add Package Dependencies, then enter `https://github.com/LinkRunway/linkrunway-sdks`), or in a manifest:

```swift
.package(url: "https://github.com/LinkRunway/linkrunway-sdks", from: "0.2.1")
// target dependency: .product(name: "LinkRunway", package: "linkrunway-sdks")
```

Optional features need app-side setup that the SDK cannot do for you:

- Links: `applinks:go.example.com` in Associated Domains.
- App Attest: the App Attest capability on your App ID, and the app's Apple team and bundle IDs registered in LinkRunway.
- Postback copies: the Info.plist endpoints described in [measurement](https://linkrunway.com/resources/developers). The SDK updates conversion values; Apple sends the postbacks.

## Quick start

```swift
import LinkRunway

let runway = LinkRunway(
    endpoint: URL(string: "https://go.example.com")!,
    publishableKey: "lr_pk_your_key"
)
let appID = "your_app_id" // the app's ID in the LinkRunway console

// After your consent flow.
await runway.setConsent(true)

// On every launch. Each call does network work only while it still has some to do.
await runway.attest(appId: appID)                        // App Attest where supported; never throws
_ = try? await runway.configureConversions(appId: appID) // before the first event
if let match = try? await runway.matchInstall(), match.matched, let path = match.path {
    // Navigate with your own allowlisted routes.
}
try await runway.install()                               // INSTALL, once per installation
_ = try? await runway.submitAdServicesToken()            // Apple Search Ads, once

// Later.
try await runway.track(type: "SIGNUP", userId: user.id)
try await runway.track(type: "CUSTOM", name: "level_10")
await runway.recordConversion(event: "PURCHASE", amount: 4999)
```

The order matters on first launch:

1. `configureConversions` before the first event, so that `INSTALL` can update Apple's conversion value.
2. `matchInstall` before `install`, so that the INSTALL event carries a matched click.
3. `attest` first when the workspace requires attestation, because events wait for an attestation in progress.

`LinkRunway` is an actor, so every call is `await`ed. The package's tests compile and run this sequence.

## API

Calls made without consent send nothing and store nothing. They return `nil` (or an empty list), except `createShare` and `createReferralCode`, which throw `LinkRunwayError.consentRequired`. `configureConversions` and `attest` still remember the app ID in memory, so they take effect once consent is given.

| Call | Result | Notes |
| --- | --- | --- |
| `init(endpoint:publishableKey:suiteName:)` | | `suiteName` defaults to `LinkRunway` |
| `init(endpoint:publishableKey:suiteName:session:)` | | Sends every request through your `URLSession` |
| `setConsent(_:)` | | `false` clears stored state; see [On the device](#on-the-device) |
| `installId()` | `String?` | The random per-install UUID |
| `attributionToken()` | `String?` | The signed click token, for your authenticated backend |
| `open(_:)` | `ResolvedLink?` | Resolves a LinkRunway link and saves its click token |
| `matchInstall()` | `InstallMatch?` | First-launch match, resolved once per installation |
| `track(type:eventId:userId:metadata:occurredAt:)` | `TrackingResult?` | `INSTALL`, `OPEN`, `SIGNUP`, or `CUSTOM` |
| `track(type:name:eventId:userId:metadata:occurredAt:)` | `TrackingResult?` | The same with the event's custom name |
| `install()` | `TrackingResult?` | Sends `INSTALL` once, with a stable event ID |
| `configureConversions(appId:)` | `[ConversionRule]` | Loads the conversion mapping |
| `recordConversion(event:name:amount:)` | `ConversionUpdate?` | Updates Apple's conversion value only |
| `submitAdServicesToken()` | `AdServicesClaim?` | Apple Search Ads claim, once per installation |
| `attest(appId:)` | `AttestationStatus?` | App Attest; never throws |
| `createShare(linkId:userId:channel:)` | `SharedLink` | |
| `createReferralCode()` / `claimReferralCode(_:claimId:)` | `ReferralCode?` / `ResolvedLink?` | See [mobile integration](https://linkrunway.com/resources/mobile) |

Everything that existed in 0.1 keeps its signature, and an upgraded app keeps its stored click token and INSTALL marker. `track` refuses revenue events (`PURCHASE`, `SUBSCRIPTION`, `REFUND`). Report them from your backend with a server key.

Every event carries `installId`, and `attestation` while a token is cached. Requests use `Authorization: Bearer <publishable key>` and the user agent `LinkRunwaySDK/0.2.1 iOS` (or `tvOS`). Each request is tried three times, backing off on 429, 5xx, and network errors. If it still fails, it throws: `LinkRunwayError.server(status, body)` for an HTTP error, otherwise the `URLError`. When delivery matters, keep your own event IDs and timestamps and retry with the same ones.

## Install identity

`setConsent(true)` creates a random lower-case UUID the first time and keeps it in the SDK's `UserDefaults` suite. It identifies one installation of your app to LinkRunway. It is not the IDFA, not the IDFV, and not derived from the device. Withdrawing consent deletes it, and consent given again creates a new one. Read it with `installId()` when your backend needs to send it with server-key events.

## First-launch matching

`matchInstall()` sends `POST /v1/installs/match` with the install ID, the platform (`ios` or `tvos`), the OS version (major.minor), the preferred language, and `consent: true`. It returns an `InstallMatch`:

- `matched`
- `method`: `.referrer`, `.probabilistic`, `.viewThrough`, `.unmatched`, or `.unknown` for a method newer than this SDK
- `clickId`, `path`, `url`, and `metadata`

Behaviour:

- On a match the click token is saved exactly as `open(_:)` saves it, so later events carry it. Call `matchInstall()` before `open(_:)` on first launch; a link opened afterwards replaces the token.
- The answer is stored. Later calls, concurrent calls, and later launches return it without a request. A failed request stores nothing and can be retried; the server gives the same install ID the same answer.
- Matching happens on the server, and only when the workspace owner turned it on: `probabilisticMinutes` for clicks, `viewThroughHours` for ad impressions. Both default to off, and then every answer is unmatched. [Attribution](https://linkrunway.com/resources/attribution) describes what the server compares.
- An app updated from 0.1 has never asked, so its first call makes one request.

## Automatic conversion updates

`configureConversions(appId:)` fetches the app's mapping from `GET /v1/mobile/config/<appId>`, stores it, and refreshes it at most once a day. A mapping from an earlier day keeps working while a refresh fails. After a failed fetch, events wait five minutes before triggering another. From then on:

- after every successful `track`, the event's type and name are matched against the rules;
- `recordConversion(event:name:amount:)` does the same for something LinkRunway learns elsewhere, such as a purchase your backend reports. `amount` is in minor units. It sends nothing to LinkRunway.

**Choosing a rule.** A rule applies when:

- its event type equals the event's,
- its name, if it has one, equals the event's name, and
- its `minAmount` is not above the amount.

Among the rules that apply, the highest `minAmount` wins. Ties go to a named rule over an unnamed one, then to the higher fine value, then to the earlier rule. Rules this SDK cannot read (a fine value outside 0–63, an unknown coarse value) are skipped.

**Never lower.** The SDK remembers the highest fine value it has handed to Apple and drops any rule below it. An equal value is sent again. `lockWindow` is passed only when the chosen rule sets it.

**Order.** Updates are queued and reach Apple one at a time, in the order they were requested. `track` returns as soon as the event is recorded and does not wait for the queue. `recordConversion` returns once its own update has been handed over. In the Simulator the first SKAdNetwork call took about five seconds. An update still queued when consent is withdrawn is dropped.

| OS | What is called |
| --- | --- |
| iOS 17.4 and later | SKAdNetwork `updatePostbackConversionValue(_:coarseValue:lockWindow:)` and AdAttributionKit `Postback.updateConversionValue(_:coarseConversionValue:lockPostback:)` |
| iOS 16.1 – 17.3 | `SKAdNetwork.updatePostbackConversionValue(_:coarseValue:lockWindow:)` |
| iOS 15.4 – 16.0 | `SKAdNetwork.updatePostbackConversionValue(_:)`: fine value only |
| iOS 15.0 – 15.3 | `SKAdNetwork.updateConversionValue(_:)`: fine value only, no result reported |
| Mac Catalyst | As iOS; compiled, never run |
| tvOS, macOS | Nothing. `configureConversions` returns an empty list and fetches nothing |

On iOS 17.4 and later the SDK calls both frameworks, as Apple advises for apps measured through both. AdAttributionKit is weak-linked, so the app still launches on iOS 15 and 16.

The order of the two calls depends on the lock. According to Apple's documentation, SKAdNetwork mirrors each of its updates into AdAttributionKit with only the fine value and the lock. So:

- By default SKAdNetwork goes first and the complete AdAttributionKit call comes last.
- A rule that locks the window goes to AdAttributionKit first, so that postback locks with the coarse value too.

`ConversionUpdate.frameworks` lists the frameworks that accepted a call, in the order they were called. In the Simulator both refuse (`SKANErrorDomain` 10, and "feature is not supported"), so the list is empty there.

Limits to know:

- Apple asks apps to call the update API at first launch to register the installation. The SDK sends only values a rule defines, so add an `INSTALL` rule with fine value 0 and call `install()` on first launch.
- The high-water mark covers the whole life of the installation, not each SKAdNetwork conversion window. In the second and third windows Apple uses only the coarse value, and an update is sent only for a rule at or above the highest fine value already sent. Per-window mappings are not implemented.
- Withdrawing consent deletes the high-water mark with everything else. After consent is given again, an update can be lower than one sent before the withdrawal.
- AdAttributionKit conversion tags and re-engagement conversion types (iOS 18+) are not used; each update applies to all postback types.

## Apple Search Ads

`submitAdServicesToken()` reads `AAAttribution.attributionToken()` and posts it with the install ID to `POST /v1/claims/apple-ads`. LinkRunway asks Apple; campaign data comes only from Apple's answer. See [ad networks](https://linkrunway.com/resources/developers).

| Result | Meaning |
| --- | --- |
| `.submitted` | The server accepted the token. Not asked again for this installation |
| `.alreadySubmitted` | An earlier call completed; nothing was sent |
| `.pending` | The server answered 202 after three retries. Call again later, for example on the next launch |
| `.unavailable` | No token: tvOS, macOS, the Simulator, or an AdServices error |

A 202 means Apple has not processed the token yet. The SDK retries at most three times, five seconds apart unless the server names another interval (capped at thirty seconds). Other failures throw and leave the claim open for a later call.

## App Attest

`attest(appId:)` follows [device attestation](https://linkrunway.com/resources/developers):

1. Without a usable cached token, it requests a challenge. The challenge comes first, so a declined request creates no key.
2. First time: `generateKey()`, then `attestKey` with the SHA-256 of the challenge text, then `POST /v1/attest/apple/register`.
3. Afterwards: `generateAssertion` with the same hash, then `POST /v1/attest/apple/assert`.
4. The returned token is stored and attached to every event until it expires. The next event after expiry renews it first, provided `attest(appId:)` was called in this process.

It never throws. When no token is available, events are sent unattested.

| Result | Meaning |
| --- | --- |
| `.attested` | A token is cached and attached to events |
| `.unsupported` | `DCAppAttestService.isSupported` is false: the Simulator, a Mac, most app extensions. Nothing is requested |
| `.disabled` | The challenge was answered 409: the owner turned attestation off for this app. Nothing more is requested until the next launch, and nothing is stored |
| `.failed(reason)` | The attempt did not complete. The SDK waits before trying again |

An event sent while an attempt is running waits for it, so that the first events of an installation can carry a token. If the attempt fails, the event goes out unattested.

Apple limits how many keys a device may create, so the SDK replaces a key only when it cannot be used:

- **Assertion answered 404.** The server does not know the key. A new key is generated and registered in the same call. This is the only server answer that replaces a key.
- **Assertion answered 400 or any other error.** A 400 means the challenge or the proof was rejected, for example more than five minutes between challenge and assertion. The key is kept, and the next attempt, after the wait, asserts again for a fresh challenge.
- **Registration refused, or sent without an answer.** The key is kept. Apple attests a key only once, so the next attempt asserts with it; if the server answers 404, a new key follows.
- **Key unusable on the device.** If the device reports the key is gone (`DCError.invalidKey`, after a reinstall, device migration, or restore), or `attestKey` fails for a reason other than an Apple outage, the key is discarded, as Apple directs.
- **Apple's service unreachable during `attestKey`.** Retried twice with the same key and hash, then the unattested key is kept for the next attempt.

After any failure the SDK waits five minutes before the next attempt, doubling up to about five hours. The wait is stored, so a new launch does not start over; a success clears it. A new token is used for at least five minutes even if the device clock says it has already expired.

Apple advises introducing App Attest gradually to a large audience. The SDK does not pace that for you.

## tvOS and macOS

- tvOS: `matchInstall()` sends `platform: "tvos"` and the user agent ends in `tvOS`. Events, links, shares, referral codes, and App Attest compile and behave as on iOS. SKAdNetwork, AdAttributionKit, and AdServices do not exist on tvOS, so conversion updates and the Search Ads claim are no-ops.
- `open(_:)` sends `platform: "ios"` on every Apple platform, because `/v1/resolve` accepts only `ios`, `android`, and `web`.
- macOS is supported so the package builds and tests on a Mac. A macOS build reports itself as iOS and has no conversion updates, Search Ads claim, or App Attest.

## On the device

Everything lives in one `UserDefaults` suite, under keys scoped to the endpoint and the first 20 characters of the publishable key.

| Value | Kept while consent is on | After withdrawal |
| --- | --- | --- |
| Signed click token | Yes | Removed |
| Install ID | Yes | Removed |
| First-launch match (without the token) | Yes | Removed |
| Conversion mapping and highest fine value sent | Yes | Removed |
| App Attest key ID and attestation token | Yes | Removed |
| Wait before the next App Attest attempt, after a failure | Yes | Removed |
| `INSTALL` event ID | Yes | Removed |
| Three booleans: `INSTALL` sent, first launch matched, Search Ads claim made | Yes | Kept |

The three booleans stay so that consent given again does not report the same installation twice. They hold no identifier. A response that arrives after consent was withdrawn is discarded, even if consent has been given again in the meantime. Withdrawal also means a new App Attest key on the next attestation.

## Privacy

- The SDK does not read the IDFA or IDFV, the pasteboard, contacts, location, or any hardware identifier, and it does not request App Tracking Transparency. Whether your app needs that prompt depends on what your app does with data.
- The SDK builds no device fingerprint. The match request carries the install ID, platform, OS version, and preferred language. When the owner enabled probabilistic matching, the server also pairs a keyed hash of the request's network address with a recent click. That is an estimate. Decide whether your consent notice and Apple's policies allow it before turning it on.
- Conversion values go to Apple's on-device APIs, not to LinkRunway. The AdServices token goes to LinkRunway and from there to Apple.
- Consent is your app's decision to record. The SDK enforces it but does not present a prompt.

## Testing your integration

Pass a `URLSession` whose configuration lists a `URLProtocol` stub to `init(endpoint:publishableKey:suiteName:session:)`, and no request leaves the process. The package's own tests do this in `Tests/LinkRunwayTests/CompatibilityTests.swift`.

```sh
swift test   # from the repository root
ios/Scripts/verify.sh /path/for/build/output
```

`verify.sh` builds and tests on macOS, compiles for iOS and tvOS (device and Simulator), and fails on any compiler warning.

## What was verified

Verified on one Mac (macOS 26.0, Xcode 26.0.1, Swift 6.2):

- 86 unit tests pass with `swift test` on macOS and in an iOS 26.0 Simulator (iPhone 17 Pro). The network is always stubbed. They cover:
  - rule selection, the never-lower rule, and update ordering;
  - request paths, headers, and bodies for every endpoint;
  - consent gating and withdrawal;
  - the 202 retry rule and the stored match;
  - the App Attest key lifecycle, including a 404 versus a 400 to an assertion and attestation turned off (409).
- The package compiles with warnings treated as errors:
  - with `xcodebuild` for the iOS Simulator, an iOS device, and Mac Catalyst;
  - with SwiftPM against Xcode's tvOS device and Simulator SDKs, because Xcode lists no tvOS destination until its tvOS platform component is installed.
- In the iOS Simulator the real system calls were made. SKAdNetwork and AdAttributionKit refuse the update, AdServices returns no token, and App Attest reports unsupported. The SDK handles each as documented above.
- The test bundle links AdAttributionKit weakly, with a deployment target of iOS 15.0.

Not verified:

- Any physical iPhone, iPad, or Apple TV, and any OS older than 26.0. The iOS 15 and 16 code paths compile but have never run.
- A real SKAdNetwork or AdAttributionKit postback. No conversion value sent by this SDK has been observed in a postback, and the call order around locking rests on Apple's documentation alone.
- A real App Attest key, attestation, or assertion. The flow ran only against a fake service.
- A real AdServices token or Apple Search Ads attribution.
- A running LinkRunway API. Stubbed tests checked the requests against the contracts; no server was involved.
- tvOS at run time. No tvOS Simulator runtime was installed; the tvOS build is a compile check only.
- App Store review. Nothing here certifies that an app using these features will pass review.
