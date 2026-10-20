import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

/// A browser sets its own user agent, and trying to replace it turns a cross-origin call into a
/// preflight the API does not allow. The header is sent on every other platform.
const bool _inBrowser =
    bool.fromEnvironment('dart.library.js_util') || bool.fromEnvironment('dart.library.js_interop');

/// True when a failure says nothing about the request itself, so sending it again may succeed.
bool isTransient(Object error) => error is! LinkRunwayException || error.isTransient;

/// A successful API answer: the HTTP status and the JSON object in the body.
final class ApiReply {
  const ApiReply(this.status, this.data);

  final int status;
  final Map<String, Object?> data;
}

/// Sends API calls with a timeout and bounded retries. Redirects are never followed, so the key
/// is only ever sent to the configured endpoint.
final class Transport {
  Transport({
    required Uri endpoint,
    required this.apiKey,
    required this.client,
    required this.retries,
    required this.timeout,
    required this.retryDelay,
    this.userAgent,
  }) : _base = endpoint.toString().replaceFirst(RegExp(r'/+$'), '');

  final String _base;
  final String apiKey;
  final http.Client client;
  final int retries;
  final Duration timeout;
  final Duration retryDelay;
  final String? userAgent;

  Future<ApiReply> post(String path, Map<String, Object?> body) => _send('POST', path, body);

  Future<ApiReply> _send(String method, String path, Map<String, Object?> body) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await _once(method, path, body).timeout(timeout);
      } on Exception catch (error) {
        if (!isTransient(error) || attempt >= retries) rethrow;
      }
      final wait = retryDelay * (1 << attempt);
      await Future<void>.delayed(
        wait > const Duration(milliseconds: 3100) ? const Duration(milliseconds: 3100) : wait,
      );
    }
  }

  Future<ApiReply> _once(String method, String path, Map<String, Object?> body) async {
    final request =
        http.Request(method, Uri.parse('$_base/v1/$path'))
          ..followRedirects = false
          ..headers['Content-Type'] = 'application/json'
          ..headers['Authorization'] = 'Bearer $apiKey'
          ..body = jsonEncode(body);
    final agent = userAgent;
    if (agent != null && !_inBrowser) request.headers['User-Agent'] = agent;
    final response = await http.Response.fromStream(await client.send(request));
    final data = _decode(utf8.decode(response.bodyBytes, allowMalformed: true));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw LinkRunwayException(response.statusCode, _message(data));
    }
    // A success that is not a JSON object did not come from the API (a captive portal, a proxy
    // page): it is retried like a network failure and never counted as delivered.
    if (data is! Map) throw const FormatException('Unexpected tracking response');
    return ApiReply(response.statusCode, {
      for (final entry in data.entries) '${entry.key}': entry.value,
    });
  }

  static Object? _decode(String text) {
    if (text.isEmpty) return const <String, Object?>{};
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  static String _message(Object? data) {
    final message = data is Map ? data['message'] : null;
    if (message is String && message.isNotEmpty) return message;
    return message is List ? message.join(', ') : 'Tracking request failed';
  }
}
