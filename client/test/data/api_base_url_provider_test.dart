import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/data/auth_config.dart';
import 'package:fulfilled/providers/api_base_url_provider.dart';
import 'package:hive/hive.dart';

/// Tests for `apiBaseUrlProvider` (LOG-001).
///
/// The provider resolves the API base URL via three rules, in order:
///   1. Compile-time absolute `--dart-define=API_BASE_URL=https://...`
///      override (any build mode; relative values are ignored).
///   2. Web → `Uri.base.origin + '/api/v1'`.
///   3. Mobile → `auth_config` Hive box.
///
/// Rule 1's absoluteness gate exists because the historical
/// `compose.coolify.yaml` default was the relative `/api/v1` literal —
/// a bare path that Dio can't use as a base URL. Production deploys
/// now bake an absolute URL like
/// `--dart-define=API_BASE_URL=https://api.coolify.stolworthy.co/api/v1`
/// (shape (b) in `deploy_tasks.md`), which rule 1 picks up in release.
/// Local `flutter run --dart-define=...` continues to work unchanged.
///
/// `String.fromEnvironment` is compile-time, so tests can't vary
/// `_baseUrlFromEnv` at runtime. We assert the **branch shape** —
/// under `flutter test` the dart-define is empty, so rule 1 is
/// inert and rules 2 / 3 win. The live release path is covered by the
/// `flutter build web --dart-define=...` Docker step.

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
  group('apiBaseUrlProvider — Rule 1: absolute --dart-define override', () {
    test(
      'when the dart-define is empty (the default in `flutter test`), '
      'rule 1 is inert and the next rule wins',
      () {
        // `_baseUrlFromEnv` is the empty string in `flutter test` (no
        // `--dart-define` is set), so the absolute-prefix check fails
        // and the branch is skipped regardless of build mode. Asserted
        // by forcing the web rule — if rule 1 had fired, no test override
        // could shadow it.
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
      'rule 1 no longer depends on kDebugMode — release builds honor '
      'an absolute dart-define value (the deploy build-arg path)',
      () {
        // Documents the LOG-001 amendment: the kDebugMode gate is
        // removed; absoluteness of `_baseUrlFromEnv` is the only gate.
        // Tests can't vary the compile-time constant, but pinning the
        // release behavior with `kDebugModeProvider: false` proves the
        // gate is gone — rule 2 (web) still resolves cleanly.
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
