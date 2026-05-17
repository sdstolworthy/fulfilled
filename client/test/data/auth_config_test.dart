import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/data/auth_config.dart';
import 'package:hive/hive.dart';

/// Tests for `auth_config.dart` (LOG-003).
///
/// Covers:
///   - The key literals (`base_url`, `last_username`) are stable. A
///     rename guard — already-shipped user data would be silently
///     orphaned by a rename.
///   - Round-trip `put` / `get` of both keys through a real
///     temp-directory Hive box.
///   - `authConfigBoxProvider` returns the opened box when overridden,
///     and throws an [UnimplementedError] when read without an override.
///   - Survival across a Hive close-and-reopen — the box is on-disk so
///     `Hive.close()` then `openBox` must surface the same values. This
///     is the manual-smoke property the architect §4.3 acceptance
///     criterion names.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory hiveDir;

  setUp(() async {
    hiveDir = await Directory.systemTemp.createTemp('fulfilled-auth-config-');
    Hive.init(hiveDir.path);
  });

  tearDown(() async {
    await Hive.close();
    if (hiveDir.existsSync()) {
      hiveDir.deleteSync(recursive: true);
    }
  });

  group('AuthConfigKey literals', () {
    test('baseUrl is the string "base_url"', () {
      expect(AuthConfigKey.baseUrl, equals('base_url'));
    });

    test('lastUsername is the string "last_username"', () {
      expect(AuthConfigKey.lastUsername, equals('last_username'));
    });

    test('authConfigBoxName is the string "auth_config"', () {
      expect(authConfigBoxName, equals('auth_config'));
    });
  });

  group('round-trip through the Hive box', () {
    test('baseUrl write then read returns the same value', () async {
      final box = await Hive.openBox<String>(authConfigBoxName);
      await box.put(AuthConfigKey.baseUrl, 'https://api.example/api/v1');
      expect(
        box.get(AuthConfigKey.baseUrl),
        equals('https://api.example/api/v1'),
      );
    });

    test('lastUsername write then read returns the same value', () async {
      final box = await Hive.openBox<String>(authConfigBoxName);
      await box.put(AuthConfigKey.lastUsername, 'alice@example.com');
      expect(
        box.get(AuthConfigKey.lastUsername),
        equals('alice@example.com'),
      );
    });

    test(
      'values survive a Hive close + re-open cycle (on-disk persistence)',
      () async {
        var box = await Hive.openBox<String>(authConfigBoxName);
        await box.put(AuthConfigKey.baseUrl, 'https://persisted.example/api/v1');
        await box.put(AuthConfigKey.lastUsername, 'bob');
        await Hive.close();

        // Re-initialise against the same temp directory — Hive should
        // pick up the on-disk box file and return the persisted values.
        Hive.init(hiveDir.path);
        box = await Hive.openBox<String>(authConfigBoxName);

        expect(
          box.get(AuthConfigKey.baseUrl),
          equals('https://persisted.example/api/v1'),
        );
        expect(
          box.get(AuthConfigKey.lastUsername),
          equals('bob'),
        );
      },
    );
  });

  group('authConfigBoxProvider', () {
    test(
      'throws UnimplementedError when read without an override',
      () {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        expect(
          () => container.read(authConfigBoxProvider),
          throwsA(isA<UnimplementedError>()),
        );
      },
    );

    test(
      'returns the overridden box and round-trips the baseUrl key '
      'through the provider surface',
      () async {
        final box = await Hive.openBox<String>(authConfigBoxName);
        final container = ProviderContainer(
          overrides: <Override>[
            authConfigBoxProvider.overrideWithValue(box),
          ],
        );
        addTearDown(container.dispose);

        final resolved = container.read(authConfigBoxProvider);
        expect(identical(resolved, box), isTrue);

        await resolved.put(AuthConfigKey.baseUrl, 'https://from-provider/api/v1');
        expect(
          container.read(authConfigBoxProvider).get(AuthConfigKey.baseUrl),
          equals('https://from-provider/api/v1'),
        );
      },
    );
  });
}
