# Android SDK

LinkRunway for Android is the client for Android phones, tablets and Android TV (version `0.2.0`, minSdk 23). It resolves link opens, reports non-revenue events, resolves an install's first launch, forwards the Play install referrer for ad-network verification, and attaches a Play Integrity attestation to events.

Read [What was verified](#what-was-verified) before relying on it: everything below was exercised with JVM tests, local test servers and one emulator, not with a Play-distributed install, a real Play Integrity verdict or a real device.

## Installation

The module builds with its Gradle wrapper (Gradle 8.11.1), JDK 17, Android Gradle Plugin 8.9.3, Kotlin 2.1.20 and compile SDK 35.

**From JitPack.** Add the repository in `settings.gradle.kts`:

```kotlin
dependencyResolutionManagement { repositories { google(); mavenCentral(); maven("https://jitpack.io") } }
```

and in the app module:

```kotlin
dependencies {
    implementation("com.github.LinkRunway:linkrunway-sdks:0.2.0")
}
```

**As a source build** (what `examples/android` does): `includeBuild("../path/to/linkrunway-sdks/android")` in the app's `settings.gradle.kts`, then `implementation("com.linkrunway:linkrunway-android")`.

**As an AAR file.** `./gradlew assembleRelease` writes `build/outputs/aar/linkrunway-android-release.aar`. A file dependency carries no dependency list, so add the SDK's two runtime libraries yourself:

```kotlin
dependencies {
    implementation(files("libs/linkrunway-android-release.aar"))
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("com.android.installreferrer:installreferrer:2.2")
}
```

**Optional, for attestation:** `implementation("com.google.android.play:integrity:1.6.0")`. The SDK compiles against Play Integrity but does not ship it; see [Device attestation](#device-attestation-with-play-integrity).

The SDK's manifest adds `INTERNET`; the Install Referrer library adds `com.google.android.finsky.permission.BIND_GET_INSTALL_REFERRER_SERVICE`. No other permission is requested. The AAR's consumer R8 rules let a minified app build with or without Play Integrity; no keep rules are needed.

Endpoints must use HTTPS. Plain `http://` is accepted only for `localhost` and `10.0.2.2` (the emulator's host) during development; on Android 9 and later the app must also allow cleartext to that host in its network security configuration. Only publishable keys (`lr_pk_…`) are accepted. Revenue and refunds are reported by your server, never by the app.

## Quick start

```kotlin
val runway = LinkRunway(applicationContext, "https://go.example.com", "lr_pk_your_key",
    attestation = PlayIntegrityAttestation(applicationContext, cloudProjectNumber = 123456789012))

// After your consent flow, on every start. Nothing is read, stored or sent before this.
runway.setConsent(true)

lifecycleScope.launch {
    // A LinkRunway link that opened this activity.
    intent.data?.let { runway.open(it.toString()) }
    // Once per install; later calls return the stored answer without a request.
    val match = runway.matchInstall(applicationContext)
    if (match?.matched == true && !match.cached) match.path?.let(::routeIfAllowed)
    runway.install(applicationContext)                 // INSTALL, once per install
    runway.submitReferrerClaim("your_console_app_id")  // never throws for network or server errors
    runway.attest("your_console_app_id")               // never throws; reuses a valid attestation
    runway.track(type = "OPEN")
}
```

`examples/android` is a one-screen app with this flow behind a consent checkbox. Build it with the SDK's wrapper: `android/gradlew -p examples/android assembleRelease`. Its endpoint, key and app ID are placeholders; pass `-Plinkrunway.endpoint=… -Plinkrunway.key=… -Plinkrunway.appId=…`, and `-Plinkrunway.cloudProjectNumber=…` to package Play Integrity.

## API

All network calls suspend; call them from a coroutine. `appId` is the app's ID in the LinkRunway console.

| Member | Behaviour |
| --- | --- |
| `LinkRunway(context, endpoint, publishableKey, attestation = null, transport = UrlConnectionTransport())` | Throws `IllegalArgumentException` for a non-publishable key or a non-HTTPS endpoint. Detects Android TV. |
| `setConsent(value)` | `true` loads stored state. `false` erases it (see [Privacy](#privacy)) and makes every call a no-op. |
| `installId(): String?` | This install's random UUID, created on first use; `null` without consent. |
| `attributionToken(): String?` | The current signed click token, for your backend to bind to an authenticated user. |
| `captureReferrer(referrer)` | Keeps the `lr_token` from an install referrer you read yourself. |
| `open(url): JSONObject?` | A URL carrying `lr_token` is captured locally and returns `null`; otherwise `POST /v1/resolve` and keeps the returned token. An `untracked` answer (plan click allowance reached) leaves the current token. |
| `track(type, eventId, userId, metadata, occurredAt): JSONObject?` | `INSTALL`, `OPEN`, `SIGNUP` or `CUSTOM` only. Sends the click token, `installId` and a valid attestation. |
| `createShare(linkId, userId, channel)` | Unchanged; throws without consent. |
| `install(context): JSONObject?` | Resolves the first launch, then sends INSTALL once with a stable event ID. Returns `null` once delivered. |
| `matchInstall(context): InstallMatchResult?` | First-launch matching; see below. |
| `installMatch(): InstallMatchResult?` | The stored answer, or `null` while the server still has to be asked. No request. |
| `submitReferrerClaim(appId): ReferrerClaimResult?` | Forwards the raw Play referrer once per install. |
| `attest(appId): AttestationResult?` | Play Integrity attestation, cached until it expires. |
| `createReferralCode()`, `claimReferralCode(code, claimId)` | Unchanged explicit deferred codes (see [Mobile integration](https://linkrunway.com/resources/mobile)). |
| `LinkRunway.VERSION` | `"0.2.0"`, sent as `User-Agent: LinkRunwaySDK/0.2.0 Android` (or `AndroidTV`). |

Without consent no call makes a request: they return `null` (`captureReferrer` does nothing), except `createShare` and `createReferralCode`, which throw `IllegalStateException`.

Results:

- `InstallMatchResult(matched, method, clickId, path, url, metadata, cached)`; `method` is `REFERRER`, `PROBABILISTIC`, `VIEW_THROUGH`, `NONE`, or `UNKNOWN` for a method added by a newer server. The click token is not part of it.
- `ReferrerClaimResult(status, networks, error)`; `status` is `SUBMITTED`, `ALREADY_SUBMITTED`, `PENDING`, `NO_REFERRER` or `FAILED`; `networks` maps each network the server checked to its answer, for example `GOOGLE_ADS` to `RECORDED`.
- `AttestationResult(status, expiresAt, cached, error)`; `status` is `ATTESTED`, `NO_PROVIDER`, `OFF` (the app's attestation mode is OFF) or `FAILED`.

Errors and retries: every request is tried three times. A 429, a 5xx or a transport failure waits 300 ms, then 600 ms. Redirects are not followed. After the third failure, `open`, `track`, `install`, `matchInstall`, `createShare` and the referral-code calls throw `LinkRunwayException(status, message)` (the server's `message`) or the `IOException`. Withdrawing consent stops a retry loop with `IllegalStateException("Consent was withdrawn")`. `submitReferrerClaim` and `attest` report failures in their result and never throw for them. Keep event IDs and `occurredAt` in your own durable job when delivery matters; the SDK does not queue events.

`HttpTransport` (`suspend fun send(HttpRequest): HttpResponse`) replaces the network layer, for your own HTTP stack or for tests. Return every HTTP status as a response, throw `IOException` for transport failures, and do not follow redirects. The request headers carry the publishable key; do not log them.

## First-launch matching

`matchInstall(context)` reads the Play install referrer and calls `POST /v1/installs/match`:

```json
{ "installId": "<uuid>", "platform": "android", "osVersion": "14", "language": "en-US",
  "referrer": "<raw Play install referrer>", "consent": true }
```

The server tries, in order: the signed LinkRunway token in the referrer (`REFERRER`), then probabilistic click matching and view-through, each only when the workspace owner enabled it, then `NONE`. See [Attribution](https://linkrunway.com/resources/attribution). `osVersion` is sent only as `major[.minor[.patch]]`, and `language` is the system language without extension or private-use subtags; either is left out when Android reports another format. A referrer longer than the contract's 4,000 characters is reduced to its `lr_token`.

- **Once per install.** The answer is stored without its click token. Later calls, also after a restart, return it with `cached = true` and make no request. Concurrent calls share one request.
- **Click token.** A matched click's token is kept for later events, unless a link opened since then already set one: the most recent touch stays.
- **Failures.** `matchInstall` throws when the request fails or when Play cannot be read; nothing is stored, so the next call asks again. It never asks without the referrer after a failed read, because that would fix an unmatched answer for this install.
- **`install(context)`** runs the same match first. If the match request fails, INSTALL is still sent, carrying the referrer's own `lr_token` as 0.1 did. If Play cannot be read, `install` throws and the next call retries with the same event ID.
- **First launch only.** Once the match was resolved, or INSTALL was delivered (including by SDK 0.1), the server is not asked again. A match erased by a consent withdrawal reads as `NONE`, so the install is never matched again under a new identity.

The referrer is read from Play once per process and kept in memory only, never stored, as Google asks apps to call the API sparingly. The read times out after 30 seconds. A device without the Play Store answers `FEATURE_NOT_SUPPORTED`; the SDK treats that as no referrer, and the match runs without one. Other Install Referrer errors throw.

## Referrer claims

`submitReferrerClaim(appId)` sends the raw referrer to `POST /v1/claims/referrer` (`{ installId, appId, referrer, consent: true }`). The server, not the SDK, looks for ad-network evidence in it: Meta's encrypted payload (needs the app's Meta Install Referrer Decryption Key in the console) and a Google click ID (needs a Google Ads connection). See [Apple privacy measurement and network claims](https://linkrunway.com/resources/developers).

- `SUBMITTED`: the server gave its final answer, in `networks`. Nothing is sent again for this install.
- `PENDING`: the server answered 202 because Google has not reported the click yet. The SDK stores when to try again (the server's `retryAfterSeconds`, held between 1 minute and 24 hours) and a later call sends the same referrer again. Two days after the first pending answer the SDK stops, because the server only looks clicks up for the account's today and yesterday.
- `NO_REFERRER`: Play has no referrer; nothing is sent.
- `FAILED`: an unusable `appId`, an unreadable referrer, a referrer over 8,000 characters, or a request failure; `error` says which. The next call tries again.

The claim and the match share one referrer read. A claim never blocks or fails `install`, in either order.

## Device attestation with Play Integrity

`attest(appId)` requests a challenge (`POST /v1/attest/challenge`), asks the `AttestationProvider` for a token bound to

```text
nonce = base64url_nopad( SHA-256( utf8(challenge) + "." + utf8(installId) ) )
```

and exchanges it at `POST /v1/attest/play` for a server attestation. That attestation is stored and sent in the `attestation` field of every `track` call until one minute before its `expiresAt` (24 hours). A valid stored attestation is reused without a request, so calling `attest` on every start is cheap. The server only marks events as attested; an event without an attestation is still accepted. Whether it keeps its attribution depends on the app's attestation mode in the console ([Device attestation](https://linkrunway.com/resources/developers)).

When the owner set the app's attestation mode to OFF, the challenge endpoint answers 409. `attest` then returns `OFF` without an error, asks nothing more for that app until the process restarts, and events are sent unattested. The provider is not asked.

Failures return `FAILED` and never block tracking. After the provider was asked and the attempt failed, the SDK waits five minutes (in this process) before spending another token. A provider gets 60 seconds to answer. The exchange is not retried after a 5xx, because the server spends a challenge on its first look. A missing Play Integrity library is reported as `FAILED` with `NoClassDefFoundError`.

Setup:

1. In Play Console, open the app → Protected with Play → Play Integrity API, and link a Google Cloud project (this enables the API in that project).
2. Note that project's **project number** (Google Cloud console, project dashboard). Each request names it.
3. Add `com.google.android.play:integrity:1.6.0` to the app and pass `PlayIntegrityAttestation(context, cloudProjectNumber)` to the constructor. Create it once.
4. In the LinkRunway console, store the app's Play Integrity credentials and start in `MONITOR` mode ([Owner configuration](https://linkrunway.com/resources/developers)).

`PlayIntegrityAttestation` modes:

- `CLASSIC` (default): the nonce is the classic request's `nonce`. The server can verify it whether Google decodes tokens or the workspace stores its own response encryption keys.
- `STANDARD`: the nonce is the standard request's `requestHash`. Only Google can decode these tokens, so the app's LinkRunway credentials must use Google decoding. The provider prepares one token provider and reuses it; when Play reports it expired (`INTEGRITY_TOKEN_PROVIDER_INVALID`) it prepares a new one once.

To use your own Play Integrity setup, implement `AttestationProvider.token(nonce)` and throw on failure.

**Quotas.** Google's published defaults: 10,000 token requests per app per day, shared between classic requests and standard token preparations, and 10,000 decryptions on Google's servers per day; per app instance, 5 classic requests and 5 standard warm-ups per minute. Google advises keeping classic requests to infrequent, high-value actions. With this SDK, a device that calls `attest` daily spends about one token request (and, when Google decodes, one server-side decryption) per day, so the default quota covers roughly 10,000 attesting devices a day. Request an increase from Google before that, or attest only some installs. The server accepts only a build Play recognizes (`PLAY_RECOGNIZED`) on a device that meets device integrity. Debug and sideloaded builds are not recognized; Play Console can send test responses to testers, which the server accepts only with `allowTestResponses`. Sources: [setup](https://developer.android.com/google/play/integrity/setup), [classic](https://developer.android.com/google/play/integrity/classic), [standard](https://developer.android.com/google/play/integrity/standard), [error codes](https://developer.android.com/google/play/integrity/error-codes).

## Android TV

A device with the leanback feature (`PackageManager.FEATURE_LEANBACK`) is reported as platform `androidtv`, with the user agent `LinkRunwaySDK/0.2.0 AndroidTV`, which the API recognizes as the SDK. Everything else works as on a phone, with these differences:

- The server never applies probabilistic click matching to `androidtv`. The referrer token and view-through from CTV impressions still apply.
- A TV without the Play Store (for example a device with another app store) has no install referrer: matching runs without one and claims return `NO_REFERRER`.
- `open()` reports `android`, because `POST /v1/resolve` accepts only `ios`, `android` and `web`.
- Play Integrity on a TV depends on the device having Google Play services; it was not tested on one.

## Privacy

Without consent the SDK reads, stores and sends nothing. It does not read the advertising ID, the Android ID, IMEI, serial number, MAC address or any other hardware identifier, does not read the clipboard, and does not fingerprint devices.

The install ID is a random UUID created by the SDK. It is not an advertising or device identifier, and it is not derived from the device. It changes on reinstall, on clearing app data, on consent withdrawal, and when the app's data is restored onto another install.

The `linkrunway` SharedPreferences file holds, per endpoint and key: the install ID, the click token, the match answer without its token, the attestation token with its expiry, the pending INSTALL event ID, a pending claim's retry times, three booleans (INSTALL delivered, first launch resolved, referrer claimed), and the backup `guard` flag described below. Withdrawing consent erases everything except those four booleans, which identify nothing and keep one install from being reported twice. The referrer itself is never stored.

Auto Backup and device-to-device transfer copy SharedPreferences to other installs. The SDK pairs its file with an empty marker file in the no-backup directory, which Android never copies. State that arrives without the marker is discarded, so a restored install starts with its own identity.

The match request carries the OS version and system language, and every request reaches the server from the device's network address. Probabilistic matching is done on the server, only when the workspace owner enabled it, with a keyed hash of that address, the OS family and the language ([Attribution](https://linkrunway.com/resources/attribution)). Decide whether your consent notice and Google Play's policies, including your Data safety form, cover this. This document makes no compliance claim.

## What was verified

Run from `android`:

```sh
./gradlew testDebugUnitTest                # JVM tests, Robolectric
./gradlew assembleRelease                  # release AAR
./gradlew connectedDebugAndroidTest        # on-device smoke test; needs a device or emulator
```

- **JVM unit tests** (Robolectric 4.16.1, Android 14 and Android 6): request paths, headers and bodies for match, claim, attestation and track; the nonce against vectors computed separately with `openssl`, Node and Python; consent gating and erasure; one-time match, INSTALL and claim; claim pending and two-day limit; retry on 429, 5xx and transport errors; Android TV detection; backup restore; upgrade from 0.1 storage; the default transport against a local HTTP server; the real Play Integrity library on a simulated device without the Play Store.
- **Release assembly** of the AAR, and R8-minified release builds of `examples/android` with and without Play Integrity, from source and from the AAR file.
- **Instrumented smoke test** on an Android 16 emulator (Google Play system image, no Google account): the default transport, real SharedPreferences, the real Install Referrer client, the backup marker, and Play Integrity. Play returned `utm_source=google-play&utm_medium=organic` for the sideloaded test app. On the first run, just after the emulator booted, the referrer read hit the then 10-second timeout while the Play Store started; the timeout is now 30 seconds, and the second run passed all four tests. Play Integrity did not issue a token there: the classic request failed with `-3` (`NETWORK_ERROR`), and the standard request hit the SDK's 60-second provider timeout. Tracking continued in both cases.

Not verified: real phones, tablets or TVs; an install from Google Play whose referrer carries a LinkRunway token; a real Play Integrity token and its acceptance by the server; Meta or Google claims end to end; a running LinkRunway API (requests were checked against the server's contracts and code, with local test servers); Play review and Data safety. No store or device certification is claimed.
