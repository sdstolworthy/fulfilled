import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/auth_config.dart';
import '../features/login/login_controller.dart';

/// Runtime API base URL seam (LOG-001).
///
/// Resolves the API base URL via three rules, in this exact order:
///
///   1. **Compile-time absolute override.** If a non-empty,
///      absolute (`http://` or `https://`) `--dart-define=API_BASE_URL=...`
///      was supplied at build time, return that. Applies in any build
///      mode — release web builds honor it so the `compose.coolify.yaml`
///      `API_BASE_URL` build-arg flows through to production. The
///      `flutter run --dart-define=API_BASE_URL=http://localhost:8080/api/v1`
///      dev loop continues to work unchanged. **Relative values are
///      ignored** (the old `/api/v1` default falls through to rule 2 so
///      the web Uri-derived path still wins — a relative bare path is
///      not a useful base URL for Dio).
///   2. **Web** (any build mode). `Uri.base.origin + '/api/v1'`. The
///      customer typed the URL into their browser; `Uri.base` is
///      canonical. NOTE: v1 strips path prefixes — operators behind
///      a reverse-proxied subpath (e.g. `/fulfilled/`) must mount at
///      the origin root. Documented limitation (architect §10.2).
///   3. **Mobile.** Read `base_url` out of the `auth_config` Hive box
///      via `ref.watch(authConfigBoxProvider).get(AuthConfigKey.baseUrl)`.
///      May be `null` on a fresh install — the redirect rule (LOG-007)
///      keeps a null-base state pinned to the login route in practice.
///
/// Watchers: `apiClientProvider` (rebuilds Dio when the URL changes)
/// + the login screen's URL field controller (seeds from the current
/// value on mount, LOG-005).
///
/// ## Test seams
///
/// Two compile-time constants are wrapped in providers so the branches
/// are testable without a real web/mobile environment:
///
///   - `kIsWebProvider` — wraps `kIsWeb`. Tests override to flip the
///     web branch on or off.
///   - `uriBaseProvider` — wraps `Uri.base`. Under `flutter_test`,
///     `Uri.base` returns `Uri.parse('about:blank')`; tests override
///     to inject a real origin.
///
/// The dart-define branch is read via `String.fromEnvironment`, which
/// is compile-time. Tests cannot vary it at runtime; the unit test
/// asserts the *branch shape* (under non-debug, the branch is skipped),
/// not the actual env read. The debug-build dev loop covers the live
/// path.
///
/// Test override:
/// ```
/// apiBaseUrlProvider.overrideWith((_) => 'https://test.example/api/v1')
/// ```

/// Compile-time fallback for the `--dart-define=API_BASE_URL=...` build
/// flag. Empty when the flag is absent. Read **only** by
/// `apiBaseUrlProvider`'s debug branch.
const String _baseUrlFromEnv = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: '',
);

/// Whether we are running on the web. Wrapping `kIsWeb` in a provider
/// makes the web branch testable. Override to `true` in tests that
/// exercise the `Uri.base.origin + '/api/v1'` path.
final kIsWebProvider = Provider<bool>((_) => kIsWeb);

/// The current `Uri.base`. Wrapping makes the web branch testable —
/// under `flutter_test`, `Uri.base` is `about:blank`. Override with a
/// real origin to assert the web rule.
final uriBaseProvider = Provider<Uri>((_) => Uri.base);

/// Whether we are running in a debug build. Wrapping `kDebugMode` in a
/// provider lets tests exercise the debug-override branch without
/// rebuilding the app under a different mode.
final kDebugModeProvider = Provider<bool>((_) => kDebugMode);

