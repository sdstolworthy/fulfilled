import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';
import 'login_errors.dart';
import 'outbox/log_outbox_notifier.dart';
import 'secure_token_store.dart';

/// The bearer token the `ApiClient` interceptor attaches to every request.
///
/// v1 runs against `DEV_AUTH_BYPASS` on the Rust server (architecture §5
/// "Auth"). The seed token comes from `--dart-define=DEV_AUTH_TOKEN=...`
/// at compile time, defaulting to a plausible dev value. When real auth
/// lands (issuer + external_id), **only this notifier changes**;
/// `ApiClient` keeps reading via `ref.read(authTokenProvider)`.
///
/// Migrated to a `Notifier` in T-019 so the profile sign-out flow stops
/// being a no-op. Existing readers continue to call
/// `ref.read(authTokenProvider)` (returns `String?`); the small set of
/// callers that mutate (today: only the profile sign-out row) reach for
/// the `.notifier` accessor — `ref.read(authTokenProvider.notifier).signOut()`.
///
/// LOG-003 wires persistence through [SecureTokenStore]. `build()` returns
/// the dev-bypass seed synchronously (Riverpod constraint), then kicks
/// off an async read of the platform secure store and replaces state
/// with the persisted bearer if one exists. `signIn` writes through to
/// the store; `signOut` clears it.
///
/// Override in tests with
/// `ProviderScope(overrides: [authTokenProvider.overrideWith(() => _Fake())])`
/// or, for read-only callers,
/// `authTokenProvider.overrideWithValue(...)` is intentionally **not**
/// supported on `NotifierProvider` — tests construct a small fake
/// notifier instead (see `test/data/auth_token_test.dart`).
class AuthTokenNotifier extends Notifier<String?> {
  @override
  String? build() {
    // Riverpod's `Notifier.build()` is synchronous. Seed with the
    // dev-bypass / dart-define value so the initial render has a
    // usable token, then asynchronously replace it from secure storage
    // if a real bearer is persisted. The store read is fire-and-forget
    // — any error leaves the dev seed in place.
    _hydrateFromSecureStore();
    return _seedToken();
  }

  /// One-shot async load from [SecureTokenStore]. If a bearer is found
  /// it replaces the dev seed; if not, state stays at whatever the
  /// dev-bypass branch returned. Errors are swallowed — the dev seed
  /// (or null) is a safe fallback and a 401 will route the user to
  /// `/login` regardless.
  Future<void> _hydrateFromSecureStore() async {
    try {
      final stored = await ref.read(secureTokenStoreProvider).read();
      if (stored != null && stored.isNotEmpty) {
        state = stored;
      }
    } catch (_) {
      // Intentionally swallowed — failure to hydrate is non-fatal.
    }
  }

  /// Seed the token from the compile-time dart-define. In release builds
  /// with no token wired we return `null` so the interceptor sends no
  /// `Authorization` header — the server will 401 and the existing
  /// interceptor surfaces that. In debug we fall back to `dev-bypass`
  /// so the local dev loop works against `DEV_AUTH_BYPASS`.
  ///
  /// Order (per architect_login.md §7.3):
  ///   1. compile-time `DEV_AUTH_TOKEN` wins if non-empty;
  ///   2. else if `kDebugMode && !DEV_AUTH_BYPASS_DISABLE` → `'dev-bypass'`
  ///      (the LOG-007 dev-loop trapdoor: a dev exercising the login
  ///      flow runs `flutter run --dart-define=DEV_AUTH_BYPASS_DISABLE=1`
  ///      to opt out of the seed without recompiling against
  ///      `kDebugMode`);
  ///   3. else `null`. **Release builds always return `null`** — the
  ///      `kDebugMode` gate means the dev-bypass branch is dead code
  ///      under release and the user lands on `/login`.
  static String? _seedToken() {
    const fromDartDefine =
        String.fromEnvironment('DEV_AUTH_TOKEN', defaultValue: '');
    if (fromDartDefine.isNotEmpty) return fromDartDefine;
    const bypassDisable =
        bool.fromEnvironment('DEV_AUTH_BYPASS_DISABLE', defaultValue: false);
    // Debug-only — `kDebugMode` is `false` under release, so the
    // `'dev-bypass'` branch is unreachable in shipped builds.
    if (kDebugMode && !bypassDisable) return 'dev-bypass';
    return null;
  }

  /// Set the token to [token]. The next API request picks the new value
  /// up via the Dio interceptor's `ref.read(authTokenProvider)`.
  ///
  /// Persists to [SecureTokenStore] **before** flipping in-memory state
  /// so a failed write doesn't leave the app with a session that won't
  /// survive an app restart.
  Future<void> signIn(String token) async {
    await ref.read(secureTokenStoreProvider).write(token);
    state = token;
  }

