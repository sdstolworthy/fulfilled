import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/data/auth_config.dart';
import 'package:fulfilled/providers/api_base_url_provider.dart';
import 'package:hive/hive.dart';

/// Tests for `apiBaseUrlProvider` (LOG-001).
///
/// The provider resolves the API base URL via three rules, in order:
///   1. Debug `--dart-define=API_BASE_URL=...` override.
///   2. Web → `Uri.base.origin + '/api/v1'`.
///   3. Mobile → `auth_config` Hive box. LOG-003 wired the real box
///      provider in `data/auth_config.dart`; the stub throw and the
///      `about:invalid://no-base` placeholder are gone. The mobile
///      branch now reads from `authConfigBoxProvider` directly — tests
///      must supply an override.
///
/// The first rule is gated on `kDebugMode && _baseUrlFromEnv.isNotEmpty`
/// — `String.fromEnvironment` is compile-time, so tests cannot vary
/// the env value at runtime. We assert the **branch shape** instead:
/// when `kDebugModeProvider` is overridden to `false`, the override
/// branch is skipped and the next rule wins. The live debug path is
/// covered by the dev loop itself (`flutter run --dart-define=...`).

/// Minimal fake `Box<String>` for the mobile-rule test. Implements just
/// enough of `Box` for `apiBaseUrlProvider` to call `box.get(key)`.
class _FakeBox implements Box<String> {
  _FakeBox(this._values);
  final Map<String, String?> _values;

  @override
  String? get(dynamic key, {String? defaultValue}) {
    if (_values.containsKey(key)) return _values[key];
    return defaultValue;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('apiBaseUrlProvider — Rule 1: debug --dart-define override', () {
    test(
      'when the dart-define is empty (the default in `flutter test`), the '
      'debug-override branch is skipped and the next rule wins',
      () {
        // The branch shape: gated on `kDebugMode && _baseUrlFromEnv.isNotEmpty`.
        // In `flutter test` `_baseUrlFromEnv` is the empty string (no
        // `--dart-define` is set), so the branch is skipped even though
        // `kDebugMode` is true under the test runner. We assert by
        // forcing the web rule (rule 2) — if rule 1 had fired, the
        // override origin would not appear.
        final container = ProviderContainer(
          overrides: <Override>[
            kIsWebProvider.overrideWithValue(true),
            uriBaseProvider.overrideWithValue(
              Uri.parse('https://app.example.com/'),
            ),
          ],
        );
        addTearDown(container.dispose);

        expect(
          container.read(apiBaseUrlProvider),
          equals('https://app.example.com/api/v1'),
        );
      },
    );

    test(
      'when `kDebugModeProvider` is overridden to false the debug branch '
      'never runs (and the web rule wins instead)',
      () {
        // Belt-and-suspenders: prove the branch is gated on kDebugMode by
        // forcing it false; rule 2 should still resolve cleanly.
        final container = ProviderContainer(
          overrides: <Override>[
            kDebugModeProvider.overrideWithValue(false),
            kIsWebProvider.overrideWithValue(true),
            uriBaseProvider.overrideWithValue(
              Uri.parse('https://rel.example.com/'),
            ),
          ],
        );
        addTearDown(container.dispose);

        expect(
          container.read(apiBaseUrlProvider),
          equals('https://rel.example.com/api/v1'),
        );
      },
    );
  });

  group('apiBaseUrlProvider — Rule 2: web Uri.base.origin', () {
    test(
      'returns `Uri.base.origin + "/api/v1"` when kIsWeb is true',
      () {
        final container = ProviderContainer(
          overrides: <Override>[
            kIsWebProvider.overrideWithValue(true),
            uriBaseProvider.overrideWithValue(
              Uri.parse('https://customer.fulfilled.app/some/path'),
            ),
          ],
        );
        addTearDown(container.dispose);

        // Uri.origin strips path/query/fragment — the path component is
        // dropped. v1 reverse-proxy subpath limitation (architect §10.2).
        expect(
          container.read(apiBaseUrlProvider),
          equals('https://customer.fulfilled.app/api/v1'),
        );
      },
    );
  });

  group('apiBaseUrlProvider — Rule 3: mobile auth_config Hive box', () {
    test(
      'with an `authConfigBoxProvider` override returning a base_url: '
      'returns that value (LOG-003 wired)',
      () {
        // Persisted base URL is returned verbatim from the Hive box.
        final container = ProviderContainer(
          overrides: <Override>[
            kIsWebProvider.overrideWithValue(false),
            authConfigBoxProvider.overrideWithValue(
              _FakeBox(<String, String?>{
                AuthConfigKey.baseUrl: 'https://hive.example/api/v1',
              }),
            ),
          ],
        );
        addTearDown(container.dispose);

        expect(
          container.read(apiBaseUrlProvider),
          equals('https://hive.example/api/v1'),
        );
      },
    );

    test(
      'with an empty Hive box on a fresh install: returns null',
      () {
        final container = ProviderContainer(
          overrides: <Override>[
            kIsWebProvider.overrideWithValue(false),
            authConfigBoxProvider.overrideWithValue(
              _FakeBox(<String, String?>{}),
            ),
          ],
        );
        addTearDown(container.dispose);

        expect(container.read(apiBaseUrlProvider), isNull);
      },
    );
  });
}
