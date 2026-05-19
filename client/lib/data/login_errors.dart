/// Typed error hierarchy thrown by
/// [AuthTokenNotifier.signInWithCredentials] (and, in LOG-005, the
/// `LoginController` + `HealthProbe` seam).
///
/// The `LoginController` (LOG-005) renders these inline (T-11): the
/// subclass identity drives which form field shows the message and
/// whether the BE-008 paste-JWT disclosure unfolds. Each subclass
/// carries a human-readable [message] that the controller surfaces
/// verbatim — the controller is intentionally text-free so this file
/// is the single edit site for copy tweaks.
///
/// `sealed` lets exhaustive `switch`es over `LoginError` light up at
/// compile time when a new subclass lands — the alternative
/// (`abstract` + `Object` checks in callers) is a stale-branch
/// regression waiting to happen.
sealed class LoginError implements Exception {
  const LoginError(this.message);

  /// Human-readable failure reason. Rendered verbatim by the
  /// LoginController's T-11 SnackBar / inline error row.
  final String message;

  @override
  String toString() => message;
}

/// The server responded `401 Unauthorized` to `POST /auth/login`.
/// Renders inline under the password field per T-11.
class BadCredentialsError extends LoginError {
  const BadCredentialsError()
      : super('Wrong username or password.');
}

/// The server responded `404 Not Found` to `POST /auth/login` — the
/// endpoint isn't deployed yet (architect §10 BE-008 is still TBD).
/// The LoginController catches this to flip the paste-JWT disclosure
/// (LOG-005 §5.4). This subclass also gets thrown when no JWT-shaped
/// fallback is in play and the server simply lacks the route.
class LoginEndpointMissingError extends LoginError {
  const LoginEndpointMissingError()
      : super(
          "Server doesn't support login yet — paste a bearer token "
          'in the password field.',
        );
}

/// Anything that isn't a clean 401 / 404: connection refused, DNS
/// failure, timeout, TLS handshake, 5xx, malformed response body, or
/// any other [DioException]. The [message] is a best-effort human
/// description (see `_describeDioError` in `auth_token.dart`).
class LoginNetworkError extends LoginError {
  const LoginNetworkError(super.reason);
}
