import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/features/login/login_controller.dart';
import 'package:fulfilled/features/login/login_screen.dart';
import 'package:fulfilled/features/login/widgets/credentials_form.dart';
import 'package:fulfilled/features/login/widgets/server_url_field.dart';
import 'package:fulfilled/routing/routes.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:go_router/go_router.dart';

/// LOG-006 — web widget test for `LoginScreen`.
///
/// ## Why no `kIsWebProvider` override
///
/// The ticket's "kIsWebProvider override" suggestion can't drive
/// `LoginScreen`'s field-omission branch directly: the screen's
/// `_LoginBody` reads `kIsWeb` from `package:flutter/foundation.dart`,
/// which is a **compile-time constant** — there's no runtime seam to
/// flip from a Riverpod override. LOG-001 shipped `apiBaseUrlProvider`
/// with `kIsWeb` baked in via `kIsWebProvider`, but the LoginScreen
/// itself reads `kIsWeb` directly so the field-omission gate is a
/// build-time decision: under `flutter test` the host VM has
/// `kIsWeb == false`, so the `ServerUrlField` subtree IS rendered.
///
/// What this test verifies under the host VM:
///   - The screen mounts cleanly when the controller's state simulates
///     the web path: empty `url` + a controller whose `submit()`
///     skips Phase 2 (URL normalize) and resolves `true` immediately.
///   - The happy-path navigation lands on `/today` (T-24 Case 2) when
///     submit succeeds — same wire as the compact test.
///   - The credentials form renders.
///
/// What this test does NOT verify:
///   - The `ServerUrlField` is absent on web. That assertion requires
///     a real web bundle (`flutter test --platform chrome`); the
///     build-time `if (!kIsWeb)` gate in `login_screen.dart` is the
///     load-bearing contract. The host-VM test asserts `findsOneWidget`
///     for the URL field as a sanity check that the build-time gate
///     is shaped correctly (when `!kIsWeb`, render it).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LoginScreen — web (kIsWeb simulated via controller state)', () {
    testWidgets(
        'happy submit path with empty url + populated credentials lands on '
        '/today (T-24 Case 2)', (tester) async {
      // Desktop-web reference viewport — same shape as a centred-card
      // expanded layout (architect §6).
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Web path: `url` stays empty in state (the real controller reads
      // `apiBaseUrlProvider` at submit time and skips Phase 2 URL
      // normalize — see `login_controller.dart`'s `kIsWeb` branch).
      // The fake's `submit()` short-circuits with `true`.
      final fake = _FakeLoginController(
        const LoginFormState(
          url: '',
          username: 'alice',
          password: 'hunter2',
          allowInsecure: false,
        ),
      );

      final router = _buildRouter();
      await tester.pumpWidget(_harness(fake: fake, router: router));
      await tester.pumpAndSettle();

      // Credentials present.
      expect(find.byType(CredentialsForm), findsOneWidget);

      // Two credential TextFields render. Under host-VM `flutter test`
      // (`kIsWeb == false`) the URL field also renders, so the total
      // TextField count is 3; the credentials-only count is asserted
      // by descendant-counting inside the CredentialsForm subtree.
      expect(
        find.descendant(
          of: find.byType(CredentialsForm),
          matching: find.byType(TextField),
        ),
        findsNWidgets(2),
      );

      // Under host-VM `flutter test` (`kIsWeb == false`) the URL field
      // renders. The web omission is a build-time `if (!kIsWeb)` gate
      // in `login_screen.dart`; a real web bundle would assert
      // `findsNothing` here. Documenting both states keeps the
      // regression guard explicit.
      expect(find.byType(ServerUrlField), findsOneWidget);

      // Tap Sign in — the fake `submit()` returns `true` immediately.
      await tester.tap(find.text('Sign in'));
      await tester.pump();
      await tester.pumpAndSettle();

      // Navigation landed on /today (same happy-path nav as compact).
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        equals('/today'),
        reason: 'context.go(Routes.todayPath) should land on /today',
      );
      expect(fake.submitCalls, equals(1));
    });
  });
}

Widget _harness({
  required _FakeLoginController fake,
  GoRouter? router,
}) {
  final r = router ?? _buildRouter();
  return ProviderScope(
    overrides: <Override>[
      loginControllerProvider.overrideWith((ref) => fake),
    ],
    child: MaterialApp.router(
      theme: buildLightTheme(),
      routerConfig: r,
    ),
  );
}

GoRouter _buildRouter() {
  return GoRouter(
    initialLocation: Routes.loginPath,
    routes: <RouteBase>[
      GoRoute(
        name: Routes.loginName,
        path: Routes.loginPath,
        builder: (_, __) => const LoginScreen(),
      ),
      GoRoute(
        name: Routes.todayName,
        path: Routes.todayPath,
        builder: (_, __) =>
            const Scaffold(body: Center(child: Text('today landed'))),
      ),
      GoRoute(
        name: Routes.onboardingName,
        path: Routes.onboardingPath,
        builder: (_, __) =>
            const Scaffold(body: Center(child: Text('onboarding'))),
      ),
    ],
  );
}

/// Test double mirroring the compact test's fake. See
/// `login_screen_compact_test.dart` for the rationale.
class _FakeLoginController extends LoginController {
  _FakeLoginController(LoginFormState initial)
      : super(_StubRef(), initial: initial);

  int submitCalls = 0;

  /// Web tests don't currently exercise the submit-fail branch — when
  /// they do, the compact test's `submitResult` named param is the
  /// seam to copy in. Kept simple for now.
  @override
  Future<bool> submit() async {
    submitCalls += 1;
    return true;
  }
}

class _StubRef implements Ref<Object?> {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError(
        '_StubRef does not forward ${invocation.memberName}. The fake '
        'LoginController should not call any Ref method.',
      );
}
