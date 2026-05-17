import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/features/onboarding/widgets/step_1_welcome.dart';
import 'package:fulfilled/routing/routes.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:go_router/go_router.dart';

/// LOG-008 — the "I already have an account" link on onboarding step 1.
///
/// PM Risk 2 originally cut this link on the premise that v1 had no login
/// screen to route to; LOG-006 reversed that premise. This test asserts the
/// link renders with the exact text the spec mandates and that tapping it
/// drives the router to `Routes.loginPath` (`/login`).
///
/// We mount `Step1Welcome` inside a throwaway two-route `GoRouter` so we can
/// observe `routerDelegate.currentConfiguration.uri.path` after the tap —
/// no real router, no real onboarding flow, no providers under test.
GoRouter _buildRouter() {
  return GoRouter(
    initialLocation: '/onboarding/1',
    routes: <RouteBase>[
      GoRoute(
        path: '/onboarding/1',
        builder: (_, __) => const Scaffold(body: Step1Welcome()),
      ),
      GoRoute(
        path: Routes.loginPath,
        builder: (_, __) => const Scaffold(body: Text('login landed')),
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'taps "I already have an account" → router lands on /login',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final router = _buildRouter();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp.router(
            theme: buildLightTheme(),
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The link renders with the verbatim label LOG-008 mandates.
      final link = find.widgetWithText(TextButton, 'I already have an account');
      expect(link, findsOneWidget);

      // Tap it; the GoRouter switches routes on the next pump.
      await tester.ensureVisible(link);
      await tester.tap(link);
      await tester.pumpAndSettle();

      // Router is now at /login.
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        equals(Routes.loginPath),
      );
      expect(find.text('login landed'), findsOneWidget);
    },
  );
}
