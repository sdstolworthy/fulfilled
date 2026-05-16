import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
/// Base URL is `--dart-define=API_BASE_URL=...`, defaulting to the local
/// Rust dev server (`http://localhost:8080/api/v1`). The `/api/v1` suffix is
/// part of the base URL so endpoint paths can match `openapi.yaml` verbatim
/// (`/log`, `/foods/search`, not `/api/v1/log`).
class ApiClient {
  ApiClient(this._dio);

  final Dio _dio;

  Dio get dio => _dio;

  static const String defaultBaseUrl = 'http://localhost:8080/api/v1';
}

const String _baseUrlFromEnv = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: ApiClient.defaultBaseUrl,
);

final apiClientProvider = Provider<ApiClient>((ref) {
  final dio = Dio(
    BaseOptions(
      baseUrl: _baseUrlFromEnv,
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

  return ApiClient(dio);
});
