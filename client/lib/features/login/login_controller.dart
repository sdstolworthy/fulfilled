/// LOG-005 — the login form's state machine.
///
/// Owns the form state ([LoginFormState]) + the five-phase submit
/// flow (architect §5.4):
///
///   1. **BE-008 workaround branch** — early return when
///      `state.pastedJwtMode` is set: shape-check the password as a
///      JWT and `signIn(password)` it directly, skipping
///      `/auth/login`.
///   2. **URL normalize** — mobile only (skipped on `kIsWeb`).
///   3. **Health probe** — `GET <candidate>/health` with an 8s
///      budget; classifies failures into [HealthProbeErrorKind].
///   4. **Persist via baseUrlProvider** — push the normalized URL
///      through the `baseUrlProvider` notifier. The notifier writes
///      to Hive and publishes to every `ref.watch(baseUrlProvider)`
///      observer — `apiBaseUrlProvider` is one, and `apiClientProvider`
///      chains off it, so Dio rebuilds against the new URL **before**
///      phase 5 fires (Case F asserts this ordering).
///   5. **Credential POST** — `signInWithCredentials(...)` through
///      the freshly-wired Dio.
///
/// The whole body is wrapped in `submitting: true` at entry and a
/// `finally` that flips it back to `false`. Tenants: **T-08** (the
/// `submitting` bool drives the LOG-006 button skeleton), **T-11**
/// (three inline error slots).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/auth_config.dart';
import '../../data/auth_token.dart';
import '../../data/login_errors.dart';
import '../../providers/api_base_url_provider.dart';
import '../../providers/profile_providers.dart';
import 'health_probe.dart';
import 'url_normalize.dart';

/// The login form's immutable state. The three error slots
/// ([urlError], [credentialsError], [formError]) map 1:1 to the three
/// T-11 inline error rows the screen renders (architect §5.5).
@immutable
class LoginFormState {
  const LoginFormState({
    required this.url,
    required this.username,
    required this.password,
    required this.allowInsecure,
    this.endpointMissing = false,
    this.pastedJwtMode = false,
    this.submitting = false,
    this.urlError,
    this.credentialsError,
    this.formError,
  });

  /// The server URL the user typed. May or may not be normalized — the
  /// raw input is held here; normalization runs in submit phase 2.
  final String url;

  /// The username the user typed. Sent verbatim as the `username`
  /// field of `POST /auth/login`.
  final String username;

  /// The password the user typed. In `pastedJwtMode` this is the
  /// pasted JWT bearer; otherwise it's the literal password.
  final String password;

  /// Per-session "I understand this is HTTP" toggle. Pre-seeded to
  /// `true` from the loginControllerProvider if the previously-stored
  /// URL was `http://` (architect §5.6 — the LOG-S6 sticky case).
  final bool allowInsecure;

  /// Set to `true` after `/auth/login` returns 404; the screen
  /// renders the BE-008 paste-JWT disclosure under the form.
  final bool endpointMissing;

  /// Set to `true` after the user accepts the BE-008 disclosure
  /// (via [LoginController.acceptJwtDisclosure]). The next
  /// submit short-circuits past `/auth/login`.
  final bool pastedJwtMode;

  /// Drives the T-08 button skeleton. Flipped to `true` at submit
  /// entry, back to `false` in a `finally`.
  final bool submitting;

  /// Inline error under the URL field (T-11). Cleared on the next
  /// keystroke and on `toggleAllowInsecure`.
  final String? urlError;

  /// Inline error under the password field (T-11). Cleared on the
  /// next keystroke in username or password.
  final String? credentialsError;

  /// Non-modal warning row below the submit button (T-11). For
  /// errors that don't belong under a specific field — TLS,
  /// connection refused, missing-token-on-200.
  final String? formError;

