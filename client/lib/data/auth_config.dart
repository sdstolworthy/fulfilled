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
