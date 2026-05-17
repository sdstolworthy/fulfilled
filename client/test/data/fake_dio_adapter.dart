import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// A response shape that lets a test scenario return either a normal
/// HTTP response (status + body) or throw a transport-level
/// [DioException] (timeout, connection refused, etc.) — the latter is
/// modelled by Dio as the adapter throwing.
///
/// We don't mock `Dio` itself because the SUT
/// (`AuthTokenNotifier.signInWithCredentials`) reads the real Dio off
/// `apiClientProvider`, and the interceptor pipeline (request-side
/// auth header, error-side 401-sweep) must run end-to-end for the
/// tests to be meaningful. Replacing the adapter is the smallest
/// possible wedge: it leaves Dio + interceptors intact and only
/// intercepts the byte-level fetch.
class FakeDioAdapter implements HttpClientAdapter {
  FakeDioAdapter(this._handler);

  /// The handler receives the outgoing [RequestOptions] and returns a
  /// `ResponseBody` for status/body, or throws a `DioException` to
  /// simulate transport failures (timeout / connectionError / etc).
  /// Test code can capture [RequestOptions] for assertions.
  final FutureOr<ResponseBody> Function(RequestOptions options) _handler;

  /// Every request seen by the adapter, in order. Tests assert on the
  /// path / method / headers / body that the SUT produced.
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<dynamic>? cancelFuture,
  ) async {
    requests.add(options);
    return _handler(options);
  }

  @override
  void close({bool force = false}) {}
}

/// Build a `ResponseBody` from a JSON-encodable map and status code.
/// Sets `content-type: application/json` so Dio's default
/// `ResponseType.json` transformer parses the body into a `Map`.
ResponseBody jsonResponse(int status, Map<String, dynamic> body) {
  final encoded = utf8.encode(jsonEncode(body));
  return ResponseBody.fromBytes(
    encoded,
    status,
    headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>['application/json; charset=utf-8'],
    },
  );
}

/// Build a `ResponseBody` representing a non-2xx response with an
/// empty body. Used for 401 / 404 / 5xx assertions where the body
/// content is irrelevant.
ResponseBody emptyResponse(int status) {
  return ResponseBody.fromBytes(
    <int>[],
    status,
    headers: <String, List<String>>{},
  );
}
