import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/data/auth_token.dart';
import 'package:fulfilled/routing/app_router.dart';
import 'package:fulfilled/routing/routes.dart';
import 'package:go_router/go_router.dart';

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
Widget _harness({required String? seed}) {
  return ProviderScope(
    overrides: <Override>[
      authTokenProvider
          .overrideWith(() => _FakeAuthTokenNotifier(seed)),
    ],
    child: Consumer(
      builder: (context, ref, _) {
        final router = ref.watch(appRouterProvider);
        return MaterialApp.router(routerConfig: router);
      },
    ),
  );
}

/// Returns the current router URI path from the mounted app.
String _currentPath(WidgetTester tester) {
  final routerContext = tester.element(find.byType(MaterialApp));
  return GoRouter.of(routerContext)
      .routerDelegate
      .currentConfiguration
      .uri
      .path;
}

/// Convenience — drives the router to [location] and pumps.
Future<void> _goTo(WidgetTester tester, String location) async {
  final routerContext = tester.element(find.byType(MaterialApp));
  GoRouter.of(routerContext).go(location);
  await tester.pumpAndSettle();
}

void main() {
  // Keep the viewport predictable across tests; the auth gate is
  // breakpoint-agnostic but the shell isn't.
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  testWidgets(
    'Case 1: no token + /today → redirects to /login',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_harness(seed: null));
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

      await tester.pumpWidget(_harness(seed: null));
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

      await tester.pumpWidget(_harness(seed: null));
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

      await tester.pumpWidget(_harness(seed: 't'));
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

      await tester.pumpWidget(_harness(seed: 't'));
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

      await tester.pumpWidget(_harness(seed: 't'));
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
