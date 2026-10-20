# JavaScript SDK (`@linkrunway/sdk`)

A typed client for browsers, Node.js backends, and any other runtime with `fetch`. It is the core that the [React Native and Expo packages](../react-native/README.md) build on. It contains no native code and reads nothing from the device: no advertising ID, no fingerprint, no clipboard.

Install it with `npm install https://github.com/LinkRunway/linkrunway-sdks/releases/download/0.2.1/linkrunway-sdk-0.1.0.tgz`. The package ships ES module and CommonJS builds with type declarations and has no dependencies.

## Setup

```ts
import { LinkRunway } from '@linkrunway/sdk';

const runway = new LinkRunway({
  endpoint: 'https://go.example.com', // your link domain; HTTPS is required outside localhost
  apiKey: 'lr_pk_your_key', // publishable in apps and pages, server key only on a backend
  consent: false,
});

// After your consent flow:
runway.setConsent(true);
runway.capture(window.location.href); // keeps lr_token from the redirect
await runway.track({ eventId: crypto.randomUUID(), type: 'OPEN' });
```

| Option       | Default                       | Purpose                                                                                                                                         |
| ------------ | ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `endpoint`   | required                      | Base URL of the app API. `http` is accepted only for `localhost` and `127.0.0.1`.                                                               |
| `apiKey`     | required                      | `lr_pk_…` or `lr_sk_…`. A server key is refused wherever `window` exists (pages and React Native).                                              |
| `consent`    | required                      | Initial consent. Change it with `setConsent`.                                                                                                   |
| `storage`    | `localStorage` when it exists | Any object with synchronous `getItem`, `setItem`, `removeItem`. Without one the client keeps state in memory.                                   |
| `fetch`      | global `fetch`                | Injected transport, for tests or a custom agent.                                                                                                |
| `retries`    | `2` (0 to 5)                  | Retries of a request that failed on the network, with a 429, or with a 5xx. Backoff is 300 ms doubling, capped at 3.1 s; each attempt has 10 s. |
| `userAgent`  | none                          | Sent as the `User-Agent` header outside browsers. See below.                                                                                    |
| `randomUUID` | the runtime's `crypto`        | Source of the install ID. See [Install identity](#install-identity-and-first-launch-match).                                                     |

The SDK routes (`track`, `shares`, `resolve`, `deferred`, `deferred/claim`, `installs/match` and the two `claims` routes) answer browser calls from any origin, without cookies. Every other route, including the console's cookie routes, answers only the console origin. CORS is not authorization: a publishable key only permits unverified, non-financial events, and server keys belong on servers.

`userAgent` exists for wrappers that identify themselves as `LinkRunwaySDK/<version> <platform>`, which the API recognizes and never classifies as a bot. A page or worker cannot set this header, and trying would turn each call into a preflight the API rejects, so the option is ignored when `document` or `WorkerGlobalScope` exists. It must be 1 to 200 printable ASCII characters.

## Consent and stored state

Without consent the client makes no request and writes nothing. `track` resolves `{ skipped: true }`, `createShare` and `createReferralCode` reject, and the other calls return `undefined`.

While consent is on, one storage entry (`linkrunway:<endpoint origin>:<first 20 characters of the key>`) holds:

- the signed click token,
- the install ID,
- up to 100 undelivered events,
- the stored first-launch match, without its token,
- which ad-network claims were already submitted.

`setConsent(false)` deletes that entry and clears the same state from memory. `setConsent(true)` after a start without consent loads what an earlier session saved, so a page that waits for a consent manager on every load keeps its attribution. A response that arrives after consent was withdrawn is discarded, even if consent was granted again in the meantime.

## Links and attribution

| Call                        | Behaviour                                                                                                                                                                                          |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `capture(url)`              | Saves the `lr_token` query parameter of a URL (at most 1500 characters). Throws a `TypeError` for a string that is not a URL.                                                                      |
| `captureReferrer(referrer)` | The same for a Play install referrer string.                                                                                                                                                       |
| `attributionToken()`        | The saved token, or `undefined` without consent. Send it to your backend through an authenticated request and report signup and revenue from there with a server key.                              |
| `open(url, platform?)`      | Resolves a `/l/<key>` link through `POST /v1/resolve` (`platform` is `ios`, `android` or `web`) and saves the returned token. Returns `{ clickId, clickToken?, path, url, metadata, untracked? }`. |

