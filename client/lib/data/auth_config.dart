import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

/// The `auth_config` Hive box holds non-secret app-level configuration —
/// the server base URL the user chose at login, and the last username they
/// signed in with. The bearer token does **NOT** live here: Hive is local
/// plaintext on disk; tokens belong in the platform keystore (see
/// `secure_token_store.dart`).
///
/// Survives sign-out (PM directive: re-login should be two field touches
/// — password + tap — not three). Architect §4.1.
const String authConfigBoxName = 'auth_config';

/// String keys for the `auth_config` Hive box. Keep these literals stable
/// across releases — renaming a key would invalidate already-shipped user
/// data. Tested in `test/data/auth_config_test.dart`.
class AuthConfigKey {
  AuthConfigKey._();

  /// The server base URL the user signed in against. Persisted so the
  /// login screen can pre-fill the field after sign-out.
  static const String baseUrl = 'base_url';

  /// The last username the user signed in with. Persisted so the login
  /// screen can pre-fill the field after sign-out.
  static const String lastUsername = 'last_username';
}

/// Provider surface for the `auth_config` Hive box. Mirrors the shape of
/// `outboxBoxProvider`: the provider throws if read before `main.dart` has
/// opened the box and installed the override. Tests override with a
/// temp-directory Hive box (see `test/data/auth_config_test.dart`).
final authConfigBoxProvider = Provider<Box<String>>((ref) {
  throw UnimplementedError(
    'authConfigBoxProvider must be overridden in main.dart with the open '
    'Hive box. See main.dart for the override.',
  );
});

/// Reactive seam over the auth-config Hive box's `base_url` cell.
///
/// Audit-fix F5: the login controller used to write to Hive and then
/// imperatively `ref.invalidate(apiBaseUrlProvider)` from outside the
/// network-config domain. That worked but hid the dependency arrow —
/// reading `apiBaseUrlProvider` you couldn't tell what made it
/// recompute. The notifier lifts the write back into Riverpod so the
/// arrow is one-way: login calls `setBaseUrl`; downstream watchers
/// (`apiBaseUrlProvider`, …) `ref.watch(baseUrlProvider)` and rebuild
/// automatically.
///
/// Persistence still terminates in Hive — the notifier is a thin
/// adapter, not a cache. Initial state is read from the box at
/// construction. Test seam: override `authConfigBoxProvider` with a
/// pre-seeded box and `baseUrlProvider`'s initial state picks that up;
/// override `baseUrlProvider` directly when a test wants to force a
/// specific value without touching Hive.
final baseUrlProvider =
    StateNotifierProvider<BaseUrlNotifier, String?>((ref) {
  return BaseUrlNotifier(ref.watch(authConfigBoxProvider));
});

class BaseUrlNotifier extends StateNotifier<String?> {
  BaseUrlNotifier(this._box) : super(_box.get(AuthConfigKey.baseUrl));

  final Box<String> _box;

  /// Persist [url] to the auth-config box and publish it through the
  /// notifier so every watcher rebuilds. Order matters: write first,
  /// publish second — a downstream that synchronously re-reads the
  /// box on rebuild (e.g. the profile screen's server-URL row) finds
  /// the persisted value rather than the previous one.
  Future<void> setBaseUrl(String url) async {
    await _box.put(AuthConfigKey.baseUrl, url);
    state = url;
  }
}

/// Reactive seam over the auth-config Hive box's `last_username` cell.
///
/// Same shape as [baseUrlProvider] — exists so UI code (the login
/// controller) doesn't import `package:hive` or reach into the box
/// directly. Login reads the current value via
/// `ref.read(lastUsernameProvider)` and writes via
/// `ref.read(lastUsernameProvider.notifier).setLastUsername(...)`.
final lastUsernameProvider =
    StateNotifierProvider<LastUsernameNotifier, String?>((ref) {
  return LastUsernameNotifier(ref.watch(authConfigBoxProvider));
});

class LastUsernameNotifier extends StateNotifier<String?> {
  LastUsernameNotifier(this._box)
      : super(_box.get(AuthConfigKey.lastUsername));

  final Box<String> _box;

  Future<void> setLastUsername(String username) async {
    await _box.put(AuthConfigKey.lastUsername, username);
    state = username;
  }
}

/// Test seam — clears every cell in the auth-config box. Pulled out of
/// `LoginController.resetForTesting` so the UI layer doesn't have to
/// import the box provider; tests that need a clean slate call this
/// helper from the `data/` layer that already owns the box.
Future<void> resetAuthConfigForTesting(Ref ref) async {
  await ref.read(authConfigBoxProvider).clear();
}