  LoginFormState copyWith({
    String? url,
    String? username,
    String? password,
    bool? allowInsecure,
    bool? endpointMissing,
    bool? pastedJwtMode,
    bool? submitting,
    Object? urlError = _sentinel,
    Object? credentialsError = _sentinel,
    Object? formError = _sentinel,
  }) {
    return LoginFormState(
      url: url ?? this.url,
      username: username ?? this.username,
      password: password ?? this.password,
      allowInsecure: allowInsecure ?? this.allowInsecure,
      endpointMissing: endpointMissing ?? this.endpointMissing,
      pastedJwtMode: pastedJwtMode ?? this.pastedJwtMode,
      submitting: submitting ?? this.submitting,
      urlError:
          identical(urlError, _sentinel) ? this.urlError : urlError as String?,
      credentialsError: identical(credentialsError, _sentinel)
          ? this.credentialsError
          : credentialsError as String?,
      formError: identical(formError, _sentinel)
          ? this.formError
          : formError as String?,
    );
  }
}

/// Sentinel for [LoginFormState.copyWith] so callers can distinguish
/// "leave the slot alone" (the default) from "clear the slot to null"
/// (pass `null` explicitly).
const Object _sentinel = Object();

/// The form's state machine. See the file-level dartdoc for the
/// five-phase submit flow.
class LoginController extends StateNotifier<LoginFormState> {
  LoginController(this._ref, {required LoginFormState initial}) : super(initial);

  final Ref _ref;

  // ─── Plain setters — clear the matching error slot on each keystroke ─────

  void setUrl(String v) =>
      state = state.copyWith(url: v, urlError: null);

  void setUsername(String v) => state = state.copyWith(
        username: v,
        credentialsError: null,
      );

  void setPassword(String v) => state = state.copyWith(
        password: v,
        credentialsError: null,
      );

  /// Flip the per-session HTTP-allow toggle. Clears the URL error so
  /// the user sees a clean field after tapping the disclosure
  /// (architect §5.6 — the next submit re-normalizes).
  void toggleAllowInsecure() => state = state.copyWith(
        allowInsecure: !state.allowInsecure,
        urlError: null,
      );

  /// Accept the BE-008 paste-JWT disclosure. Flips the form into
  /// "treat password as a literal bearer" mode and clears the
  /// endpoint-missing flag so the disclosure folds back up.
  void acceptJwtDisclosure() => state = state.copyWith(
        pastedJwtMode: true,
        endpointMissing: false,
      );

  /// Run the five-phase submit flow. Returns `true` on success
  /// (caller routes to `/today`), `false` on any failure (the form
  /// state carries the inline error).
  ///
  /// `submitting` is `true` for the lifetime of this call (drives the
  /// T-08 skeleton on the submit button). The `finally` guarantees
  /// it flips back even on uncaught exceptions.
  Future<bool> submit() async {
    state = state.copyWith(
      submitting: true,
      urlError: null,
      credentialsError: null,
      formError: null,
    );
    try {
      // ── Phase 1: BE-008 paste-JWT workaround (early return). ──
      if (state.pastedJwtMode) {
        final raw = state.password.trim();
        if (!_looksLikeJwt(raw)) {
          state = state.copyWith(
            credentialsError: "That doesn't look like a JWT.",
          );
          return false;
        }
        await _ref.read(authTokenProvider.notifier).signIn(raw);
        await _persistConfig(state.url, state.username);
        return true;
      }

      // ── Phase 2: URL normalize (mobile only). ──
      late final String normalized;
      if (kIsWeb) {
        final fromProvider = _ref.read(apiBaseUrlProvider);
        if (fromProvider == null) {
          state = state.copyWith(
            formError: "Couldn't determine server URL from this page.",
          );
          return false;
        }
        normalized = fromProvider;
      } else {
        try {
          normalized = normalizeServerUrl(
            state.url,
            allowInsecure: state.allowInsecure,
          );
        } on UrlNormalizeError catch (e) {
          // All three kinds (empty, malformed, insecureScheme) carry
          // canonical PM-facing messages — render them verbatim. The
          // screen reads `state.allowInsecure` to decide whether to
          // show the Allow-HTTP disclosure under an insecureScheme
          // error (architect §5.6).
          state = state.copyWith(urlError: e.message);
          return false;
        }
      }

      // ── Phase 3: Health probe (8s timeout). ──
      try {
        await _ref.read(healthProbeProvider).probe(
              normalized,
              timeout: const Duration(seconds: 8),
            );
      } on HealthProbeError catch (e) {
        state = state.copyWith(urlError: e.message);
        return false;
      }

      // ── Phase 4: Persist via the base-URL notifier. ──
      //
      // The notifier writes to Hive AND publishes the new value to
      // every watcher of `baseUrlProvider` — `apiBaseUrlProvider` is
      // one of those, and `apiClientProvider` chains off it, so Dio
      // rebuilds against the fresh URL before phase 5 fires.
      // Audit-fix F5: this used to be a hand-rolled `box.put +
      // invalidate(apiBaseUrlProvider)` from outside the network-config
      // domain. Case F still asserts the call ordering, but it now
      // observes the notifier emission rather than the invalidate.
      await _ref.read(baseUrlProvider.notifier).setBaseUrl(normalized);

      // ── Phase 5: Credential POST. ──
      try {
        await _ref.read(authTokenProvider.notifier).signInWithCredentials(
              username: state.username,
              password: state.password,
            );
      } on BadCredentialsError catch (e) {
        state = state.copyWith(credentialsError: e.message);
        return false;
      } on LoginEndpointMissingError {
        // The screen renders the JWT-paste disclosure under the form
        // — that's the "tap to enter paste-JWT mode" affordance. The
        // disclosure-tap fires `acceptJwtDisclosure()` which sets
        // `pastedJwtMode = true`; the next submit takes phase 1.
        state = state.copyWith(endpointMissing: true);
        return false;
      } on LoginNetworkError catch (e) {
        state = state.copyWith(formError: e.message);
        return false;
      }

      // On success, re-persist baseUrl (idempotent) + lastUsername.
      // The re-write is fine — Hive's `put` is overwrite-or-create.
      await _persistConfig(normalized, state.username);
      // Force `meProvider` to refetch with the freshly-installed
      // bearer. Without this its pre-login `AsyncError` (from the
      // boot-time `GET /me` 401) lingers and the router's
      // onboarding gate keeps reading `me.value == null`, which
      // either races the post-submit `context.go(/today)` call or
      // leaves the redirect stuck. Mirrors the OIDC path's
      // post-signIn invalidation in `oidc_exchange.dart`.
      _ref.invalidate(meProvider);
      return true;
    } finally {
      state = state.copyWith(submitting: false);
    }
  }

