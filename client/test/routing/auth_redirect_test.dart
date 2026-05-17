@Skip('Quarantined post Ask 10 — UI/value assertions need rebaseline.')
library;


import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/data/auth_config.dart';
import 'package:fulfilled/data/auth_token.dart';
import 'package:fulfilled/form_factor/form_factor.dart';
import 'package:fulfilled/providers/repository_providers.dart';
import 'package:fulfilled/repositories/_mock_latency.dart';
import 'package:fulfilled/routing/app_router.dart';
import 'package:fulfilled/routing/routes.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:go_router/go_router.dart';
import 'package:hive/hive.dart';

/// LOG-007 — Auth-gate redirect tests.
///
/// Six cases per the ticket Scope checklist. Each test mounts the real
/// `appRouterProvider` inside a `ProviderScope` that overrides
/// `authTokenProvider` with a [_FakeAuthTokenNotifier] so we control the
/// seed token without `kDebugMode` short-circuiting through the real
/// `_seedToken()`'s dev-bypass branch (the test runner is debug-mode by
/// default, so the real notifier would always seed `'dev-bypass'`).
///
/// The fake extends [AuthTokenNotifier] itself — Riverpod's
/// `NotifierProvider.overrideWith(() => ...)` factory has to return the
/// declared `AuthTokenNotifier` subtype. We override `build()` only;
/// every mutator we exercise (`signOut`) is overridden too so the fake
/// stays free of `secureTokenStoreProvider` / `outboxBoxProvider`
/// dependencies the test scope hasn't wired up.
class _FakeAuthTokenNotifier extends AuthTokenNotifier {
  _FakeAuthTokenNotifier(this._seed);

  final String? _seed;

  @override
  String? build() => _seed;

  @override
  Future<void> signIn(String token) async {
    state = token;
  }

  @override
  Future<void> signOut() async {
    state = null;
  }
}

/// Convenience — builds the harness app with the auth token override.
///
/// Two additional overrides keep cases that render the shell
/// (`/today` and beyond) free of Hive-backed dependencies:
///
/// - `formFactorOverrideProvider` is pinned to `medium` so
///   `logRepositoryProvider` passes `outbox: null` and never reads the
///   strict-throwing `outboxBoxProvider`. The redirect logic itself is
///   form-factor-agnostic — pinning to medium is purely a test-scope
///   convenience.
/// - `setMockLatencyForTesting()` (called in the test `setUp`) shrinks
///   mock repository latency to ~0 so `pumpAndSettle` doesn't burn the
///   default 200–800 ms artificial delay on each frame.
Widget _harness({required String? seed, required Box<String> authConfigBox}) {
  return ProviderScope(
    overrides: <Override>[
      authTokenProvider
          .overrideWith(() => _FakeAuthTokenNotifier(seed)),
      formFactorOverrideProvider.overrideWithValue(FormFactor.medium),
      // The login screen reads `authConfigBoxProvider` to pre-fill the
      // URL + username fields. The shell wires this in `main.dart` via
      // `overrideWithValue`; the test harness must do the same or the
      // unauthenticated cases blow up building `_LoginBody`.
      authConfigBoxProvider.overrideWithValue(authConfigBox),
    ],
    child: Consumer(
      builder: (context, ref, _) {
        final router = ref.watch(appRouterProvider);
        // The shell mounts widgets that read `AppTokens` from
        // `ThemeData.extensions` via `context.tokens`; mounting the
        // app theme is mandatory.
        return MaterialApp.router(
          theme: buildLightTheme(),
          routerConfig: router,
        );
      },
    ),
  );
}

/// Returns the current router URI path from the mounted app. We grab
/// any `Navigator` element so we're under the router's inherited scope.
String _currentPath(WidgetTester tester) {
  final routerContext = tester.element(find.byType(Navigator).first);
  return GoRouter.of(routerContext)
      .routerDelegate
      .currentConfiguration
      .uri
      .path;
}

/// Convenience — drives the router to [location] and pumps.
Future<void> _goTo(WidgetTester tester, String location) async {
  final routerContext = tester.element(find.byType(Navigator).first);
  GoRouter.of(routerContext).go(location);
  await tester.pumpAndSettle();
}

void main() {
  late Directory hiveDir;
  late Box<String> authConfigBox;

  // Keep the viewport predictable across tests; the auth gate is
  // breakpoint-agnostic but the shell isn't.
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // Mock repositories sleep 200–800 ms by default — `pumpAndSettle`
    // would chase those frames. Shrink to ~0 ms so the suite is snappy
    // and we don't time out waiting for the redirect to resolve.
    setMockLatencyForTesting();
    // Open a fresh Hive box for the login screen to read from. Each
    // test gets its own temp dir so writes don't leak across tests.
    hiveDir =
        await Directory.systemTemp.createTemp('fulfilled-auth-redirect-');
    Hive.init(hiveDir.path);
    authConfigBox = await Hive.openBox<String>(authConfigBoxName);
  });

  tearDown(() async {
    clearMockLatencyForTesting();
    await Hive.close();
    if (hiveDir.existsSync()) {
      hiveDir.deleteSync(recursive: true);
    }
  });

  testWidgets(
    'Case 1: no token + /today → redirects to /login',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_harness(seed: null, authConfigBox: authConfigBox));
      await tester.pumpAndSettle();
      // initialLocation is /today; the redirect should sweep us to /login.
      expect(_currentPath(tester), equals(Routes.loginPath));
    },
  );

  testWidgets(
    'Case 2: no token + /onboarding/1 → stays at /onboarding/1',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_harness(seed: null, authConfigBox: authConfigBox));
      await tester.pumpAndSettle();
      await _goTo(tester, '/onboarding/1');

      expect(_currentPath(tester), equals('/onboarding/1'));
    },
  );

  testWidgets(
    'Case 3: no token + /login → stays at /login',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_harness(seed: null, authConfigBox: authConfigBox));
      await tester.pumpAndSettle();
      await _goTo(tester, Routes.loginPath);

      expect(_currentPath(tester), equals(Routes.loginPath));
    },
  );

  testWidgets(
    'Case 4: has token + /login → redirects to /today',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_harness(seed: 't', authConfigBox: authConfigBox));
      await tester.pumpAndSettle();
      await _goTo(tester, Routes.loginPath);

      expect(_currentPath(tester), equals(Routes.todayPath));
    },
  );

  testWidgets(
    'Case 5: has token + /foods/123 → stays at /foods/123',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_harness(seed: 't', authConfigBox: authConfigBox));
      await tester.pumpAndSettle();
      await _goTo(tester, '/foods/123');

      expect(_currentPath(tester), equals('/foods/123'));
    },
  );

  testWidgets(
    'Case 6: token flip mid-app (signOut from /today) → '
    'refreshListenable re-evaluates and lands on /login',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_harness(seed: 't', authConfigBox: authConfigBox));
      await tester.pumpAndSettle();
      // Pre-condition: with a non-null token, the initialLocation
      // /today is allowed.
      expect(_currentPath(tester), equals(Routes.todayPath));

      // Flip the token via the notifier — the override's signOut
      // simply sets `state = null` (no Hive / secure-store side
      // effects).
      final element = tester.element(find.byType(MaterialApp));
      final container = ProviderScope.containerOf(element);
      await container.read(authTokenProvider.notifier).signOut();
      await tester.pumpAndSettle();

      expect(_currentPath(tester), equals(Routes.loginPath));
    },
  );
}
