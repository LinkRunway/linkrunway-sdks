/// The platform an app runs on, as the LinkRunway API names it.
enum LinkRunwayPlatform {
  ios('ios', 'ios'),
  android('android', 'android'),
  tvos('tvos', 'ios'),
  androidTv('androidtv', 'android');

  const LinkRunwayPlatform(this.matchName, this.resolveName);

  /// The value sent with a first-launch match.
  final String matchName;

  /// The value sent when a link is resolved, which knows only `ios`, `android` and `web`.
  final String resolveName;
}

/// The events an app may report. Revenue is reported by your backend with a server key.
enum EventType {
  install('INSTALL'),
  open('OPEN'),
  signup('SIGNUP'),
  custom('CUSTOM');

  const EventType(this.wireName);
  final String wireName;
}

/// How the server resolved an install's first launch.
enum MatchMethod {
  referrer('REFERRER'),
  probabilistic('PROBABILISTIC'),
  viewThrough('VIEW_THROUGH'),
  none('NONE'),

  /// A method added by a server newer than this package.
  unknown('UNKNOWN');

  const MatchMethod(this.wireName);
  final String wireName;

  static MatchMethod parse(Object? value) => values.firstWhere(
    (method) => method.wireName == value,
    orElse: () => value == null ? none : unknown,
  );
}

String? _text(Object? value) => value is String && value.isNotEmpty ? value : null;

Map<String, Object?> _object(Object? value) =>
    value is Map
        ? <String, Object?>{for (final entry in value.entries) '${entry.key}': entry.value}
        : const {};

/// An API answer other than success. [status] is the HTTP status code.
final class LinkRunwayException implements Exception {
  const LinkRunwayException(this.status, this.message);

  final int status;
  final String message;

  /// True when the same request may succeed later: the server was busy or unavailable.
  bool get isTransient => status >= 500 || status == 429;

  @override
  String toString() => 'LinkRunwayException($status): $message';
}

/// What happened to a tracked event.
final class TrackingResult {
  const TrackingResult({this.id, this.attributed = false, this.duplicate = false})
    : skipped = false,
      queued = false;

  /// Nothing was sent because consent is off.
  const TrackingResult.skipped()
    : id = null,
      attributed = false,
      duplicate = false,
      skipped = true,
      queued = false;

  /// The request failed; the event waits in the offline queue for [LinkRunway.flush].
  const TrackingResult.queued()
    : id = null,
      attributed = false,
      duplicate = false,
      skipped = false,
      queued = true;

  factory TrackingResult.fromJson(Map<String, Object?> json) => TrackingResult(
    id: _text(json['id']),
    attributed: json['attributed'] == true,
    duplicate: json['duplicate'] == true,
  );

  final String? id;
  final bool attributed;
  final bool duplicate;
  final bool skipped;
  final bool queued;
}

/// A resolved LinkRunway link.
final class ResolvedLink {
  ResolvedLink.fromJson(Map<String, Object?> json)
    : clickId = _text(json['clickId']),
      clickToken = _text(json['clickToken']),
      path = _text(json['path']) ?? '/',
      url = _text(json['url']),
      metadata = _object(json['metadata']),
      untracked = json['untracked'] == true;

  /// Absent when the open was not recorded.
  final String? clickId;
  final String? clickToken;

  /// The link's in-app path as configured in LinkRunway. Route it through your own allowlist.
  final String path;
  final String? url;
  final Map<String, Object?> metadata;

  /// The workspace is over its click allowance: the link still routes, the open is not recorded.
  final bool untracked;
}

/// A tracked share link.
final class SharedLink {
  SharedLink.fromJson(Map<String, Object?> json)
    : shareId = _text(json['shareId']) ?? '',
      url = _text(json['url']) ?? '';

  final String shareId;
  final String url;
}

/// A single-use referral code and when it stops being claimable.
final class ReferralCode {
  ReferralCode.fromJson(Map<String, Object?> json)
    : code = _text(json['code']) ?? '',
      expiresAt = DateTime.tryParse(_text(json['expiresAt']) ?? '');

  final String code;
  final DateTime? expiresAt;
}

/// The answer to a first-launch match. The signed click token is kept by the client:
/// read it with [LinkRunway.attributionToken].
final class InstallMatch {
  InstallMatch.fromJson(Map<String, Object?> json, {required this.cached})
    : matched = json['matched'] == true,
      method = MatchMethod.parse(json['method']),
      clickId = _text(json['clickId']),
      path = _text(json['path']),
      url = _text(json['url']),
      metadata = _object(json['metadata']);

  final bool matched;
  final MatchMethod method;
  final String? clickId;

  /// The matched link's in-app path. Route it through your own allowlist.
  final String? path;
  final String? url;
  final Map<String, Object?> metadata;

  /// True when the answer was stored by an earlier call and no request was made.
  final bool cached;
}

enum ClaimStatus {
  /// The server gave its final answer.
  submitted,

  /// An earlier call completed for this install; nothing was sent.
  alreadySubmitted,

  /// The ad network has not processed the evidence yet. Submit it again later.
  pending,
}

/// What a claim call did, with the server's answer in [data].
final class ClaimResult {
  const ClaimResult(this.status, [this.data = const {}]);

  final ClaimStatus status;
  final Map<String, Object?> data;
}
