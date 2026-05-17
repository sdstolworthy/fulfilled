import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api_client.dart';
import '../../data/auth_token.dart';

/// Result of exchanging an OIDC handoff code for an opaque bearer.
sealed class OidcExchangeResult {
  const OidcExchangeResult();

  /// Successful sign-in. The token is already stored via
  /// [AuthTokenNotifier.signIn] — callers just need to navigate.
  factory OidcExchangeResult.success() = OidcExchangeSuccess;

  /// Anything that prevented sign-in: server 4xx/5xx, network
  /// failure, malformed response. [message] is render-ready.
  factory OidcExchangeResult.error(String message) = OidcExchangeError;
}

class OidcExchangeSuccess extends OidcExchangeResult {
  const OidcExchangeSuccess();
}

class OidcExchangeError extends OidcExchangeResult {
  const OidcExchangeError(this.message);
  final String message;
}

/// `POST /auth/oidc/exchange {code}` → opaque bearer → store via
/// `authTokenProvider.signIn`. Shared between the web `LoginScreen`'s
/// inline handler (consumes `?oidc_code=…` off `Uri.base`) and the
/// mobile `OidcButton` (consumes the handoff returned from the
/// in-app webview).
///
/// Does not navigate — callers handle routing on success.
Future<OidcExchangeResult> runOidcExchange({
  required WidgetRef ref,
  required String handoff,
}) async {
  try {
    final dio = ref.read(apiClientProvider).dio;
    final res = await dio.post<dynamic>(
      '/auth/oidc/exchange',
      data: <String, String>{'code': handoff},
    );
    final body = res.data;
    if (body is! Map ||
        body['token'] is! String ||
        (body['token'] as String).isEmpty) {
      return OidcExchangeResult.error(
        'Sign-in completed but the server returned no token. '
        'Please try again.',
      );
    }
    final token = body['token'] as String;
    await ref.read(authTokenProvider.notifier).signIn(token);
    return OidcExchangeResult.success();
  } on DioException catch (e) {
    final status = e.response?.statusCode;
    final message = _extractServerMessage(e.response?.data) ??
        (status == null
            ? "Couldn't reach the server. Check your connection and "
                'try again.'
            : 'Sign-in failed (server returned $status).');
    return OidcExchangeResult.error(message);
  } catch (_) {
    return OidcExchangeResult.error(
      'An unexpected error occurred. Please try again.',
    );
  }
}

/// Lift a server-provided message off a 4xx/5xx body. Mirrors the
/// shape `LoginScreen._extractServerMessage` used to walk before this
/// helper was factored out.
String? _extractServerMessage(Object? body) {
  if (body is! Map) return null;
  final m = body['message'] ?? body['error'] ?? body['detail'];
  if (m is String && m.isNotEmpty) return m;
  return null;
}
