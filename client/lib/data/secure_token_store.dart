import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persistent store for the bearer token. Backed by
/// [FlutterSecureStorage], which maps to:
///
///   - iOS: Keychain (Services API).
///   - Android: EncryptedSharedPrefs (AES-GCM) via Jetpack Security.
///   - macOS: Keychain.
///   - Linux: libsecret.
///   - Windows: DPAPI.
///   - Web: `window.localStorage`. **There is no platform secure store on
///     the web** — this is documented per architect §3.5. The web tier is
///     same-origin to the API, so the bearer is gated by the browser's
///     same-origin policy; that is the threat model v1 ships against.
///     A determined attacker with XSS on the page can read the bearer,
///     same as a session cookie without `HttpOnly`. PMgr ratified this in
///     architect §10.3.
///
/// The key literal (`'auth_token'`) is intentionally short and unscoped —
/// the secure-storage namespace is per-app already, so a longer prefix
/// adds no isolation. If we ever ship multiple bearers (e.g. an offline
/// "guest" token) the key gains a discriminant suffix.
class SecureTokenStore {
  /// Default ctor — uses a fresh [FlutterSecureStorage] with default
  /// platform options. Tests construct a [SecureTokenStore] with a
  /// supplied storage (or, more commonly, implement a fake via
  /// [SecureTokenStore]'s public method surface).
  SecureTokenStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  /// The on-disk key. Stable across releases — renaming would orphan
  /// already-shipped tokens (users would silently appear signed-out).
  static const String _key = 'auth_token';

  /// Read the persisted token, or `null` if no token is stored (fresh
  /// install, or after [clear]). Returns the raw bearer string — no
  /// validation, no JWT parsing.
  Future<String?> read() => _storage.read(key: _key);

  /// Persist [token]. Overwrites any existing value. Callers should
  /// prefer to write **before** mutating in-memory state so a failed
  /// write doesn't leave the app with a session that won't survive
  /// restart.
  Future<void> write(String token) => _storage.write(key: _key, value: token);

  /// Remove the persisted token. Idempotent: clearing an already-empty
  /// store is a no-op.
  Future<void> clear() => _storage.delete(key: _key);
}

/// Provider surface for [SecureTokenStore]. Mirrors the shape of
/// `outboxBoxProvider` / `authConfigBoxProvider`: the default throws so
/// tests are forced to override with a fake, and `main.dart` overrides
/// with the real [FlutterSecureStorage]-backed implementation.
final secureTokenStoreProvider = Provider<SecureTokenStore>((ref) {
  throw UnimplementedError(
    'secureTokenStoreProvider must be overridden in main.dart with the '
    'real FlutterSecureStorage-backed implementation, or in tests with '
    'an in-memory fake.',
  );
});
