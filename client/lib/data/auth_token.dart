import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'outbox/log_outbox_notifier.dart';

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
/// Override in tests with
/// `ProviderScope(overrides: [authTokenProvider.overrideWith(() => _Fake())])`
/// or, for read-only callers,
/// `authTokenProvider.overrideWithValue(...)` is intentionally **not**
/// supported on `NotifierProvider` — tests construct a small fake
/// notifier instead (see `test/data/auth_token_test.dart`).
class AuthTokenNotifier extends Notifier<String?> {
  @override
  String? build() => _seedToken();

  /// Seed the token from the compile-time dart-define. In release builds
  /// with no token wired we return `null` so the interceptor sends no
  /// `Authorization` header — the server will 401 and the existing
  /// interceptor surfaces that. In debug we fall back to `dev-bypass`
  /// so the local dev loop works against `DEV_AUTH_BYPASS`.
  static String? _seedToken() {
    const compileTime = String.fromEnvironment('DEV_AUTH_TOKEN');
    if (compileTime.isNotEmpty) return compileTime;
    if (kReleaseMode) return null;
    return 'dev-bypass';
  }

  /// Set the token to [token]. The next API request picks the new value
  /// up via the Dio interceptor's `ref.read(authTokenProvider)`.
  void signIn(String token) {
    state = token;
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
