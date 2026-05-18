import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/data/auth_token.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/user.dart';
import 'package:fulfilled/features/custom_food/custom_food_screen.dart';
import 'package:fulfilled/features/food_detail/food_detail_screen.dart';
import 'package:fulfilled/providers/profile_providers.dart';
import 'package:fulfilled/routing/app_router.dart';
import 'package:fulfilled/routing/routes.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:go_router/go_router.dart';

import '../repositories/_harness.dart';

/// F2 — Route-precedence lock-in.
///
/// Verifies that the production router resolves `/foods/new` to
/// [CustomFoodScreen] rather than letting it match the catch-all
/// `/foods/:foodId` and landing on [FoodDetailScreen]. go_router 14.x
/// walks `routes:` top-down and the first pattern that matches wins,
/// so the only thing keeping `/foods/new` from collapsing into the
/// detail route is declaration order. The four cases below cover
/// every entry point we know about:
///
///   1. `context.push('/foods/new')` — base case.
///   2. `context.push('/foods/new?barcode=…')` — T-021 prefill path.
///   3. `context.push('/foods/<opaque-id>')` — id fall-through; a
///      real food id (not the reserved `new` verb) must still land
///      on the detail screen so the fix doesn't regress lookup.
///   4. `context.go('/foods/new')` — go semantics, not push, to make
///      sure both navigation paths agree.

/// Fake [AuthTokenNotifier] that bypasses the secure-store hydration and
/// the dev-bypass branch — tests need a token present without spinning
/// up the platform secure store.
class _FakeAuthTokenNotifier extends AuthTokenNotifier {
  @override
  String? build() => 'test-token';

  @override
  Future<void> signIn(String token) async => state = token;

  @override
  Future<void> signOut() async => state = null;
}

/// Fully-onboarded user — every nullable profile field set so the F3
/// onboarding redirect (`/onboarding/1`) doesn't intercept us.
User _onboardedUser() => User(
      id: 'u_test',
      displayName: 'Tester',
      email: 'tester@example.com',
      sex: Sex.other,
      birthDate: DateTime(1990, 1, 1),
      heightCm: Decimal.fromInt(175),
      activityLevel: ActivityLevel.moderate,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 5, 1),
    );

Widget _harness() {
  return ProviderScope(
    overrides: <Override>[
      authTokenProvider.overrideWith(_FakeAuthTokenNotifier.new),
      meProvider.overrideWith((ref) async => _onboardedUser()),
    ],
    child: Consumer(
      builder: (context, ref, _) {
        final router = ref.watch(appRouterProvider);
        return MaterialApp.router(
          theme: buildLightTheme(),
          routerConfig: router,
        );
      },
    ),
  );
}

Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(_harness());
  await tester.pumpAndSettle();
}

BuildContext _routerContext(WidgetTester tester) =>
    tester.element(find.byType(Navigator).first);

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    resetRepositoriesForTest();
  });
  tearDown(teardownRepositoriesForTest);

  testWidgets('/foods/new lands on CustomFoodScreen (push)', (tester) async {
    await _pump(tester);
    unawaited(GoRouter.of(_routerContext(tester)).push(Routes.foodNewPath));
    await tester.pumpAndSettle();

    expect(
      find.byType(CustomFoodScreen),
      findsOneWidget,
      reason: 'precedence: /foods/new must beat the catch-all :foodId',
    );
    expect(find.byType(FoodDetailScreen), findsNothing);
  });

  testWidgets('/foods/new?barcode=… propagates initialBarcode',
      (tester) async {
    await _pump(tester);
    unawaited(
      GoRouter.of(_routerContext(tester))
          .push('/foods/new?barcode=0123456789'),
    );
    await tester.pumpAndSettle();

    final screen =
        tester.widget<CustomFoodScreen>(find.byType(CustomFoodScreen));
    expect(
      screen.initialBarcode,
      '0123456789',
      reason: 'T-021 — barcode query param must reach the screen',
    );
  });

  testWidgets('/foods/<opaque-id> still lands on FoodDetailScreen',
      (tester) async {
    await _pump(tester);
    // An id shaped like the server's opaque ids (not `new`, not any
    // reserved verb). The detail provider will error against the
    // unstubbed repository, but the route resolution itself is what
    // we're asserting here — FoodDetailScreen mounts.
    unawaited(GoRouter.of(_routerContext(tester)).push('/foods/f_real_id_123'));
    await tester.pumpAndSettle();

    expect(
      find.byType(FoodDetailScreen),
      findsOneWidget,
      reason: 'precedence fix must not regress real id lookups',
    );
  });

  testWidgets('context.go("/foods/new") also lands on CustomFoodScreen',
      (tester) async {
    await _pump(tester);
    GoRouter.of(_routerContext(tester)).go(Routes.foodNewPath);
    await tester.pumpAndSettle();

    expect(
      find.byType(CustomFoodScreen),
      findsOneWidget,
      reason: 'go semantics must agree with push semantics',
    );
    expect(find.byType(FoodDetailScreen), findsNothing);
  });
}
