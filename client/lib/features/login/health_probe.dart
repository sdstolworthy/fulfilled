/// LOG-005 — the health-probe seam the login controller depends on.
///
/// The probe is the "is the user typing at a Fulfilled server?" check
/// that runs between URL normalization (LOG-002) and the credential POST
/// (LOG-004). It GETs `/health` against the candidate base URL and
/// classifies the outcome into one of five [HealthProbeErrorKind]s so
/// the controller can render the right inline error string under the
/// URL field (T-11, architect §5.5).
///
/// The probe constructs a **fresh** [Dio] per call — it does NOT reuse
/// `apiClientProvider`'s Dio. The user is typing a candidate URL that
/// may differ from the currently-wired `apiBaseUrlProvider` value;
/// persisting + invalidating before we know the URL is good would flip
/// the app's wiring against a bad URL. Architect §5.4 names this
/// invariant explicitly.
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The five classes of probe failure. The controller switches on this
/// enum to map each kind to its canonical PM-facing message
/// (architect §5.4).
enum HealthProbeErrorKind {
  /// The host could not be resolved. Backed by [SocketException] in
  /// the wrapped [DioException]. Rendered as *"Couldn't find a server
  /// at that address."*
  dns,

  /// The server presented an untrusted certificate. Mapped from
  /// [DioExceptionType.badCertificate]. Rendered as *"Server's
  /// certificate isn't trusted."*
  tls,

  /// One of the three Dio timeout slots fired (connect / receive /
  /// send). 8s is the budget the controller passes. Rendered as
  /// *"Couldn't reach the server (timed out after 8 seconds)..."*
  timeout,

  /// The server answered with a non-200, non-404 status. Rendered as
  /// *"Server responded with <code>."*
  nonOk,

  /// The server answered with 200 + wrong body, or 404. Either way
  /// this URL is *not* a Fulfilled server. Rendered as *"That address
  /// answered, but does not look like a Fulfilled server."*
  notFound,
}

/// Thrown by [HealthProbe.probe] on any failure. The [message] field is
/// the canonical PM-facing string (architect §5.4) — the controller
/// surfaces it verbatim under the URL field.
class HealthProbeError implements Exception {
  const HealthProbeError(this.message, this.kind);

  /// The PM-facing error string, rendered as-is.
  final String message;

  /// The discriminant the controller (and tests) switch on.
  final HealthProbeErrorKind kind;

  @override
  String toString() => message;
}

/// The injectable seam. `LoginController.submit()` reads
/// [healthProbeProvider] and calls [probe] in phase 3.
///
/// Tests override the provider with a fake that throws one of the five
/// [HealthProbeErrorKind]s (see `login_url_validation_test.dart`) or
/// returns normally for the happy path (see `login_controller_test.dart`).
abstract class HealthProbe {
  /// Returns normally on a 200 + `{status: "ok"}` response. Throws
  /// [HealthProbeError] with the appropriate [HealthProbeErrorKind] on
  /// any other outcome.
  ///
  /// [baseUrl] is the *normalized* candidate URL (already ends in
  /// `/api/v1`). [timeout] is applied to all three of Dio's timeout
  /// slots — the controller passes 8s per architect §5.4.
  Future<void> probe(String baseUrl, {required Duration timeout});
}

/// Default concrete implementation — constructs a fresh [Dio] per call.
/// See file-level dartdoc for the "why fresh Dio" rationale.
class _DioHealthProbe implements HealthProbe {
  const _DioHealthProbe();

  @override
  Future<void> probe(String baseUrl, {required Duration timeout}) async {
    final dio = Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: timeout,
        receiveTimeout: timeout,
        sendTimeout: timeout,
      ),
    );
    try {
      final response = await dio.get<dynamic>('/health');
      // 200 + {status: "ok"} is the only success shape. Anything else
      // — 200 + wrong body, 200 + non-Map body, 200 + missing status
      // — falls through to the `notFound` branch (this address
      // answered, but it isn't us).
      if (response.statusCode == 200 &&
          response.data is Map &&
          (response.data as Map)['status'] == 'ok') {
        return;
      }
      if (response.statusCode == 404) {
        throw const HealthProbeError(
          'That address answered, but does not look like a Fulfilled server.',
          HealthProbeErrorKind.notFound,
        );
      }
      // 200-but-wrong-body lands here as well — the surface telling
      // the user "answered but isn't us" is the right one.
      if (response.statusCode == 200) {
        throw const HealthProbeError(
          'That address answered, but does not look like a Fulfilled server.',
          HealthProbeErrorKind.notFound,
        );
      }
      throw HealthProbeError(
        'Server responded with ${response.statusCode}.',
        HealthProbeErrorKind.nonOk,
      );
    } on DioException catch (e) {
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.sendTimeout:
          throw const HealthProbeError(
            "Couldn't reach the server (timed out after 8 seconds). "
            'Check the address and your network.',
            HealthProbeErrorKind.timeout,
          );
        case DioExceptionType.badCertificate:
          throw const HealthProbeError(
            "Server's certificate isn't trusted.",
            HealthProbeErrorKind.tls,
          );
        case DioExceptionType.connectionError:
        case DioExceptionType.cancel:
        case DioExceptionType.badResponse:
        case DioExceptionType.unknown:
          if (e.error is SocketException) {
            throw const HealthProbeError(
              "Couldn't find a server at that address.",
              HealthProbeErrorKind.dns,
            );
          }
          if (e.response?.statusCode == 404) {
            throw const HealthProbeError(
              'That address answered, but does not look like a Fulfilled '
              'server.',
              HealthProbeErrorKind.notFound,
            );
          }
          throw HealthProbeError(
            'Server responded with ${e.response?.statusCode ?? "an error"}.',
            HealthProbeErrorKind.nonOk,
          );
      }
    }
  }
}

/// Provider surface — the controller reads this in phase 3 of submit.
/// Tests override with a fake that throws / returns to exercise the
/// branch matrix.
final healthProbeProvider = Provider<HealthProbe>((_) => const _DioHealthProbe());