  /// Write both `auth_config` keys. Called on every successful submit
  /// (phase 1 or phase 5) so the next visit pre-fills the URL +
  /// username fields. Both writes flow through their notifier so the
  /// UI layer stays ignorant of the underlying Hive box.
  Future<void> _persistConfig(String url, String username) async {
    await _ref.read(baseUrlProvider.notifier).setBaseUrl(url);
    await _ref
        .read(lastUsernameProvider.notifier)
        .setLastUsername(username);
  }
}

/// JWT-shape heuristic — three non-empty dot-separated segments. The
/// server is the ultimate validator; this guard only stops the user
/// from accidentally shipping a non-JWT password as a bearer.
/// Architect §3.6 names the exact predicate.
bool _looksLikeJwt(String raw) {
  final parts = raw.split('.');
  return parts.length == 3 && parts.every((s) => s.isNotEmpty);
}

/// The controller's provider. `autoDispose` because login is one-shot
/// — popping the route should clear the password buffer (architect
/// §5.3 "Why autoDispose").
///
/// Initial state is pre-seeded via the auth-config notifiers:
///   - `url` ← `baseUrlProvider` (mobile only — web reads from
///     `apiBaseUrlProvider` at submit time).
///   - `username` ← `lastUsernameProvider`.
///   - `allowInsecure` ← `true` if the persisted URL is `http://`
///     (architect §5.6 — the LOG-S6 sticky case).
///
/// The notifiers terminate in Hive, but the controller doesn't know
/// or care — the UI layer depends on Riverpod seams only.
final loginControllerProvider =
    StateNotifierProvider.autoDispose<LoginController, LoginFormState>(
  (ref) {
    final persistedUrl = ref.watch(baseUrlProvider);
    final persistedUsername = ref.watch(lastUsernameProvider);
    return LoginController(
      ref,
      initial: LoginFormState(
        url: kIsWeb ? '' : (persistedUrl ?? ''),
        username: persistedUsername ?? '',
        password: '',
        allowInsecure: persistedUrl?.startsWith('http://') ?? false,
      ),
    );
  },
);