  /// Trade [username] + [password] for a bearer token by POSTing to
  /// `<baseUrl>/auth/login`. On success, persists the token via
  /// [signIn] (writes to [SecureTokenStore] then flips notifier
  /// state).
  ///
  /// **JWT-paste workaround (v1 only, until BE-008 lands).** If
  /// [password] matches the three-segment base64url shape of a JWT
  /// (`xxx.yyy.zzz`), the method **skips the POST entirely** and
  /// signs the user in with the password value as the literal
  /// bearer. This lets users authenticate against servers that
  /// haven't shipped `POST /auth/login` yet by pasting a hand-issued
  /// JWT into the password field. PM directive — see architect_login.md
  /// §3.6. The shortcut stays as a fallback for older self-hosted
  /// deployments once BE-008 lands.
  ///
  /// Throws (all from the [LoginError] sealed hierarchy):
  ///   - [BadCredentialsError] on `401` from the server — the
  ///     LoginController renders this inline under the password field.
  ///   - [LoginEndpointMissingError] on `404` — the LoginController
  ///     flips its `pastedJwtMode` flag and renders the BE-008
  ///     disclosure (LOG-005 §5.4).
  ///   - [LoginNetworkError] on any other DioException (timeout,
  ///     connection refused, TLS handshake, 5xx, malformed response).
  ///
  /// `expires_at` on the response is intentionally ignored in v1
  /// per architect §10.7 — proactive expiry tracking is the gateway
  /// drug to refresh-token rotation, which PM punted. The 401-sweep
  /// interceptor (see `api_client.dart`) catches stale tokens.
  // TODO BE-008-refresh: expires_at intentionally ignored in v1 per
  // architect_login.md §10.7.
  Future<void> signInWithCredentials({
    required String username,
    required String password,
  }) async {
    // JWT-shape detection: three base64url segments separated by
    // dots. We don't validate the signature — the server does that
    // on the first authenticated request, and a malformed bearer
    // surfaces as the 401-sweep. The shape guard is purely
    // defensive against "user typed their actual password and we
    // shipped it as a bearer."
    if (_jwtShape.hasMatch(password)) {
      await signIn(password);
      return;
    }

    final dio = ref.read(apiClientProvider).dio;
    try {
      final response = await dio.post<dynamic>(
        '/auth/login',
        data: <String, String>{
          'username': username,
          'password': password,
        },
        // Defensive: strip any stale bearer the request interceptor
        // would otherwise attach. `/auth/login` is `security: []` on
        // the server side per the BE-008 contract; keeping the wire
        // clean avoids surprising the server.
        options: Options(headers: <String, String>{'Authorization': ''}),
      );

      final body = response.data;
      if (body is! Map ||
          body['token'] is! String ||
          (body['token'] as String).isEmpty) {
        throw const LoginNetworkError('Login response missing token.');
      }
      final token = body['token'] as String;
      // `signIn` persists to secure storage **before** mutating
      // in-memory state — a failed write keeps the notifier at its
      // pre-call value (architect §3.2).
      await signIn(token);
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 401) {
        throw const BadCredentialsError();
      }
      if (status == 404) {
        throw const LoginEndpointMissingError();
      }
      throw LoginNetworkError(_describeDioError(e));
    }
  }

  /// Clear the token + the outbox Hive box. The profile screen calls
  /// this after a destructive `AlertDialog` confirmation (T-11).
  ///
  /// Today only `outbox_log` is opened (`client/lib/main.dart`). Per the
  /// architect's "inventory before clearing" note, we touch only the
  /// boxes that actually exist — clearing a not-yet-opened box would
  /// throw. Future per-domain boxes (recent foods, weights, profile)
  /// extend this list as they land.
  ///
  /// Navigation back to `/onboarding/1` is the **caller's** job — this
  /// notifier stays free of `BuildContext` / `GoRouter` so it remains
  /// unit-testable without a widget tree.
  Future<void> signOut() async {
    state = null;
    // Clear the persisted bearer so the next app launch doesn't
    // resurrect the signed-out session via `_hydrateFromSecureStore`.
    await ref.read(secureTokenStoreProvider).clear();
    // The outbox box is the only Hive box opened today. Read it through
    // the provider so a test that overrides `outboxBoxProvider` with a
    // fake box sees its `clear()` invoked.
    final outbox = ref.read(outboxBoxProvider);
    await outbox.clear();
  }
}

/// Provider surface for the auth token. Readers continue to call
/// `ref.read(authTokenProvider)` (returns the current `String?`).
/// Mutators reach for `ref.read(authTokenProvider.notifier)`.
final authTokenProvider =
    NotifierProvider<AuthTokenNotifier, String?>(AuthTokenNotifier.new);

/// Three base64url segments separated by dots. Anchored at both ends
/// so an embedded JWT-looking substring (e.g. a password that
/// happens to contain dots) doesn't match. Base64url alphabet:
/// `[A-Za-z0-9_-]`. We accept (but don't require) padding-free
/// segments — JWTs are unpadded by RFC 7515, but a user pasting an
/// older `=`-padded blob would still pass the eyeball test as a
/// JWT; the server is the ultimate validator, this regex is just
/// the "did the user paste a credential vs. type a password" guard.
///
/// Edge case: an empty segment between dots (`a..c`) fails the `+`
/// quantifier, so a literal `..` won't match. Negative example: a
/// 20-character password like `Pa55w0rd.foo.bar` would match and
/// be sent as a bearer — accepted risk per architect §3.6 ("we
/// don't actually parse the JWT — the server validates it"). The
/// failure mode there is a 401 on the next authenticated request,
/// which the 401-sweep handles.
final RegExp _jwtShape =
    RegExp(r'^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$');

/// Best-effort human description for a [DioException] that wasn't a
/// 401 or 404. The LoginController surfaces the message verbatim as
/// a T-11 inline error row; keep these short and copy-stable.
String _describeDioError(DioException e) {
  switch (e.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
      return 'The server took too long to respond. Check your connection.';
    case DioExceptionType.connectionError:
      return "Couldn't reach the server. Check the server URL and your network.";
    case DioExceptionType.badCertificate:
      return 'The server certificate is invalid.';
    case DioExceptionType.cancel:
      return 'Login was cancelled.';
    case DioExceptionType.badResponse:
      final status = e.response?.statusCode;
      if (status != null) {
        return 'Server responded with $status. Try again in a moment.';
      }
      return 'Server returned an unexpected response.';
    case DioExceptionType.unknown:
      return e.message ?? 'Unknown network error.';
  }
}
