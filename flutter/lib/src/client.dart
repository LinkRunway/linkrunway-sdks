import 'dart:async';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'session.dart';
import 'storage.dart';
import 'transport.dart';
import 'values.dart';

part 'events.dart';
part 'install.dart';

/// Sent in the user agent as `LinkRunwaySDK/<version> Flutter`.
const String sdkVersion = '0.1.0';

const _localHosts = {'localhost', '127.0.0.1', '10.0.2.2'};

/// A consent-gated LinkRunway client for an app. Without consent it makes no request and stores
/// nothing; withdrawing consent erases what it stored.
///
/// It is pure Dart: values that only native code can read (the Play install referrer, an
/// AdServices token, a device attestation) are passed in by the app.
final class LinkRunway extends _Client with _Events, _Install {
  /// [endpoint] is your link domain, such as `https://go.example.com`. [publishableKey] must be
  /// a publishable key (`lr_pk_`); a server key never belongs in an app.
  LinkRunway({
    required super.endpoint,
    required super.publishableKey,
    super.consent,
    super.platform,
    super.storage,
    super.httpClient,
    super.retries,
    super.timeout,
    super.retryDelay,
    super.randomUuid,
    super.clock,
  });
}

// Consent, links, shares and referral codes. Events and install calls are in the part files.
abstract base class _Client {
  _Client({
    required String endpoint,
    required String publishableKey,
    bool consent = false,
    this.platform,
    LinkRunwayStorage? storage,
    http.Client? httpClient,
    int retries = 2,
    Duration timeout = const Duration(seconds: 10),
    Duration retryDelay = const Duration(milliseconds: 300),
    String Function()? randomUuid,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       _ownsClient = httpClient == null {
    final uri = Uri.tryParse(endpoint);
    if (uri == null || uri.host.isEmpty || !{'http', 'https'}.contains(uri.scheme)) {
      throw ArgumentError.value(endpoint, 'endpoint', 'Use an absolute HTTPS URL');
    }
    if (uri.scheme != 'https' && !_localHosts.contains(uri.host)) {
      throw ArgumentError.value(endpoint, 'endpoint', 'HTTPS is required outside localhost');
    }
    // The key is left out of the message: a server key passed by mistake must not reach a log.
    if (!publishableKey.startsWith('lr_pk_')) {
      throw ArgumentError('Use a publishable key (lr_pk_) in apps');
    }
    final prefix = publishableKey.length > 20 ? publishableKey.substring(0, 20) : publishableKey;
    _session = Session(
      storage ?? MemoryStorage(),
      'linkrunway:${uri.origin}:$prefix',
      false,
      randomUuid ?? uuidV4,
    );
    _api = Transport(
      endpoint: uri,
      apiKey: publishableKey,
      client: httpClient ?? http.Client(),
      retries: retries.clamp(0, 5),
      timeout: timeout,
      retryDelay: retryDelay,
      userAgent: 'LinkRunwaySDK/$sdkVersion Flutter',
    );
    if (consent) unawaited(_session.grant());
  }

  /// Used for the first-launch match, and as the platform a link is resolved for. Null resolves
  /// links as `web` and makes [matchInstall] unavailable.
  final LinkRunwayPlatform? platform;

  final DateTime Function() _clock;
  final bool _ownsClient;
  late final Session _session;
  late final Transport _api;
  Future<void>? _flushing;
  Future<InstallMatch?>? _matching;
  final Map<String, Future<ClaimResult?>> _claiming = {};
  ({String token, DateTime until})? _attestation;

  bool get consent => _session.consent;

  /// Turns tracking on or off. Turning it on makes state saved by an earlier launch usable again;
  /// turning it off erases the click token, the install ID, the queue and the stored match.
  Future<void> setConsent(bool value) {
    if (value) return _session.grant();
    _attestation = null;
    return _session.withdraw();
  }

  /// Saves the signed click token carried by [url], if it has one.
  Future<void> capture(String url) async {
    await _session.settled;
    final token = tokenInUrl(url);
    if (!_session.consent || token == null || token.length > 1500) return;
    _session.clickToken = token;
    await _session.persist();
  }

  /// Saves the click token a LinkRunway store link placed in the Play install referrer.
  Future<void> captureReferrer(String referrer) => capture('https://referrer.invalid/?$referrer');

  /// The signed click token to hand to your backend, or null without consent.
  Future<String?> attributionToken() async {
    await _session.settled;
    return _session.consent ? _session.clickToken : null;
  }

  /// Resolves a LinkRunway link the app was opened with and saves its click token.
  Future<ResolvedLink?> open(String url) async {
    await _session.settled;
    if (!_session.consent) return null;
    final epoch = _session.epoch;
    final reply = await _api.post('resolve', {
      'url': url,
      'platform': platform?.resolveName ?? 'web',
      'consent': true,
    });
    if (!_session.current(epoch)) return null;
    final link = ResolvedLink.fromJson(reply.data);
    // An untracked open recorded no click, so it leaves the current attribution as it was.
    if (!link.untracked) {
      _session.clickToken = link.clickToken;
      await _session.persist();
    }
    return link;
  }

  /// Creates a tracked share link. Throws a [StateError] without consent.
  Future<SharedLink> createShare({
    required String linkId,
    String? externalUserId,
    String? channel,
  }) async {
    await _session.settled;
    if (!_session.consent) {
      throw StateError('Analytics consent is required to create tracked shares');
    }
    final reply = await _api.post('shares', {
      'linkId': linkId,
      if (externalUserId != null) 'externalUserId': externalUserId,
      if (channel != null) 'channel': channel,
    });
    return SharedLink.fromJson(reply.data);
  }

  /// Turns the current attributed click into a single-use code the user can carry to a new
  /// install. Throws a [StateError] without consent or without an attributed click.
  Future<ReferralCode?> createReferralCode() async {
    await _session.settled;
    final token = _session.clickToken;
    if (!_session.consent || token == null) {
      throw StateError('A consented attributed click is required');
    }
    final epoch = _session.epoch;
    final reply = await _api.post('deferred', {'clickToken': token, 'consent': true});
    return _session.current(epoch) ? ReferralCode.fromJson(reply.data) : null;
  }

  /// Claims a referral code. Keep [claimId], a UUID, stable across retries of the same claim.
  Future<ResolvedLink?> claimReferralCode(String code, String claimId) async {
    await _session.settled;
    if (!_session.consent) return null;
    final epoch = _session.epoch;
    final reply = await _api.post('deferred/claim', {
      'code': code,
      'claimId': claimId,
      'consent': true,
    });
    if (!_session.current(epoch)) return null;
    final link = ResolvedLink.fromJson(reply.data);
    _session.clickToken = link.clickToken;
    await _session.persist();
    return link;
  }

  /// Closes the HTTP client this instance created. A client you passed in stays open.
  void close() {
    if (_ownsClient) _api.client.close();
  }
}
