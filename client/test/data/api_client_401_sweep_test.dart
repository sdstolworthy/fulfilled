import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/data/api_client.dart';
import 'package:fulfilled/data/auth_token.dart';
import 'package:fulfilled/data/outbox/log_outbox_notifier.dart';
import 'package:fulfilled/data/secure_token_store.dart';
import 'package:fulfilled/providers/api_base_url_provider.dart';
import 'package:hive/hive.dart';

import 'fake_dio_adapter.dart';
import 'fake_secure_token_store.dart';

/// Tests for the 401-sweep interceptor branch in `apiClientProvider`
/// (LOG-004 §3.4). The interceptor listens for 401 responses on the
/// Dio error pipeline and signs the user out via
/// `authTokenProvider.notifier.signOut()` — EXCEPT when the offending
/// request is `/auth/login`, where the 401 is informational ("bad
/// credentials") and signing out would create a loop.
///
/// We swap the real HTTP adapter for [FakeDioAdapter] so the
/// interceptor pipeline runs end-to-end on a controlled 401, then
/// assert on `authTokenProvider`'s state after the request settles.
/// The `signOut()` call is fire-and-forget inside the interceptor —
/// we pump the microtask queue once so its `await
/// secureTokenStoreProvider.clear()` + `outbox.clear()` complete
/// before the assertions.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory hiveDir;
  late Box<String> outboxBox;
  late FakeSecureTokenStore fakeSecureStore;

  setUp(() async {
    hiveDir = await Directory.systemTemp.createTemp('fulfilled-401-sweep-');
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

  ProviderContainer containerWithAdapter(FakeDioAdapter adapter) {
    final container = ProviderContainer(
      overrides: <Override>[
        outboxBoxProvider.overrideWithValue(outboxBox),
        secureTokenStoreProvider.overrideWithValue(fakeSecureStore),
        apiBaseUrlProvider.overrideWith((_) => 'https://test.example/api/v1'),
      ],
    );
    addTearDown(container.dispose);
    container.read(apiClientProvider).dio.httpClientAdapter = adapter;
    return container;
  }

  test(
    '401 on a non-/auth/login endpoint signs the user out via the '
    'interceptor, but the DioException still bubbles to the caller',
    () async {
      final adapter = FakeDioAdapter((_) => emptyResponse(401));
      final container = containerWithAdapter(adapter);

      // Seed the in-memory bearer + the secure store so we can
      // assert the sweep cleared both.
      await container
          .read(authTokenProvider.notifier)
          .signIn('seeded-bearer');
      expect(container.read(authTokenProvider), equals('seeded-bearer'));
      expect(await fakeSecureStore.read(), equals('seeded-bearer'));

      // Fire an authenticated request — `/log` is the canonical
      // non-login endpoint. The 401 must:
      //   (a) bubble back to the caller as a DioException, AND
      //   (b) trigger the sweep so authTokenProvider flips to null.
      await expectLater(
        () => container.read(apiClientProvider).dio.get<dynamic>('/log'),
        throwsA(isA<DioException>()),
      );

      // The interceptor's signOut() is fire-and-forget; pump the
      // event loop a few times so the awaited secure-store clear +
      // outbox clear inside it have a chance to land. `state = null`
      // is synchronous so it's already flipped by the time
      // `handler.next(e)` runs; the pumps cover the awaited side
      // effects on the fake stores.
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(container.read(authTokenProvider), isNull);
      expect(await fakeSecureStore.read(), isNull);
    },
  );

  test(
    '401 on /auth/login does NOT trigger the sweep (no loop)',
    () async {
      final adapter = FakeDioAdapter((_) => emptyResponse(401));
      final container = containerWithAdapter(adapter);

      await container
          .read(authTokenProvider.notifier)
          .signIn('seeded-bearer');
      expect(container.read(authTokenProvider), equals('seeded-bearer'));

      // Hit /auth/login directly so the path-exclusion branch fires.
      await expectLater(
        () => container.read(apiClientProvider).dio.post<dynamic>(
              '/auth/login',
              data: <String, String>{'username': 'u', 'password': 'p'},
            ),
        throwsA(isA<DioException>()),
      );

      // Pump the microtask queue — if the sweep DID fire, the
      // signOut's awaits would have run by now.
      await Future<void>.delayed(Duration.zero);

      // State unchanged — the in-memory bearer + secure store
      // survive the informational 401.
      expect(container.read(authTokenProvider), equals('seeded-bearer'));
      expect(await fakeSecureStore.read(), equals('seeded-bearer'));
    },
  );

  test(
    '5xx on a non-login endpoint does NOT trigger the sweep '
    '(the branch is 401-specific)',
    () async {
      final adapter = FakeDioAdapter((_) => emptyResponse(500));
      final container = containerWithAdapter(adapter);

      await container
          .read(authTokenProvider.notifier)
          .signIn('seeded-bearer');

      await expectLater(
        () => container.read(apiClientProvider).dio.get<dynamic>('/log'),
        throwsA(isA<DioException>()),
      );
      await Future<void>.delayed(Duration.zero);

      // Non-401 errors are caller-handled (T-11 SnackBar etc.); no
      // sign-out side effect.
      expect(container.read(authTokenProvider), equals('seeded-bearer'));
      expect(await fakeSecureStore.read(), equals('seeded-bearer'));
    },
  );
}
