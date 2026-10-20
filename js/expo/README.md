# React Native and Expo (`@linkrunway/sdk-react-native`, `@linkrunway/sdk-expo`)

Two typed JavaScript packages on top of the [core SDK](../sdk/README.md):

- `@linkrunway/sdk-react-native` connects the core SDK to an app: persistent storage, incoming links, the offline queue, and the first-launch match.
- `@linkrunway/sdk-expo` re-exports that layer and adds an Expo config plugin that declares your link domains in the native projects.

**Neither package contains a native module.** They do not import `react-native`, and they cannot read the Play install referrer, an AdServices token, or a device attestation. The app passes those values in; [Values only native code can read](#values-only-native-code-can-read) shows how. Install the core and React Native packages in one command: `npm install https://github.com/LinkRunway/linkrunway-sdks/releases/download/0.2.1/linkrunway-sdk-0.1.0.tgz https://github.com/LinkRunway/linkrunway-sdks/releases/download/0.2.1/linkrunway-sdk-react-native-0.1.0.tgz`. In an Expo app, add `https://github.com/LinkRunway/linkrunway-sdks/releases/download/0.2.1/linkrunway-sdk-expo-0.1.0.tgz` to the same command. See [Verified and not verified](#verified-and-not-verified) before relying on them.

## Setup

The layer takes the platform pieces as arguments, so it works with any storage and linking module that has the same shape.

```ts
import AsyncStorage from '@react-native-async-storage/async-storage';
import { AppState, Linking, Platform } from 'react-native';
import { createLinkRunway } from '@linkrunway/sdk-react-native';

export const runway = createLinkRunway({
  endpoint: 'https://go.example.com',
  apiKey: 'lr_pk_your_key',
  consent: false,
  platform: Platform.OS as 'ios' | 'android',
  linking: Linking,
  appState: AppState,
  storage: AsyncStorage,
});

// After your consent flow:
runway.setConsent(true);
```

Create one client for the lifetime of the app, outside any component.

| Option               | Purpose                                                                                                                                                                    |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `endpoint`, `apiKey` | Your link domain and a publishable key. A server key is refused.                                                                                                           |
| `consent`            | Initial consent. `false` is "not decided yet" and erases nothing; call `setConsent(false)` for a refusal.                                                                  |
| `platform`           | `ios`, `android`, `tvos` or `androidtv`. Any other value throws.                                                                                                           |
| `linking`            | `{ getInitialURL(), addEventListener('url', handler) }`: React Native's `Linking` or `expo-linking`.                                                                       |
| `appState`           | `{ addEventListener('change', handler) }`: React Native's `AppState`.                                                                                                      |
| `storage`            | `{ getItem, setItem, removeItem }`, each answering directly or with a promise.                                                                                             |
| `domains`            | Hosts whose `/l/<key>` URLs are LinkRunway links. Defaults to the host of `endpoint`.                                                                                      |
| `osVersion`          | The OS release (`17.5`, `14`), not the Android API level. On Android use `Platform.constants.Release`; on iOS `String(Platform.Version)`.                                  |
| `language`           | The user's first language tag, such as `en-US`.                                                                                                                            |
| `getInstallReferrer` | Returns the Play install referrer, or `null` when there is none. Reject only when the read failed and should be tried again.                                               |
| `getAttestation`     | `({ installId }) => Promise<{ attestation, expiresAt } \| null>`: your App Attest or Play Integrity exchange.                                                              |
| `randomUUID`         | Source of install and event IDs. Recommended: React Native has no `crypto` by default, and the fallback is `Math.random()`.                                                |
| `fetch`, `retries`   | As in the core SDK.                                                                                                                                                        |
| `onError`            | `(error, stage)` for failures of work the layer starts itself. `stage` is `storage`, `link`, `flush`, `install`, `attestation` or `listener`. Without it they are dropped. |

A synchronous store such as MMKV fits the same three methods; the method names of your MMKV version may differ:

```ts
storage: {
  getItem: (key) => mmkv.getString(key),
  setItem: (key, value) => mmkv.set(key, value),
  removeItem: (key) => mmkv.delete(key),
},
```

## What the client does

1. **Storage.** The core SDK reads storage synchronously, so the layer loads the saved state once and then writes every change through in order. Calls made before loading has finished wait for it: an event tracked at startup is sent afterwards with the saved click token and install ID, and keeps the time of the call.
2. **Links.** It reads `getInitialURL()` and listens for `url` events.
   - A URL on one of `domains` with the path `/l/<key>` is resolved through the API. Subscribers receive `{ source, url, path, destination, metadata, clickId }`.
   - A URL carrying `lr_token` (the destination of a web redirect) has its token saved. No link is announced; your own routing handles that URL.
   - Every other URL is ignored.
   - The same URL delivered twice within two seconds, as some platforms do at launch, is resolved once.
3. **Offline queue.** Queued events are flushed after loading and whenever `AppState` changes to `active`.
4. **First launch.** Once per install it calls `getInstallReferrer`, then `matchInstall`. A match is announced to subscribers with `source: 'install'`, unless a link was already opened in this session. Later launches find the answer in storage and make no request. If reading the referrer fails, no match is made, and the next foreground tries again.
5. **Attestation.** With `getAttestation` it asks for a token after consent, attaches it to events, and asks again within a minute of expiry. A failed or empty attempt is not repeated for 15 minutes.

Every request carries `User-Agent: LinkRunwaySDK/<version> ReactNative`, which the API recognizes.

## API

| Call                                                 | Notes                                                                                                                                        |
| ---------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `setConsent(value)`                                  | `true` loads saved state and starts the work above. `false` erases stored state and drops a link that was waiting.                           |
| `track({ type, eventId?, name?, metadata?, … })`     | Resolves `{ id, attributed, duplicate }`, `{ queued: true }` or `{ skipped: true }`. `eventId` defaults to a new UUID.                       |
| `install()`                                          | Reports INSTALL after the first-launch match. See below.                                                                                     |
| `createShare({ linkId, externalUserId?, channel? })` | Returns `{ shareId, url }` for the system share sheet. Rejects without consent.                                                              |
| `open(url)`                                          | Handles a URL that reached the app another way, such as a push payload. Rejects if resolving fails.                                          |
| `subscribe(listener)`                                | Calls `listener(link)` for each resolved link and install match. Returns the unsubscribe function.                                           |
| `lastLink()`                                         | The most recent link, for a component that mounts after it arrived.                                                                          |
| `attributionToken()`, `installId()`, `flush()`       | As in the core SDK, as promises.                                                                                                             |
| `ready`                                              | A promise for the core `LinkRunway` instance once storage has loaded: use it for `submitAdServicesToken`, referral codes and `installMatch`. |
| `destroy()`                                          | Removes the `Linking` and `AppState` listeners.                                                                                              |

Change consent through the client, not through the core instance from `ready`.

There is no React hook in the package, because it does not import React. `subscribe` and `lastLink` fit `useSyncExternalStore`:

```tsx
const link = useSyncExternalStore(runway.subscribe, runway.lastLink);
useEffect(() => {
  if (link?.path && allowedRoutes.has(link.path)) navigation.navigate(link.path);
}, [link]);
```

`path` and `metadata` come from the link's configuration. Route only to paths your app allowlists.

Report installs with `install()`, not with `track`. It waits for the first-launch match (and for a pending attestation, at most 30 seconds), then sends INSTALL with the matched click and the ID `install-<installId>`. The fixed ID makes a call on every launch one event: the API answers repeats as duplicates. An INSTALL sent before the match would be stored without the matched click, and every later copy would be a duplicate of it, which is why `install()` rejects while the match has not completed (for example offline, or when reading the referrer failed). Call it again on the next foreground.

```ts
runway.install().catch(() => undefined); // if it rejects, call it again on the next foreground
```

## Values only native code can read

These are suggestions for where the values can come from. None of the packages named here was installed or run with this SDK; check each package's own documentation.

**Play install referrer (Android).** `expo-application` exposes `getInstallReferrerAsync()`; in a bare app `getInstallReferrer()` from `react-native-device-info` reads the same API.

```ts
getInstallReferrer: () => (Platform.OS === 'android' ? Application.getInstallReferrerAsync() : null),
```

To let the server verify Google Ads or Meta evidence in the same referrer, also submit it once as a claim. `appId` is the ID of the mobile app registered in LinkRunway:

```ts
const sdk = await runway.ready;
await sdk.submitReferrerClaim(appId, referrer); // { status: 'submitted' | 'pending' | 'alreadySubmitted' }
```

**AdServices token (iOS).** Read `AAAttribution.attributionToken()` with a native module of your choice and submit it. A `pending` result means Apple does not know the token yet; call again on a later launch.

```ts
const sdk = await runway.ready;
const result = await sdk.submitAdServicesToken(await readAdServicesToken());
```

**App Attest and Play Integrity.** The exchange is described in [device attestation](https://linkrunway.com/resources/developers): request a challenge, obtain the platform proof with a native module that exposes App Attest or Play Integrity, and post it. `getAttestation` returns the server's answer. For Play Integrity:

```ts
let attestationOff = false;

getAttestation: async ({ installId }) => {
  if (attestationOff) return null;
  const started = await attest('challenge', { appId });
  if (started.status === 409) {
    attestationOff = true; // the owner turned attestation off for this app: stop for this session
    return null;
  }
  const { challengeId, challenge } = await started.json();
  // base64url, without padding, of SHA-256("<challenge>.<installId>")
  const token = await requestIntegrityToken(await sha256Base64Url(`${challenge}.${installId}`));
  return (await attest('play', { appId, challengeId, installId, token })).json(); // { attestation, expiresAt }
},
```

Here `attest(path, body)` is your own `fetch` to `POST <endpoint>/v1/attest/<path>` with the publishable key, returning the response, and `requestIntegrityToken` and `sha256Base64Url` come from your native modules. On iOS the same shape applies with `apple/register` once and `apple/assert` afterwards. The layer itself never calls the attestation endpoints: it only calls `getAttestation`, and an answer without `attestation` (such as `null` or an error body) is ignored.

## Expo

```ts
import * as Linking from 'expo-linking';
import { createLinkRunway } from '@linkrunway/sdk-expo';
```

`expo-linking` has the `linking` shape, `randomUUID` from `expo-crypto` fits `randomUUID`, and `getLocales()[0]?.languageTag` from `expo-localization` fits `language`.

If the app uses Expo Router, its router also sees the incoming `https://go.example.com/l/<key>` URL. Keep it away from that URL (for example in `+native-intent`) and navigate from `subscribe` instead. `linkKind(url, domains)` from this package returns `'link'` for such a URL.

### Config plugin

```json
{
  "expo": {
    "plugins": [["@linkrunway/sdk-expo", { "domains": ["go.example.com"], "scheme": "myapp" }]]
  }
}
```

`withLinkRunway(config, { domains, scheme? })` changes native project files only. It adds no native code and no permission.

- **iOS.** Adds `applinks:<domain>` for each domain to the Associated Domains entitlement, and to `ios.associatedDomains` in the evaluated config. Existing entries, including other services such as `webcredentials:`, keep their place, and nothing is added twice.
- **Android.** Adds one intent filter per domain to the main activity (`.MainActivity`, or the launcher activity): `android:autoVerify="true"`, action `VIEW`, categories `DEFAULT` and `BROWSABLE`, and `<data android:scheme="https" android:host="<domain>" android:pathPrefix="/l/"/>`. Running prebuild again changes nothing. Other filters, activities and elements are left alone.
- **`scheme`** (optional) is added to the config's `scheme`, which Expo registers on both platforms and `expo-linking` reads.

`domains` must be bare hostnames. A URL, a path, a port, a wildcard, an IP address, a single label such as `localhost`, or a non-ASCII name (use its punycode form) is rejected with an error when the config is evaluated, as are unknown options.

The app opens a domain's links only after the domain is verified in LinkRunway and the Apple team and bundle ID, or Android package and signing fingerprints, are registered: the API serves `/.well-known/apple-app-site-association` and `/.well-known/assetlinks.json` for that domain. See [mobile integration](https://linkrunway.com/resources/mobile).

Things to know:

- List the plugin under `plugins`, as above. Expo then runs it after its own mods, which is the order it was tested in.
- After removing a domain, run `npx expo prebuild --clean`. The plugin cannot tell a filter it wrote earlier from one you wrote.
- When prebuild runs against an existing `android` directory and a custom scheme was added since, Expo's scheme mod appends that scheme to every `VIEW` filter of the main activity, including the app-link filters. The plugin moves it back out, into a filter of its own if no other filter declares it, so the app-link filters stay pure HTTPS filters.
- The published plugin is compiled JavaScript, so `expo prebuild` runs it on any Node.js version Expo supports.

## Privacy notes

- Nothing is sent or stored before consent, and `setConsent(false)` erases what was stored. See the [core SDK](../sdk/README.md#consent-and-stored-state).
- A link that opens the app before the user has answered your consent prompt is held in memory, not stored and not sent. It is resolved if they consent and discarded if they decline or the app exits. A link that arrives after a refusal is dropped.
- `getInstallReferrer` and `getAttestation` are called only while consent is on.
- The attestation token is kept in memory only.
- State is stored in plain text in the storage you pass. AsyncStorage is not encrypted.
- The layer reads no advertising ID, device ID, clipboard or contact data, and asks for no permission.

## Verified and not verified

Verified by unit tests in Node.js 22 (`tests/sdk-react-native*.test.ts`, `tests/sdk-expo*.test.ts`), with fakes for `Linking`, `AppState` and storage and a stubbed `fetch`:

- the hydration race, write-through order, and a failing or synchronous store;
- initial and later links, token capture, ignored URLs, duplicate delivery, and `destroy`;
- the foreground flush; the first-launch match running once, with the referrer, and retrying after a failed read;
- `install()` waiting for the match, sending the matched click with a fixed ID, and rejecting before the match;
- the referrer not being read when consent is withdrawn while a waiting link resolves;
- consent: waiting links, refusal before and after loading, and re-consent;
- the attestation provider being called once per validity period and backing off after a failure;
- the plugin's transformations on objects produced by Expo's own XML parser: adding, idempotence, unrelated entries untouched, invalid options rejected;
- the plugin inside the mod compiler of `@expo/config-plugins` 57.0.10 in introspection mode (Expo's template manifest, nothing written to disk), next to that package's own scheme, intent-filter and Associated Domains mods;
- the packed `@linkrunway/sdk-expo` installed into a new project, its `app.plugin.js` found by package name and run by plain Node.js 22.16 through Expo's `withStaticPlugin`.

Not verified:

- **Neither package has run inside a React Native or Expo app**, on Hermes or JavaScriptCore, on a device or in a simulator.
- `react-native` is not installed in this repository. The `Linking`, `AppState` and storage shapes were written from their documented signatures and were not type-checked against the real packages.
- The community packages named above were not installed or run. Whether React Native's networking sends the custom `User-Agent` header on each platform was not observed.
- `expo prebuild`, EAS Build and a real Expo project were not run. `@expo/prebuild-config` is not installed, so the order in which prebuild registers Expo's own mods was reproduced by hand in the tests, not taken from that package.
- No app was built, so Universal Links and Android App Links opening the app, and domain verification on a device, are untested.
- Play Install Referrer, AdServices and App Attest or Play Integrity are not implemented here. They depend entirely on the values your app supplies.
