import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/features/login/login_controller.dart';
import 'package:fulfilled/features/login/login_screen.dart';
import 'package:fulfilled/features/login/widgets/credentials_form.dart';
import 'package:fulfilled/features/login/widgets/login_button.dart';
import 'package:fulfilled/features/login/widgets/server_url_field.dart';
import 'package:fulfilled/routing/routes.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:go_router/go_router.dart';

/// LOG-006 — compact (mobile) widget test for `LoginScreen`.
///
/// Mounted at iPhone-class width (393 × 851); overrides
/// `loginControllerProvider` with a `_FakeLoginController` that owns
/// its own `LoginFormState` so the test drives the controller's state
/// directly (the real controller's submit flow is exercised in
/// `login_controller_test.dart`; here we test the *widget's* binding
/// to the controller — fields render, taps wire through, navigation
/// runs on submit success).
///
/// Assertions per ticket Scope checklist:
///   - Three `TextField`s render in the correct order (URL → username
///     → password).
///   - The headline "Sign in to your server" renders.
///   - The happy submit path drives `context.go('/today')` (T-24 Case 2).
///   - **Zero** `CircularProgressIndicator` exists anywhere in the
///     widget subtree during a submitting state (T-08).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LoginScreen — compact (mobile)', () {
    testWidgets('renders three TextFields in URL → username → password order',
        (tester) async {
      tester.view.physicalSize = const Size(393, 851);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fake = _FakeLoginController(const LoginFormState(
        url: '',
        username: '',
        password: '',
        allowInsecure: false,
      ),);

      await tester.pumpWidget(_harness(fake: fake));
      await tester.pumpAndSettle();

      // Headline.
      expect(find.text('Sign in to your server'), findsOneWidget);

      // Three TextFields render on mobile (URL + username + password).
      expect(find.byType(TextField), findsNWidgets(3));
      // The URL field is present (compact / `!kIsWeb` path).
      expect(find.byType(ServerUrlField), findsOneWidget);
      // The credentials form is present.
      expect(find.byType(CredentialsForm), findsOneWidget);
      // The submit button is present.
      expect(find.byType(LoginButton), findsOneWidget);

      // Top-to-bottom order — ServerUrlField appears above
      // CredentialsForm vertically.
      final urlTopLeft = tester.getTopLeft(find.byType(ServerUrlField));
      final credsTopLeft = tester.getTopLeft(find.byType(CredentialsForm));
      expect(
        urlTopLeft.dy < credsTopLeft.dy,
        isTrue,
        reason: 'ServerUrlField should render above CredentialsForm',
      );
    });

    testWidgets(
        'happy submit path — tapping Sign in routes to /today (T-24 Case 2)',
        (tester) async {
      tester.view.physicalSize = const Size(393, 851);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Fake returns `true` from `submit()` → screen calls
      // `context.go(Routes.todayPath)`.
      final fake = _FakeLoginController(
        const LoginFormState(
          url: 'https://srv.example',
          username: 'alice',
          password: 'hunter2',
          allowInsecure: false,
        ),
        submitResult: true,
      );

      final router = _buildRouter();
      await tester.pumpWidget(_harness(fake: fake, router: router));
      await tester.pumpAndSettle();

      // Sanity: starting location is /login.
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        equals('/login'),
      );

      await tester.tap(find.text('Sign in'));
      // First pump kicks the submit Future; second settles the route
      // change.
      await tester.pump();
      await tester.pumpAndSettle();

      // The screen navigated to /today.
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        equals('/today'),
        reason: 'context.go(Routes.todayPath) should land on /today',
      );
      // The fake's submit was called exactly once.
      expect(fake.submitCalls, equals(1));
    });

    testWidgets('zero CircularProgressIndicator anywhere during submit (T-08)',
        (tester) async {
      tester.view.physicalSize = const Size(393, 851);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Seed in the submitting state from the start.
      final fake = _FakeLoginController(
        const LoginFormState(
          url: 'https://srv.example',
          username: 'alice',
          password: 'hunter2',
          allowInsecure: false,
          submitting: true,
        ),
      );

      await tester.pumpWidget(_harness(fake: fake));
      // Don't `pumpAndSettle` — a `CircularProgressIndicator` would
      // animate indefinitely; a single `pump` is enough to render the
      // submitting-state subtree.
      await tester.pump();

      // T-08 invariant: no spinner is rendered anywhere on the screen.
      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason: 'T-08 — login screen renders a skeleton, not a spinner',
      );
    });
  });
}

/// `MaterialApp.router` harness mounting `LoginScreen` at `/login` and
/// a throwaway `/today` so the happy-path nav assertion lands somewhere
/// real. Tests that don't care about routing can pass `router: null` —
/// a default is built for them.
Widget _harness({
  required _FakeLoginController fake,
  GoRouter? router,
}) {
  final r = router ?? _buildRouter();
  return ProviderScope(
    overrides: <Override>[
      // The fake is pre-built with a stub `Ref` in its super
      // constructor; every method that would touch the parent's
      // `_ref` field is overridden so the stub is never dereferenced.
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

/// Test double for [LoginController]. Overrides `submit()` to return a
/// pre-baked `bool` (no network, no Hive, no probe). Records the call
/// count so the happy-path test can assert exactly one submit fired.
///
/// Threads a [_StubRef] through the super constructor — the parent
/// class stores it in `_ref` for `submit()` / `_persistConfig`. Both
/// are overridden here (or unreachable), so the stub is never actually
/// dereferenced; `noSuchMethod` on `_StubRef` throws as a loud-failure
/// guard if the assumption is broken.
class _FakeLoginController extends LoginController {
  _FakeLoginController(
    LoginFormState initial, {
    this.submitResult = true,
  }) : super(_StubRef(), initial: initial);

  /// Value returned by [submit]. Defaults to `true` (happy path).
  final bool submitResult;

  int submitCalls = 0;

  @override
  Future<bool> submit() async {
    submitCalls += 1;
    // The real controller flips `submitting` to `true` on entry, runs
    // the five phases, and flips it back in a `finally`. Our fake
    // returns the pre-baked result synchronously — the screen only
    // needs `submit()`'s `Future<bool>` to resolve so the post-submit
    // `context.go` branch fires.
    return submitResult;
  }
}

/// Stub `Ref` for the fake controller's super constructor. The fake
/// overrides every method that would touch the parent's `_ref` field,
/// so this stub is never actually dereferenced — `noSuchMethod`
/// throws as a loud-failure guard if the assumption is ever broken.
///
/// Implements the un-parameterized `Ref` (defaulting to `Ref<Object?>`)
/// because the `LoginController` constructor takes a bare `Ref _ref`
/// parameter; matching the field's static type avoids a generics
/// mismatch under strict-cast.
class _StubRef implements Ref<Object?> {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError(
        '_StubRef does not forward ${invocation.memberName}. The fake '
        'LoginController should not call any Ref method.',
      );
}
