import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:linkrunway/linkrunway.dart';

const endpoint = 'https://go.example.com';
const publishableKey = 'lr_pk_test';
const storageKey = 'linkrunway:https://go.example.com:lr_pk_test';
final uuidShape = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

/// One request the client made.
final class Sent {
  Sent(this.path, this.headers, this.body);

  final String path;
  final Map<String, String> headers;
  final Map<String, Object?> body;
}

http.Response json(Object? body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

http.Response refuse(String message, [int status = 400]) => json({'message': message}, status);

/// Records each request and answers with [reply]. Throwing from [reply] is a network failure.
final class FakeApi {
  FakeApi(this.reply);

  final FutureOr<http.Response> Function(Sent request) reply;
  final List<Sent> sent = [];

  late final http.Client client = MockClient((request) async {
    final body = request.body.isEmpty ? <String, Object?>{} : jsonDecode(request.body);
    final entry = Sent(
      request.url.path.replaceFirst('/v1/', ''),
      request.headers,
      (body as Map).cast<String, Object?>(),
    );
    sent.add(entry);
    return reply(entry);
  });

  List<Sent> to(String path) => [
    for (final request in sent)
      if (request.path == path) request,
  ];
}

/// Storage that keeps values in a map the test can inspect, and counts writes.
final class RecordingStorage implements LinkRunwayStorage {
  final Map<String, String> values = {};
  int writes = 0;

  Map<String, Object?> get saved =>
      (jsonDecode(values[storageKey] ?? '{}') as Map).cast<String, Object?>();

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    writes++;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

LinkRunway client(
  FakeApi api, {
  bool consent = true,
  LinkRunwayStorage? storage,
  LinkRunwayPlatform? platform = LinkRunwayPlatform.ios,
  int retries = 0,
  String Function()? randomUuid,
  DateTime Function()? clock,
}) => LinkRunway(
  endpoint: endpoint,
  publishableKey: publishableKey,
  consent: consent,
  platform: platform,
  storage: storage,
  httpClient: api.client,
  retries: retries,
  retryDelay: const Duration(milliseconds: 1),
  randomUuid: randomUuid,
  clock: clock,
);
