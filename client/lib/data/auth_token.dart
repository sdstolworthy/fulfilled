import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The bearer token the `ApiClient` interceptor attaches to every request.
///
/// v1 runs against `DEV_AUTH_BYPASS` on the Rust server (architecture §5
/// "Auth"). The token is read from the `--dart-define=DEV_AUTH_TOKEN=...`
/// environment at compile time, defaulting to a plausible dev value. When
/// real auth lands (issuer + external_id), **only this provider changes**;
/// `ApiClient` keeps reading via `ref.read(authTokenProvider)`.
///
/// Override in tests with `ProviderScope(overrides: [authTokenProvider.overrideWithValue('test-token')])`.
final authTokenProvider = Provider<String?>((ref) {
  const compileTime = String.fromEnvironment('DEV_AUTH_TOKEN');
  if (compileTime.isNotEmpty) return compileTime;
  if (kReleaseMode) return null;
  return 'dev-bypass';
});
