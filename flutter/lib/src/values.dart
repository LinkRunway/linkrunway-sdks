import 'dart:math';

final _uuidShape = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
final _versionShape = RegExp(r'^\d{1,3}(\.\d{1,3}){0,2}$');
final _languageShape = RegExp(r'^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$');

/// A lowercase RFC 9562 UUID, the only form the API accepts for install IDs.
bool isUuid(Object? value) => value is String && _uuidShape.hasMatch(value);

Random _random() {
  try {
    return Random.secure();
  } on UnsupportedError {
    // No cryptographic source on this platform; the ID is still random, only not unguessable.
    return Random();
  }
}

/// A random version 4 UUID from the platform's cryptographic source.
String uuidV4() {
  final random = _random();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return [
    hex.substring(0, 8),
    hex.substring(8, 12),
    hex.substring(12, 16),
    hex.substring(16, 20),
    hex.substring(20),
  ].join('-');
}

/// `major[.minor[.patch]]`, or null when the platform reports another format.
String? plainVersion(String? value) {
  final version = (value ?? '').trim().split('.').take(3).join('.');
  return _versionShape.hasMatch(version) ? version : null;
}

/// A plain language tag such as `en-US`; extension and private-use subtags are dropped.
String? plainLanguage(String? value) {
  final parts = (value ?? '').trim().replaceAll('_', '-').split('-');
  final tag = parts.takeWhile((part) => part.length > 1).join('-');
  final usable =
      tag.length <= 35 && _languageShape.hasMatch(tag) && !tag.toLowerCase().startsWith('und');
  return usable ? tag : null;
}

/// The value of [name] in a query string such as an install referrer, or null.
String? queryValue(String query, String name) {
  try {
    final value = Uri.splitQueryString(query)[name];
    return value == null || value.isEmpty ? null : value;
  } on Object {
    // Not a decodable query string.
    return null;
  }
}

/// The `lr_token` of a URL, or null when it has none or cannot be parsed.
String? tokenInUrl(String url) {
  final query = Uri.tryParse(url)?.query;
  return query == null ? null : queryValue(query, 'lr_token');
}

/// The match contract caps the referrer; an oversized one is reduced to the token it is read for.
String? matchableReferrer(String? referrer, {int limit = 4000}) {
  if (referrer == null || referrer.isEmpty) return null;
  if (referrer.length <= limit) return referrer;
  final token = queryValue(referrer, 'lr_token');
  final reduced = token == null ? null : 'lr_token=${Uri.encodeQueryComponent(token)}';
  return reduced != null && reduced.length <= limit ? reduced : null;
}
