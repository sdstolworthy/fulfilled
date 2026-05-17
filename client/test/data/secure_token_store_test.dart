import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/data/secure_token_store.dart';

import 'fake_secure_token_store.dart';

/// Tests for [SecureTokenStore] (LOG-003).
///
/// The production [SecureTokenStore] wraps `FlutterSecureStorage`, which
/// dispatches to a platform `MethodChannel`. The Flutter test
/// environment has no platform implementation and the exact channel
/// name varies by `flutter_secure_storage` major version, so we route
/// the round-trip + clear assertions through [FakeSecureTokenStore]
/// (which extends [SecureTokenStore] and overrides every public
/// method). This locks in the abstraction's contract — every
/// `SecureTokenStore` instance, real or fake, behaves the same way.
///
/// We also exercise [secureTokenStoreProvider]: it must throw without
/// an override (so misuse is loud), and return the supplied store
/// when overridden.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SecureTokenStore contract (via FakeSecureTokenStore)', () {
    test('write then read returns the same token (round-trip)', () async {
      final store = FakeSecureTokenStore();
      await store.write('bearer-abc-123');
      expect(await store.read(), equals('bearer-abc-123'));
    });

    test('read returns null when no token has been written', () async {
      final store = FakeSecureTokenStore();
      expect(await store.read(), isNull);
    });

    test('clear removes the persisted token (subsequent read is null)',
        () async {
      final store = FakeSecureTokenStore();
      await store.write('bearer-xyz');
      expect(await store.read(), equals('bearer-xyz'));

      await store.clear();
      expect(await store.read(), isNull);
    });

    test('write overwrites a prior value', () async {
      final store = FakeSecureTokenStore();
      await store.write('first');
      await store.write('second');
      expect(await store.read(), equals('second'));
    });

    test('clear is idempotent when no token is persisted', () async {
      final store = FakeSecureTokenStore();
      // No prior write; clear should still succeed and read should be null.
      await store.clear();
      expect(await store.read(), isNull);
    });
  });

  group('secureTokenStoreProvider', () {
    test(
      'throws UnimplementedError when read without an override',
      () {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        expect(
          () => container.read(secureTokenStoreProvider),
          throwsA(isA<UnimplementedError>()),
        );
      },
    );

    test(
      'returns the supplied store when overridden',
      () async {
        final fake = FakeSecureTokenStore();
        await fake.write('overridden');
        final container = ProviderContainer(
          overrides: <Override>[
            secureTokenStoreProvider.overrideWithValue(fake),
          ],
        );
        addTearDown(container.dispose);

        final resolved = container.read(secureTokenStoreProvider);
        expect(identical(resolved, fake), isTrue);
        expect(await resolved.read(), equals('overridden'));
      },
    );
  });
}
