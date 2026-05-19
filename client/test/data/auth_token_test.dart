import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/data/api_client.dart';
import 'package:fulfilled/data/auth_token.dart';
import 'package:fulfilled/data/login_errors.dart';
import 'package:fulfilled/data/outbox/log_outbox_notifier.dart';
import 'package:fulfilled/data/secure_token_store.dart';
import 'package:fulfilled/providers/api_base_url_provider.dart';
import 'package:hive/hive.dart';

import 'fake_dio_adapter.dart';
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

  ProviderContainer container0() {
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
    final container = container0();
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
    final container = container0();
    await container
        .read(authTokenProvider.notifier)
        .signIn('user-token-abc');
    expect(container.read(authTokenProvider), equals('user-token-abc'));
    expect(await fakeSecureStore.read(), equals('user-token-abc'));
  });

  test('signOut() clears state to null and clears the store', () async {
    final container = container0();
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

    final container = container0();
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

      final container = container0();
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

  /// `signInWithCredentials` tests (LOG-004). These build a real
  /// `apiClientProvider` against an in-memory base URL and a
  /// [FakeDioAdapter] so the full interceptor pipeline + the SUT's
  /// `dio.post('/auth/login', ...)` call run end-to-end. The adapter
  /// captures the outgoing [RequestOptions] for path/body assertions
  /// and returns canned status + body (or throws a `DioException` to
  /// simulate transport failures).
  group('signInWithCredentials', () {
    ProviderContainer containerWithAdapter(FakeDioAdapter adapter) {
      final container = ProviderContainer(
        overrides: <Override>[
          outboxBoxProvider.overrideWithValue(outboxBox),
          secureTokenStoreProvider.overrideWithValue(fakeSecureStore),
          apiBaseUrlProvider.overrideWith((_) => 'https://test.example/api/v1'),
        ],
      );
      addTearDown(container.dispose);
      // Swap Dio's transport adapter for the fake. The interceptor
      // chain (auth header on request, 401-sweep on error) runs
      // unchanged.
      container.read(apiClientProvider).dio.httpClientAdapter = adapter;
      return container;
    }

    test(
      '200 + {token: "..."} → posts to /auth/login with username+password '
      'and stores the returned token',
      () async {
        final adapter = FakeDioAdapter(
          (_) => jsonResponse(200, <String, dynamic>{'token': 'srv-token-1'}),
        );
        final container = containerWithAdapter(adapter);

        await container.read(authTokenProvider.notifier).signInWithCredentials(
              username: 'alice',
              password: 'hunter2',
            );

        // Path + method.
        expect(adapter.requests, hasLength(1));
        final req = adapter.requests.single;
        expect(req.method, equalsIgnoringCase('POST'));
        expect(req.path, equals('/auth/login'));
        // Body — Dio serialises maps to JSON by default.
        expect(req.data, isA<Map<String, String>>());
        expect((req.data as Map)['username'], equals('alice'));
        expect((req.data as Map)['password'], equals('hunter2'));
        // The token is now in both the notifier and the secure store.
        expect(container.read(authTokenProvider), equals('srv-token-1'));
        expect(await fakeSecureStore.read(), equals('srv-token-1'));
      },
    );

    test('401 from /auth/login → BadCredentialsError; state untouched',
        () async {
      final adapter = FakeDioAdapter((_) => emptyResponse(401));
      final container = containerWithAdapter(adapter);
      // Snapshot pre-call state — the dev-bypass seed is non-null
      // under flutter_test, so we assert "unchanged" rather than
      // "null".
      final before = container.read(authTokenProvider);
      final beforeStore = await fakeSecureStore.read();

      await expectLater(
        () => container.read(authTokenProvider.notifier).signInWithCredentials(
              username: 'alice',
              password: 'wrong',
            ),
        throwsA(isA<BadCredentialsError>()),
      );
      expect(container.read(authTokenProvider), equals(before));
      expect(await fakeSecureStore.read(), equals(beforeStore));
    });

    test('404 from /auth/login → LoginEndpointMissingError', () async {
      final adapter = FakeDioAdapter((_) => emptyResponse(404));
      final container = containerWithAdapter(adapter);

      await expectLater(
        () => container.read(authTokenProvider.notifier).signInWithCredentials(
              username: 'alice',
              password: 'pw-no-server',
            ),
        throwsA(isA<LoginEndpointMissingError>()),
      );
    });

    test(
      'connection error from the adapter → LoginNetworkError',
      () async {
        final adapter = FakeDioAdapter(
          (req) => throw DioException(
            requestOptions: req,
            type: DioExceptionType.connectionError,
            message: 'connection refused',
          ),
        );
        final container = containerWithAdapter(adapter);

        await expectLater(
          () => container.read(authTokenProvider.notifier).signInWithCredentials(
                username: 'alice',
                password: 'pw',
              ),
          throwsA(isA<LoginNetworkError>()),
        );
      },
    );

    test('500 from /auth/login → LoginNetworkError (not BadCredentials)',
        () async {
      final adapter = FakeDioAdapter((_) => emptyResponse(500));
      final container = containerWithAdapter(adapter);

      await expectLater(
        () => container.read(authTokenProvider.notifier).signInWithCredentials(
              username: 'alice',
              password: 'pw',
            ),
        throwsA(isA<LoginNetworkError>()),
      );
    });

    test(
      'JWT-shaped password skips the POST and signs in with that value',
      () async {
        // No request should hit the adapter — if any does, the
        // handler throws so the test fails loudly.
        final adapter = FakeDioAdapter(
          (req) => throw DioException(
            requestOptions: req,
            error: StateError(
              'JWT-shape path should not have hit the network: ${req.path}',
            ),
          ),
        );
        final container = containerWithAdapter(adapter);

        // Realistic but minimal three-segment JWT shape: header.payload.sig
        // with base64url-safe chars. The regex requires `+` per segment.
        const jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1In0.abc-_DEF';

        await container.read(authTokenProvider.notifier).signInWithCredentials(
              username: 'ignored',
              password: jwt,
            );

        expect(adapter.requests, isEmpty);
        expect(container.read(authTokenProvider), equals(jwt));
        expect(await fakeSecureStore.read(), equals(jwt));
      },
    );

    test(
      'non-JWT-shaped passwords (two dots only, empty segment, '
      'illegal chars) DO hit the POST',
      () async {
        // Verifies the regex anchors / segment-non-empty / charset
        // edge cases. Each call should produce a real network hit
        // (we return 401 to abort cheaply).
        final adapter = FakeDioAdapter((_) => emptyResponse(401));
        final container = containerWithAdapter(adapter);

        for (final pw in <String>[
          'no-dots-here',
          'only.one.', // trailing empty segment
          '.empty.first', // leading empty segment
          'a..c', // empty middle segment
          'has spaces.in.it', // space is not base64url
          'a.b.c.d', // four segments
        ]) {
          await expectLater(
            () => container
                .read(authTokenProvider.notifier)
                .signInWithCredentials(username: 'u', password: pw),
            throwsA(isA<BadCredentialsError>()),
          );
        }
        // One network hit per non-JWT-shaped password.
        expect(adapter.requests, hasLength(6));
      },
    );
  });
}
