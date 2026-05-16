import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/data/auth_token.dart';
import 'package:fulfilled/data/outbox/log_outbox_notifier.dart';
import 'package:hive/hive.dart';

/// Unit tests for `AuthTokenNotifier` — the new T-019 surface.
///
/// We override `outboxBoxProvider` with a real Hive box opened against a
/// per-test temp directory so `signOut()`'s `await outbox.clear()` runs
/// against the same `Box<String>` contract the app sees in production
/// (architect ruling: prefer the real Box to a stub when the real thing
/// is cheap to construct).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory hiveDir;
  late Box<String> outboxBox;

  setUp(() async {
    hiveDir = await Directory.systemTemp.createTemp('fulfilled-auth-token-');
    Hive.init(hiveDir.path);
    outboxBox = await Hive.openBox<String>(outboxBoxName);
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

  test('signIn(token) sets state to that token', () {
    final container = _container();
    container
        .read(authTokenProvider.notifier)
        .signIn('user-token-abc');
    expect(container.read(authTokenProvider), equals('user-token-abc'));
  });

  test('signOut() clears state to null', () async {
    final container = _container();
    container.read(authTokenProvider.notifier).signIn('user-token-abc');
    expect(container.read(authTokenProvider), equals('user-token-abc'));

    await container.read(authTokenProvider.notifier).signOut();

    expect(container.read(authTokenProvider), isNull);
  });

  test('signOut() clears the outbox Hive box', () async {
    await outboxBox.put('entry-1', '{"foo":1}');
    await outboxBox.put('entry-2', '{"foo":2}');
    expect(outboxBox.length, equals(2));

    final container = _container();
    await container.read(authTokenProvider.notifier).signOut();

    expect(outboxBox.length, equals(0));
  });
}