/// The runtime API base URL. See file-level dartdoc for the three-rule
/// resolution order. Returns `null` only when rule 3 reads `null` from
/// the Hive box — the apiClientProvider maps `null` to the
/// `'about:invalid'` sentinel for fail-loud behaviour.
///
/// `authConfigBoxProvider` and `AuthConfigKey` live in
/// `client/lib/data/auth_config.dart` (LOG-003). The box is opened in
/// `main.dart` and installed via `overrideWithValue`.
final apiBaseUrlProvider = Provider<String?>((ref) {
  // Rule 1: compile-time absolute dart-define. Applies in any mode so
  // the `compose.coolify.yaml` build-arg flows through to release web
  // builds (the deploy went with shape (b) — separate api/app FQDNs —
  // so the web image must bake the api FQDN at build time). Relative
  // values (e.g. the legacy `/api/v1` default) fall through to rule 2
  // because Dio can't use a base URL without an origin.
  if (_baseUrlFromEnv.startsWith('http://') ||
      _baseUrlFromEnv.startsWith('https://')) {
    return _baseUrlFromEnv;
  }

  // Rule 2: web — Uri.base.origin + '/api/v1'.
  if (ref.watch(kIsWebProvider)) {
    final base = ref.watch(uriBaseProvider);
    return '${base.origin}/api/v1';
  }

  // Rule 3: mobile — read the persisted base URL through
  // `baseUrlProvider` (the reactive notifier over the auth-config
  // Hive cell). May be `null` on a fresh install (pre-login); the
  // redirect rule (LOG-007) keeps that state pinned to the login
  // route. The login controller writes via the notifier, so this
  // provider rebuilds automatically when the URL changes — no
  // sideways `ref.invalidate(apiBaseUrlProvider)` from outside the
  // network-config domain.
  final fromBox = ref.watch(baseUrlProvider);
  if (fromBox != null && fromBox.isNotEmpty) return fromBox;

  // Rule 4: mobile, pre-submit fallback. The Hive `baseUrl` is only
  // persisted on a successful credential submit (see
  // `LoginController._runCredentialsSubmit`). Without rule 4 the OIDC
  // discovery fetch (`/auth/providers`) has no host to hit until the
  // user has already signed in — chicken-and-egg for the "Sign in
  // with Authentik" button. So: peek at the form URL the user has
  // typed; if it parses as an absolute http/https URL with a host,
  // use it. Lightly normalize (append `/api/v1` when missing) so the
  // user can type just the origin and still get the discovery hit.
  //
  // Reads the **debounced** form URL (`debouncedLoginUrlProvider`)
  // rather than the raw `loginControllerProvider.url` so a keystroke
  // burst doesn't thrash Dio. Settles 100 ms after the last
  // keystroke.
  final formUrl = ref.watch(debouncedLoginUrlProvider);
  return _tryDeriveBaseUrlFromFormInput(formUrl);
});

/// 100 ms debounced mirror of `loginControllerProvider.url`. Used by
/// [apiBaseUrlProvider] (rule 4) so each keystroke in the URL field
/// doesn't rebuild Dio + re-fire `/auth/providers`.
///
/// Why not just `Future.delayed` inside the consumer? Riverpod is
/// pull-based — there's no natural seam for "wait, then maybe
/// publish." A `StateNotifier` that owns the timer is the simplest
/// fit: it listens to the controller, cancels its pending timer on
/// every emission, schedules a new one. State settles once the
/// stream has been quiet for the timer's duration.
final debouncedLoginUrlProvider =
    StateNotifierProvider.autoDispose<_DebouncedLoginUrlNotifier, String>(
  (ref) {
    final initial = ref.read(loginControllerProvider).url;
    return _DebouncedLoginUrlNotifier(ref, initial: initial);
  },
);

/// Constant exposed for tests that want to assert the debounce window.
const Duration kLoginUrlDebounce = Duration(milliseconds: 100);

class _DebouncedLoginUrlNotifier extends StateNotifier<String> {
  _DebouncedLoginUrlNotifier(Ref ref, {required String initial})
      : super(initial) {
    // `ref.listen` returns a subscription we never explicitly cancel
    // — `autoDispose` on the provider tears the notifier down (and
    // with it the listener) when no consumer remains.
    ref.listen<String>(
      loginControllerProvider.select((s) => s.url),
      (_, next) {
        _timer?.cancel();
        _timer = Timer(kLoginUrlDebounce, () {
          if (!mounted) return;
          if (state == next) return;
          state = next;
        });
      },
    );
  }

  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// Best-effort normalization of the in-flight login-form URL. Returns
/// null for anything that wouldn't make a usable Dio base (missing
/// scheme, missing host, non-http schemes, parse failure). Lightly
/// canonicalises by trimming trailing slash + appending `/api/v1`
/// when absent.
String? _tryDeriveBaseUrlFromFormInput(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  if (uri.host.isEmpty) return null;
  var url = trimmed.endsWith('/')
      ? trimmed.substring(0, trimmed.length - 1)
      : trimmed;
  if (!url.endsWith('/api/v1')) {
    url = '$url/api/v1';
  }
  return url;
}
