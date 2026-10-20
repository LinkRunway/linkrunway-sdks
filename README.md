# LinkRunway SDKs

Client SDKs for [LinkRunway](https://linkrunway.com): branded links, mobile deep links, attribution and partner programs. Every SDK is consent-gated: nothing is stored or sent until your app grants consent.

| Platform | Install | Guide |
| --- | --- | --- |
| Web, Node.js | npm, from the [0.2.1 release](https://github.com/LinkRunway/linkrunway-sdks/releases/tag/0.2.1) | [js/sdk](js/sdk/README.md) |
| React Native | npm, from the 0.2.1 release | [js/react-native](js/react-native/README.md) |
| Expo | npm, from the 0.2.1 release | [js/expo](js/expo/README.md) |
| iOS, tvOS, macOS | Swift Package Manager: `https://github.com/LinkRunway/linkrunway-sdks` | [ios](ios/README.md) |
| Android, Android TV | JitPack: `com.github.LinkRunway:linkrunway-sdks` | [android](android/README.md) |
| Dart, Flutter | git dependency, `path: flutter` | [flutter](flutter/README.md) |

Apps and web pages use a publishable key (`lr_pk_…`). Publishable keys record unverified, non-financial activity only: purchases, subscriptions, refunds and customer identity are reported by your server with a server key (`lr_sk_…`), which must never ship in an app or page. Create both under **Developers → API keys** in the [LinkRunway console](https://app.linkrunway.com/developers/keys).

Each guide ends with what was and was not verified for that SDK. Questions and security reports: support@linkrunway.com. Released under the [MIT license](LICENSE).
