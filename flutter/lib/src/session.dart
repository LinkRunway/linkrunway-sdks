import 'dart:async';
import 'dart:convert';

import 'storage.dart';
import 'values.dart';

typedef Json = Map<String, Object?>;

/// Everything the client remembers. Nothing is read, created or written while consent is off, and
/// withdrawing consent erases it from memory and from storage.
final class Session {
  Session(this._storage, this._key, this.consent, this._newId);

  static const queueLimit = 100;

  final LinkRunwayStorage _storage;
  final String _key;
  final String Function() _newId;

  bool consent;
  String? clickToken;
  List<Json> queue = [];
  Json? match;
  final Set<String> claims = {};
  String? _install;

  /// Advances on every withdrawal, so an answer that started under an earlier consent is dropped.
  int epoch = 0;

  // Storage work runs in the order it was asked for; a failing store never breaks the session.
  Future<void> _work = Future<void>.value();

  /// Completes when the storage work asked for so far is done.
  Future<void> get settled => _work;

  Future<void> _serial(Future<void> Function() task) {
    return _work = _work.then((_) async {
      try {
        await task();
      } on Object {
        // Memory-only mode remains usable.
      }
    });
  }

  /// Makes state saved under an earlier grant (a previous launch) usable again.
  Future<void> load() => _serial(() async {
    final text = await _storage.read(_key);
    if (!consent) return;
    Object? saved;
    try {
      saved = text == null ? null : jsonDecode(text);
    } on FormatException {
      saved = null;
    }
    final state = saved is Map ? saved : const <Object?, Object?>{};
    final token = state['clickToken'];
    final events = state['queue'];
    final found = state['match'];
    final done = state['claims'];
    clickToken = token is String ? token : null;
    queue = [
      if (events is List)
        for (final event in events)
          if (event is Map) {for (final entry in event.entries) '${entry.key}': entry.value},
    ];
    if (queue.length > queueLimit) queue = queue.sublist(queue.length - queueLimit);
    _install = isUuid(state['installId']) ? state['installId'] as String : null;
    match =
        found is Map && found['matched'] is bool
            ? {for (final entry in found.entries) '${entry.key}': entry.value}
            : null;
    claims
      ..clear()
      ..addAll([
        if (done is Map)
          for (final entry in done.entries)
            if (entry.value == true) '${entry.key}',
      ]);
  });

  /// Writes the current state. The snapshot is taken when the write runs, so the last write wins.
  Future<void> persist() => _serial(() async {
    if (!consent) return;
    await _storage.write(
      _key,
      jsonEncode({
        if (clickToken != null) 'clickToken': clickToken,
        'queue': queue,
        if (_install != null) 'installId': _install,
        if (match != null) 'match': match,
        if (claims.isNotEmpty) 'claims': {for (final claim in claims) claim: true},
      }),
    );
  });

  Future<void> grant() {
    if (consent) return settled;
    consent = true;
    return load();
  }

  Future<void> withdraw() {
    consent = false;
    epoch++;
    clickToken = null;
    queue = [];
    match = null;
    claims.clear();
    _install = null;
    return _serial(() async => _storage.delete(_key));
  }

  /// This install's random ID, created and saved on first use. Not a device or advertising ID.
  Future<String?> installId() async {
    await settled;
    if (!consent) return null;
    final existing = _install;
    if (existing != null) return existing;
    final supplied = _newId().toLowerCase();
    final created = _install = isUuid(supplied) ? supplied : uuidV4();
    await persist();
    return consent ? created : null;
  }

  /// True while consent has not been withdrawn since [epoch] and [installId] is still current.
  bool current(int epoch, [String? installId]) =>
      consent && epoch == this.epoch && (installId == null || installId == _install);

  /// Keeps an undelivered event for a later flush. The queue holds the newest [queueLimit] events.
  Future<void> enqueue(Json event) {
    if (!queue.any((item) => item['eventId'] == event['eventId'])) queue.add(event);
    if (queue.length > queueLimit) queue = queue.sublist(queue.length - queueLimit);
    return persist();
  }
}
