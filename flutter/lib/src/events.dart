part of 'client.dart';

String _timestamp(DateTime moment) =>
    DateTime.fromMillisecondsSinceEpoch(
      moment.millisecondsSinceEpoch,
      isUtc: true,
    ).toIso8601String();

base mixin _Events on _Client {
  /// Reports an event. Returns [TrackingResult.skipped] without consent and
  /// [TrackingResult.queued] when the request could not be delivered; a queued event keeps its
  /// ID and time and is sent by [flush].
  ///
  /// Throws a [LinkRunwayException] when the API refuses the event itself.
  Future<TrackingResult> track(
    EventType type, {
    String? eventId,
    String? name,
    String? externalUserId,
    Map<String, Object?>? metadata,
    DateTime? occurredAt,
  }) async {
    // The ID and the time belong to the moment of the call, not to when storage finished loading.
    final moment = occurredAt ?? _clock();
    final id = eventId ?? uuidV4();
    await _session.settled;
    if (!_session.consent) return const TrackingResult.skipped();
    final epoch = _session.epoch;
    final installId = await _session.installId();
    if (!_session.current(epoch)) return const TrackingResult.skipped();
    final token = _session.clickToken;
    final event = <String, Object?>{
      'eventId': id,
      'type': type.wireName,
      if (name != null) 'name': name,
      if (token != null) 'clickToken': token,
      if (externalUserId != null) 'externalUserId': externalUserId,
      if (metadata != null) 'metadata': metadata,
      'occurredAt': _timestamp(moment),
      'installId': installId,
    };
    try {
      return TrackingResult.fromJson(await _deliver(event));
    } on Exception catch (error) {
      if (!_session.current(epoch)) return const TrackingResult.skipped();
      if (!isTransient(error)) rethrow;
      await _session.enqueue(event);
      return const TrackingResult.queued();
    }
  }

  /// Sends the queued events in order. Call it when connectivity returns or the app comes to the
  /// foreground. Concurrent calls share one pass.
  Future<void> flush() {
    return _flushing ??= _drain().whenComplete(() {
      _flushing = null;
    });
  }

  Future<void> _drain() async {
    await _session.settled;
    final epoch = _session.epoch;
    Object? refused;
    StackTrace? trace;
    for (final event in List.of(_session.queue)) {
      if (!_session.current(epoch)) return;
      if (!_session.queue.contains(event)) continue;
      try {
        await _deliver(event);
      } on LinkRunwayException catch (error, stack) {
        // Only these answers concern one event: an invalid event is dropped and a conflict waits
        // for the next flush. Any other failure would repeat for the rest, so the flush stops.
        if (!const {400, 409, 422}.contains(error.status)) rethrow;
        refused ??= error;
        trace ??= stack;
        if (error.status == 409) continue;
      }
      if (!_session.current(epoch)) return;
      _session.queue.remove(event);
      await _session.persist();
    }
    if (refused != null) Error.throwWithStackTrace(refused, trace ?? StackTrace.current);
  }

  // The attestation is added when a request is made, so a queued event never carries a stale one
  // and the token is never written to storage.
  Future<Json> _deliver(Json event) async {
    final attestation = _attestation;
    final body = <String, Object?>{
      ...event,
      if (attestation != null && attestation.until.isAfter(_clock()))
        'attestation': attestation.token,
      'consent': true,
    };
    try {
      return (await _api.post('track', body)).data;
    } on LinkRunwayException catch (error, stack) {
      // The API refuses an event whose click token has expired. The event is sent once more
      // without it; if that is accepted the token was the reason and is forgotten, so later
      // events are not refused too.
      final token = event['clickToken'];
      if (error.status != 400 || token == null) rethrow;
      final Json accepted;
      try {
        accepted = (await _api.post('track', {...body}..remove('clickToken'))).data;
      } on Exception catch (again) {
        // Refused again: the event itself is invalid. A network failure is worth another try.
        if (isTransient(again)) rethrow;
        Error.throwWithStackTrace(error, stack);
      }
      if (_session.clickToken == token) {
        _session.clickToken = null;
        await _session.persist();
      }
      return accepted;
    }
  }
}
