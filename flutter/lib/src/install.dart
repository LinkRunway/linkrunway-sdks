part of 'client.dart';

base mixin _Install on _Client {
  /// This install's random UUID, created and saved on first use and sent with every event. It is
  /// not derived from the device and is not an advertising ID. Null without consent.
  Future<String?> installId() => _session.installId();

  /// The stored answer of [matchInstall], once there is one.
  Future<InstallMatch?> installMatch() async {
    await _session.settled;
    final stored = _session.match;
    return _session.consent && stored != null ? InstallMatch.fromJson(stored, cached: true) : null;
  }

  /// Asks the server once which earlier touch, if any, led to this install. The answer is stored,
  /// so later calls make no request; concurrent calls share one.
  ///
  /// The returned click token is kept unless a link opened since has already set one. Pass the
  /// Play install [referrer] on Android when your app can read it.
  Future<InstallMatch?> matchInstall({String? osVersion, String? language, String? referrer}) {
    final target = platform;
    if (target == null) throw StateError('matchInstall needs the platform given to LinkRunway()');
    return _matching ??= _match(target, osVersion, language, referrer).whenComplete(() {
      _matching = null;
    });
  }

  Future<InstallMatch?> _match(
    LinkRunwayPlatform target,
    String? version,
    String? language,
    String? referrer,
  ) async {
    final cached = await installMatch();
    if (cached != null || !_session.consent) return cached;
    final epoch = _session.epoch;
    final id = await _session.installId();
    if (id == null) return null;
    final reply = await _api.post('installs/match', {
      'installId': id,
      'platform': target.matchName,
      if (plainVersion(version) case final value?) 'osVersion': value,
      if (plainLanguage(language) case final value?) 'language': value,
      if (matchableReferrer(referrer) case final value?) 'referrer': value,
      'consent': true,
    });
    // An answer for an identity the user has since withdrawn is dropped, not stored.
    if (!_session.current(epoch, id)) return null;
    final token = reply.data['clickToken'];
    _session.match = {...reply.data}..remove('clickToken');
    if (token is String && token.isNotEmpty) _session.clickToken ??= token;
    await _session.persist();
    return InstallMatch.fromJson(reply.data, cached: false);
  }

  /// Forwards the raw Play install referrer so the server can verify ad-network evidence in it.
  /// Runs once per install; a [ClaimStatus.pending] answer may be submitted again later.
  Future<ClaimResult?> submitReferrerClaim(String appId, String referrer) {
    if (referrer.isEmpty) return Future.value();
    return _claim(
      'referrer',
      'claims/referrer',
      {'appId': appId, 'referrer': referrer},
      0,
      Duration.zero,
    );
  }

  /// Forwards Apple's AdServices attribution token. While Apple does not know the token yet the
  /// request is repeated [retries] times, [delay] apart, as Apple advises.
  Future<ClaimResult?> submitAdServicesToken(
    String token, {
    int retries = 3,
    Duration delay = const Duration(seconds: 5),
  }) => _claim('appleAds', 'claims/apple-ads', {'token': token}, retries.clamp(0, 10), delay);

  Future<ClaimResult?> _claim(
    String kind,
    String path,
    Json evidence,
    int retries,
    Duration delay,
  ) {
    // The callback must not return the removed future: whenComplete would wait for it, and it is
    // the very future being completed.
    return _claiming[kind] ??= _submit(kind, path, evidence, retries, delay).whenComplete(() {
      _claiming.remove(kind);
    });
  }

  Future<ClaimResult?> _submit(
    String kind,
    String path,
    Json evidence,
    int retries,
    Duration delay,
  ) async {
    await _session.settled;
    if (!_session.consent) return null;
    if (_session.claims.contains(kind)) return const ClaimResult(ClaimStatus.alreadySubmitted);
    final epoch = _session.epoch;
    final id = await _session.installId();
    if (id == null) return null;
    for (var attempt = 0; ; attempt++) {
      final reply = await _api.post(path, {'installId': id, ...evidence, 'consent': true});
      if (!_session.current(epoch, id)) return null;
      if (reply.status != 202 && reply.data['pending'] != true) {
        _session.claims.add(kind);
        await _session.persist();
        return ClaimResult(ClaimStatus.submitted, reply.data);
      }
      if (attempt >= retries) return ClaimResult(ClaimStatus.pending, reply.data);
      await Future<void>.delayed(delay);
      if (!_session.current(epoch, id)) return null;
    }
  }

  /// Attaches a server-issued attestation token to events until [expiresAt]. It is kept in
  /// memory only, ignored without consent, and cleared when consent is withdrawn.
  void setAttestation(String token, DateTime expiresAt) {
    if (token.isEmpty || token.length > 2000) {
      throw ArgumentError.value(
        token.length,
        'token',
        'Use the attestation token the API returned',
      );
    }
    if (_session.consent) _attestation = (token: token, until: expiresAt);
  }
}
