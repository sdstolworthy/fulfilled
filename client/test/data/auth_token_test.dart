import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/data/auth_token.dart';
import 'package:fulfilled/data/outbox/log_outbox_notifier.dart';
import 'package:fulfilled/data/secure_token_store.dart';
import 'package:hive/hive.dart';

import 'fake_secure_token_store.dart';

/// Unit tests for `AuthTokenNotifier` — the T-019 surface, extended in
/// LOG-003 with [SecureTokenStore] persistence.
///
/// We override `outboxBoxProvider` with a real Hive box opened against a
/// per-test temp directory so `signOut()`'s `await outbox.clear()` runs
/// against the same `Box<String>` contract the app sees in production
/// (architect ruling: prefer the real Box to a stub when the real thing
/// is cheap to construct). `secureTokenStoreProvider` is overridden with
/// an in-memory [FakeSecureTokenStore] so the persistence wiring is
/// exercised end-to-end without touching the real platform keystore.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory hiveDir;
  late Box<String> outboxBox;
  late FakeSecureTokenStore fakeSecureStore;

  setUp(() async {
    hiveDir = await Directory.systemTemp.createTemp('fulfilled-auth-token-');
    Hive.init(hiveDir.path);
    outboxBox = await Hive.openBox<String>(outboxBoxName);
    fakeSecureStore = FakeSecureTokenStore();
  });

  tearDown(() async {
    await Hive.close();
    if (hiveDir.existsSync()) {
      hiveDir.deleteSync(recursive: true);
    }
  });

  ProviderContainer _container() {
    final container = ProviderContainer(
      overrides: <Override>[
        outboxBoxProvider.overrideWithValue(outboxBox),
        secureTokenStoreProvider.overrideWithValue(fakeSecureStore),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('build() seeds the dev-bypass token in debug builds', () {
    final container = _container();
    // Test runner is always non-release — seed should fall through to the
    // dev-bypass constant. If the test ever runs under `--dart-define=
    // DEV_AUTH_TOKEN=...` the seed picks that up instead; we assert
    // non-null + non-empty rather than a literal so the test stays
    // robust against the compile-time override.
    final token = container.read(authTokenProvider);
    expect(token, isNotNull);
    expect(token, isNotEmpty);
  });

  test('signIn(token) sets state to that token and persists to the store',
      () async {
    final container = _container();
    await container
        .read(authTokenProvider.notifier)
        .signIn('user-token-abc');
    expect(container.read(authTokenProvider), equals('user-token-abc'));
    expect(await fakeSecureStore.read(), equals('user-token-abc'));
  });

  test('signOut() clears state to null and clears the store', () async {
    final container = _container();
    await container.read(authTokenProvider.notifier).signIn('user-token-abc');
    expect(container.read(authTokenProvider), equals('user-token-abc'));
    expect(await fakeSecureStore.read(), equals('user-token-abc'));

    await container.read(authTokenProvider.notifier).signOut();

    expect(container.read(authTokenProvider), isNull);
    expect(await fakeSecureStore.read(), isNull);
  });

  test('signOut() clears the outbox Hive box', () async {
    await outboxBox.put('entry-1', '{"foo":1}');
    await outboxBox.put('entry-2', '{"foo":2}');
    expect(outboxBox.length, equals(2));

    final container = _container();
    await container.read(authTokenProvider.notifier).signOut();

    expect(outboxBox.length, equals(0));
  });

  test(
    'build() hydrates state from the secure store on first read',
    () async {
      // Seed the fake store before constructing the container — the
      // notifier's async hydrate path should replace the dev-bypass seed
      // with the persisted bearer.
      await fakeSecureStore.write('persisted-token-xyz');

      final container = _container();
      // First read triggers `build()` which schedules the async hydrate.
      container.read(authTokenProvider);
      // Pump the microtask queue so the hydrate future resolves.
      await Future<void>.delayed(Duration.zero);

      expect(
        container.read(authTokenProvider),
        equals('persisted-token-xyz'),
      );
    },
  );
}
