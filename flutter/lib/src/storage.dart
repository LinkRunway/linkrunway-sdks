import 'dart:async';

/// Where the client keeps its state between launches. Implement it over the key-value store your
/// app already uses; every method may answer directly or with a future.
///
/// The client writes one small JSON value, only while consent is on, and deletes it when consent
/// is withdrawn.
abstract interface class LinkRunwayStorage {
  FutureOr<String?> read(String key);
  FutureOr<void> write(String key, String value);
  FutureOr<void> delete(String key);
}

/// Keeps state for the lifetime of the process only. The default when no storage is given.
final class MemoryStorage implements LinkRunwayStorage {
  final Map<String, String> _values = {};

  @override
  String? read(String key) => _values[key];

  @override
  void write(String key, String value) => _values[key] = value;

  @override
  void delete(String key) => _values.remove(key);
}
