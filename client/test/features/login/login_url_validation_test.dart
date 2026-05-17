import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/data/auth_config.dart';
import 'package:fulfilled/features/login/health_probe.dart';
import 'package:fulfilled/features/login/login_controller.dart';
import 'package:hive/hive.dart';

/// LOG-005 — one test per [HealthProbeErrorKind]. Each case overrides
/// [healthProbeProvider] with a fake that throws the matching
/// [HealthProbeError] and asserts that `LoginController.submit()`
/// surfaces the kind-specific message in `state.urlError`.
///
/// The five kinds (architect §5.4 + ticket Scope checklist):
///
///   - `dns`      → "Couldn't find a server at that address."
///   - `tls`      → "Server's certificate isn't trusted."
///   - `timeout`  → "...timed out after 8 seconds..."
///   - `nonOk`    → "Server responded with ..."
///   - `notFound` → "That address answered, but does not look like a
///                   Fulfilled server."
///
/// The assertions use `contains` against a stable substring rather
/// than the full canonical string so a copy tweak to the error message
/// in `health_probe.dart` won't require five test edits — the
/// substring is the inspection-correct contract.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory hiveDir;
  late Box<String> authConfigBox;

  setUp(() async {
    hiveDir = await Directory.systemTemp.createTemp('fulfilled-login-url-');
    Hive.init(hiveDir.path);
    authConfigBox = await Hive.openBox<String>(authConfigBoxName);
  });

  tearDown(() async {
    await Hive.close();
    if (hiveDir.existsSync()) {
      hiveDir.deleteSync(recursive: true);
    }
  });

  /// Build a container with the auth_config override and a
  /// [healthProbeProvider] that throws [err] on every probe call. The
  /// other providers (`authTokenProvider`, `outboxBoxProvider`,
  /// `secureTokenStoreProvider`) are never instantiated — the
  /// controller bails out in phase 3 before reaching phase 5.
  ProviderContainer containerThrowing(HealthProbeError err) {
    final container = ProviderContainer(
      overrides: <Override>[
        authConfigBoxProvider.overrideWithValue(authConfigBox),
        healthProbeProvider.overrideWith((_) => _ThrowingProbe(err)),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// Drive `submit()` from a seeded form. Returns `(returnValue,
  /// urlErrorAfterSubmit)` for the case to assert on.
  Future<({bool returned, String? urlError})> runProbe(
    HealthProbeError err,
  ) async {
    final container = containerThrowing(err);
    final controller = container.read(loginControllerProvider.notifier);
    // Seed a syntactically-valid URL so phase 2 passes and phase 3
    // (the probe) is what fires.
    controller.setUrl('https://srv.example');
    controller.setUsername('alice');
    controller.setPassword('hunter2');
    final returned = await controller.submit();
    return (
      returned: returned,
      urlError: container.read(loginControllerProvider).urlError,
    );
  }

  test('HealthProbeErrorKind.dns surfaces the "couldn\'t find" message', () async {
    final result = await runProbe(
      const HealthProbeError(
        "Couldn't find a server at that address.",
        HealthProbeErrorKind.dns,
      ),
    );
    expect(result.returned, isFalse);
    expect(result.urlError, isNotNull);
    expect(result.urlError, contains("Couldn't find"));
  });

  test('HealthProbeErrorKind.tls surfaces the "certificate isn\'t trusted" message',
      () async {
    final result = await runProbe(
      const HealthProbeError(
        "Server's certificate isn't trusted.",
        HealthProbeErrorKind.tls,
      ),
    );
    expect(result.returned, isFalse);
    expect(result.urlError, isNotNull);
    expect(result.urlError, contains("certificate isn't trusted"));
  });

  test('HealthProbeErrorKind.timeout surfaces the "timed out" message',
      () async {
    final result = await runProbe(
      const HealthProbeError(
        "Couldn't reach the server (timed out after 8 seconds). "
        'Check the address and your network.',
        HealthProbeErrorKind.timeout,
      ),
    );
    expect(result.returned, isFalse);
    expect(result.urlError, isNotNull);
    expect(result.urlError, contains('timed out'));
  });

  test('HealthProbeErrorKind.nonOk surfaces the "Server responded with" message',
      () async {
    final result = await runProbe(
      const HealthProbeError(
        'Server responded with 503.',
        HealthProbeErrorKind.nonOk,
      ),
    );
    expect(result.returned, isFalse);
    expect(result.urlError, isNotNull);
    expect(result.urlError, contains('Server responded with'));
  });

  test(
      'HealthProbeErrorKind.notFound surfaces the "does not look like a '
      'Fulfilled server" message', () async {
    final result = await runProbe(
      const HealthProbeError(
        'That address answered, but does not look like a Fulfilled server.',
        HealthProbeErrorKind.notFound,
      ),
    );
    expect(result.returned, isFalse);
    expect(result.urlError, isNotNull);
    expect(
      result.urlError,
      contains('does not look like a Fulfilled server'),
    );
  });
}

/// Tiny fake — throws the supplied [HealthProbeError] from every
/// `probe()` call. The five test cases each construct one with a
/// different `HealthProbeErrorKind`.
class _ThrowingProbe implements HealthProbe {
  const _ThrowingProbe(this._err);
  final HealthProbeError _err;

  @override
  Future<void> probe(String baseUrl, {required Duration timeout}) async {
    throw _err;
  }
}
