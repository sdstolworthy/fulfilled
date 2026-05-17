import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/auth_config.dart';

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

  // Rule 3: mobile — read from the auth_config Hive box. May be `null`
  // on a fresh install (pre-login); the redirect rule (LOG-007) keeps
  // that state pinned to the login route.
  final box = ref.watch(authConfigBoxProvider);
  return box.get(AuthConfigKey.baseUrl);
});