`open` replaces the saved token with the one for the new click. When the server declines to attribute the visit (a bot, a privacy signal, a blocked source) there is no token and the saved one is cleared. When the workspace is over its click allowance the answer has `untracked: true` and an empty `clickId`: the link still routes, no click was recorded, and the saved token is left as it was.

Treat `path` and `metadata` as input: route only to paths your application allowlists.

## Events and the offline queue

```ts
const result = await runway.track({ eventId, type: 'SIGNUP', externalUserId: user.id });
// { id, attributed, duplicate } | { queued: true } | { skipped: true }
```

`track` adds `occurredAt` (now, unless given), the saved click token and the install ID. Types are `INSTALL`, `OPEN`, `SIGNUP`, `PURCHASE`, `SUBSCRIPTION`, `REFUND` and `CUSTOM`; financial types need a server key.

- A network failure, a 429 or a 5xx (after the retries) puts the event in the queue and resolves `{ queued: true }`. The queue keeps the newest 100 events with their original ID and time. It is not a durable financial delivery system.
- Any other 4xx rejects with a `LinkRunwayError` (`status`, `message`) and is not queued.
- A successful status whose body is not a JSON object (a captive portal, a proxy page) is treated as a network failure, never as delivered.

`flush()` sends the queue in order and is safe to call concurrently. An event the API rejects as invalid (400 or 422) is dropped so it cannot block the rest; a 409 stays for the next flush; any other failure stops the flush with the queue intact. After a pass that dropped or kept an event, `flush()` rejects with the first such error.

A signed click token expires with the workspace's attribution window, and the API answers 400 for an event that carries an expired one. With a publishable key the client then sends the event once more without the token. If that is accepted, the token was the reason: it is forgotten, and later events are sent unattributed instead of failing. With a server key the 400 is returned to the caller, because the backend supplied that token.

## Shares and referral codes

