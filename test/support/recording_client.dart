import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class RecordedRequest {
  RecordedRequest(this.method, this.uri, this.body, this.authorization, [this.contentType]);

  final String method;
  final Uri uri;
  final String body;
  final String? authorization;
  final String? contentType;

  /// `METHOD /path?query`, like the Summary of the original test handler.
  String get summary => '$method ${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';

  Object? get json => body.isEmpty ? null : jsonDecode(body);
}

/// An http client that records requests and answers them with [respond].
class RecordingClient {
  RecordingClient(http.Response Function(RecordedRequest request) respond) {
    client = MockClient((request) async {
      final recorded = RecordedRequest(
        request.method,
        request.url,
        latin1.decode(request.bodyBytes),
        request.headers['Authorization'],
        request.headers['content-type'],
      );
      requests.add(recorded);
      return respond(recorded);
    });
  }

  late final http.Client client;
  final List<RecordedRequest> requests = [];

  static http.Response json(Object? body, [int statusCode = 200]) => http.Response(
    body is String ? body : jsonEncode(body),
    statusCode,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}
