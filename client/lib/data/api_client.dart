import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/api_base_url_provider.dart';
import 'auth_token.dart';

/// The HTTP client every repository talks to. Screens **never** see Dio.
///
/// Codegen path (TODO once an openapi-generator config lands):
/// ```
/// dart run build_runner build --delete-conflicting-outputs
/// ```
/// will produce typed DTOs in `lib/data/dtos/`. Until then, repositories
/// hand-roll the few DTOs they need against `specs/openapi.yaml`.
///
/// Base URL is resolved at **runtime** by `apiBaseUrlProvider` (LOG-001).
/// Three rules, in order:
///   1. Debug `--dart-define=API_BASE_URL=...` override (kDebugMode only).
///   2. Web → `Uri.base.origin + '/api/v1'`.
///   3. Mobile → `auth_config` Hive box (LOG-003 wires it).
///
/// `apiClientProvider` `ref.watch`es `apiBaseUrlProvider` and rebuilds
/// Dio whenever the value changes. The `/api/v1` suffix is part of the
/// base URL so endpoint paths can match `openapi.yaml` verbatim
/// (`/log`, `/foods/search`, not `/api/v1/log`).
class ApiClient {
  ApiClient(this._dio, {required this.baseUrl});

  final Dio _dio;

  /// The base URL this client was constructed against. Kept on the
  /// instance for diagnostics — Dio also exposes it via
  /// `dio.options.baseUrl`.
  final String baseUrl;

  Dio get dio => _dio;
}

/// Fail-loud sentinel for when `apiBaseUrlProvider` returns `null`
/// (fresh mobile install pre-login). Dio constructs against it; the
/// first request fails with a `DioException`. The redirect rule
/// (LOG-007) keeps a null-base state pinned to the login route so
/// callers don't hit this in practice.
const String _noBaseUrlSentinel = 'about:invalid';

final apiClientProvider = Provider<ApiClient>((ref) {
  final baseUrl = ref.watch(apiBaseUrlProvider) ?? _noBaseUrlSentinel;

  final dio = Dio(
    BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
      sendTimeout: const Duration(seconds: 20),
      headers: <String, String>{
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      },
    ),
  );

  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        final token = ref.read(authTokenProvider);
        if (token != null && token.isNotEmpty) {
          options.headers['Authorization'] = 'Bearer $token';
        }
        handler.next(options);
      },
    ),
  );

  return ApiClient(dio, baseUrl: baseUrl);
});