`createShare({ linkId, externalUserId?, channel? })` returns `{ shareId, url }`. `createReferralCode()` and `claimReferralCode(code, claimId)` are described in [mobile integration](https://linkrunway.com/resources/mobile).

## Install identity and first-launch match

These calls are for app runtimes (React Native, Capacitor, Electron) and need a publishable key. With a server key `installId()` returns `undefined` and the other calls reject, because a backend is not an install. A backend may forward an app's install ID explicitly as `installId` on an event.

- `installId()` returns a random version 4 UUID. It is created on first use, saved with the rest of the state, sent with every event, and deleted when consent is withdrawn; a later grant starts a new one. It is not derived from the device.
- `matchInstall({ platform, osVersion?, language?, referrer? })` asks `POST /v1/installs/match` once which earlier touch led to this install, as described in [attribution](https://linkrunway.com/resources/attribution). The answer is stored, so later calls return it with `cached: true` and make no request; concurrent calls share one request. `platform` is `ios`, `android`, `tvos` or `androidtv`.
- `installMatch()` returns the stored answer, if there is one.

Send INSTALL only after `matchInstall` has resolved, with a fixed event ID such as `install-<installId>`. An INSTALL sent before the match is stored without the matched click, and later copies with the same ID are duplicates of that first one.

The match's click token is saved unless a token is already held: a link the user opened is a later touch than the click that led to the install. An OS version or language the API would reject is left out instead of failing the request, and a referrer above the 4000-character limit is reduced to its `lr_token`.

The ID comes from `crypto.randomUUID()`, or `crypto.getRandomValues()`. A runtime with neither (React Native without a polyfill) falls back to `Math.random()`, which is not cryptographically strong. The server returns an install's stored match to whoever presents its ID, so pass `randomUUID` there (for example `randomUUID` from `expo-crypto`).

Withdrawing consent deletes the stored match together with the ID. A later grant is a new install as far as the SDK knows, and `matchInstall` will ask the server again.

## Device attestation

`setAttestation(token, expiresAt)` takes the `{ attestation, expiresAt }` answer of the [attestation endpoints](https://linkrunway.com/resources/developers) and attaches the token to every event sent before it expires. It is kept in memory only, ignored without consent, cleared when consent is withdrawn, and added when a request is made, so a queued event never stores it. The SDK does not perform App Attest or Play Integrity; a native layer has to. A browser cannot attest, so in a workspace whose app mode is `REQUIRED` web events lose their attribution; see [attestation modes](https://linkrunway.com/resources/developers).

## Ad-network claims

Both run once per install and return `{ status, data? }`, where `status` is `submitted`, `alreadySubmitted` or `pending` and `data` is the server's answer.

- `submitAdServicesToken(token, { retries?, delayMs? })` posts Apple's AdServices attribution token to `POST /v1/claims/apple-ads`. A 202 means Apple does not know the token yet: the request is repeated three times, five seconds apart (Apple's guidance), then reported as `pending`. Call it again later, for example on the next launch; a token is valid for 24 hours.
- `submitReferrerClaim(appId, referrer)` posts the raw Play install referrer to `POST /v1/claims/referrer`. A 202 is reported as `pending` without retrying, because the server asks for about an hour (`data.retryAfterSeconds`). An empty referrer sends nothing.

What the server verifies and stores is described in [Apple measurement and network claims](https://linkrunway.com/resources/developers).

## Configuration and server-side helpers

`mobileConfig(appId)` returns `{ id, conversionRules }` from `GET /v1/mobile/config/:id`.

Two helpers refuse to run with a publishable key and reject with `… requires a server key`:

```ts
const server = new LinkRunway({
  endpoint,
  apiKey: process.env.LINKRUNWAY_SERVER_KEY!,
  consent: true,
});
await server.recordImpression({ linkId, platform: 'CTV', device: 'Roku', ip: viewerAddress });
await server.bindStoreAccount({ externalUserId: user.id, storeAccountToken });
```

`recordImpression` reports an ad impression for [view-through matching](https://linkrunway.com/resources/attribution). `bindStoreAccount` binds a store account token to your authenticated customer, as described in [store receipts](https://linkrunway.com/resources/developers). Both follow the instance's consent: construct the client with `consent: true` only for users whose consent you hold, or do not call it for the others.

The package also exports `LinkRunwayError`, `SDK_VERSION`, `storageKey(endpoint, apiKey)`, `uuid()` and `parseUrl(url)` for wrappers such as the React Native layer.

## Privacy notes

- No request and no storage write happens before consent, and withdrawal erases what was stored.
- The click token, the install ID and queued events are stored in plain text in the storage you provide. Do not put secrets in event metadata.
- The install ID is random and scoped to one storage entry. It is not shared between apps, browsers or devices.
- Apart from the install ID and the optional `userAgent`, the SDK adds no identifier to a request. The API sees what any HTTPS request carries, such as the caller's address.
- A publishable key is public. Never trust events sent with it for revenue or customer identity.

## Verified and not verified

Verified by unit tests against a stubbed `fetch` (`tests/sdk*.test.ts`, run in Node.js 22):

- consent gating of every call, and erasure on withdrawal;
- install ID creation, persistence and renewal; a server key getting none;
- `matchInstall` caching, request sharing, token precedence and input cleaning;
- attestation attachment and expiry; the 202 retry rule and once-per-install claims;
- the untracked resolve result; server-only helpers refusing a publishable key;
- the user agent header being sent in Node.js and omitted when `document` exists;
- queue behaviour for network failures, invalid events, conflicts and expired click tokens;
- URL handling on a text parser when the runtime's `URL` class is incomplete, as in older React Native.

Not verified:

- No test runs in a real browser, so `localStorage`, CORS and page lifecycle behaviour are untested here.
- No test in this file set calls a running API. The server routes have their own integration tests; the two sides were written against the same contracts and have not been exercised together.
- Runtimes other than Node.js 22 (Bun, Deno, edge workers, React Native) were not run.
