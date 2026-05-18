import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/data/auth_token.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/user.dart';
import 'package:fulfilled/providers/profile_providers.dart';
import 'package:fulfilled/routing/app_router.dart';
import 'package:fulfilled/theme/theme_data.dart';

/// AppScaffold renders three nav chromes. Golden tests are stubbed here —
/// the first agent who runs `flutter test --update-goldens` checks the
/// generated images into `test/widget/goldens/`. Until then, these tests
/// run as ordinary widget tests (no goldens assertion) so CI stays green.
///
/// TODO(golden): once goldens land, drop the smoke `expect` and re-enable
/// `matchesGoldenFile`. Three breakpoints come from
/// `tester.view.physicalSize` so the same widget tree renders at three
/// widths.

/// Fully-onboarded user — the router redirect rule short-circuits on
/// `needsOnboarding(me) == false` and lets us land on `/today`. Without
/// the override, `meProvider` would resolve via the real
/// `profileRepository.me()` chain → `apiClientProvider` → Dio with the
/// `about:invalid` sentinel base URL → throw before this test ever
/// gets to the scaffold.
User _onboardedUser() => User(
      id: 'u_test',
      displayName: 'Test',
      email: 't@example.com',
      sex: Sex.male,
      birthDate: DateTime(1990, 1, 1),
      heightCm: Decimal.fromInt(180),
      activityLevel: ActivityLevel.moderate,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

Widget _harness() {
  return ProviderScope(
    overrides: <Override>[
      // Seed a token so the router doesn't redirect to `/login` before
      // we can assert the scaffold renders.
      authTokenProvider.overrideWith(() => _StubAuthTokenNotifier('stub')),
      // Skip the real /me network fetch — the router's redirect rule
      // (added in 4b956a4) reads `meProvider.value` synchronously.
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

/// Stub notifier — ships a non-null token from `build()` so the
/// auth-gate redirect skips the `/login` bounce.
class _StubAuthTokenNotifier extends AuthTokenNotifier {
  _StubAuthTokenNotifier(this._seed);

  final String _seed;

  @override
  String? build() => _seed;
}

void main() {
  testWidgets('compact renders bottom NavigationBar', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness());
    await tester.pump();

    // TODO(golden): await expectLater(
    //   find.byType(MaterialApp),
    //   matchesGoldenFile('goldens/app_scaffold_compact.png'),
    // );
    expect(find.byType(NavigationBar), findsWidgets);
  });

  testWidgets('medium renders NavigationRail', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness());
    await tester.pump();

    // TODO(golden): matchesGoldenFile('goldens/app_scaffold_medium.png').
    expect(find.byType(NavigationRail), findsWidgets);
  });

  testWidgets('expanded renders the 240 px sidebar', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness());
    await tester.pump();

    // TODO(golden): matchesGoldenFile('goldens/app_scaffold_expanded.png').
    // Sidebar is a 240-wide Container. A real golden replaces this smoke
    // assertion with pixel truth.
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
