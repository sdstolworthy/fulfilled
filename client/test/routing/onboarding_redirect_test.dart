import 'dart:io';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/data/auth_config.dart';
import 'package:fulfilled/data/auth_token.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/user.dart';
import 'package:fulfilled/form_factor/form_factor.dart';
import 'package:fulfilled/providers/profile_providers.dart';
import 'package:fulfilled/providers/repository_providers.dart';
import 'package:fulfilled/repositories/_mock_latency.dart';
import 'package:fulfilled/routing/app_router.dart';
import 'package:fulfilled/routing/routes.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:go_router/go_router.dart';
import 'package:hive/hive.dart';

/// F3-T2 — Onboarding-gate redirect tests.
///
/// Three cases per the ticket §8 + audit §1.1:
///   1. Fresh authed user (all four onboarding fields null) → `/onboarding/1`.
///   2. Already-onboarded user (all four fields set) → `/today`.
///   3. Partially-onboarded user (only `sex` set, others null) → `/onboarding/1`.
///
/// We override `meProvider` directly (Riverpod 2's `FutureProvider.overrideWith`)
/// so we sidestep the quarantined mock-fixture churn that's currently blocking
/// `auth_redirect_test.dart`.

/// Fake `AuthTokenNotifier` that pins the token to a constant — the real
/// notifier short-circuits to `'dev-bypass'` in `kDebugMode` (test runner
/// is always debug-mode), so we can't get a stable seed without an
/// override.
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

/// Convenience — builds the harness app with the auth + meProvider overrides.
Widget _harness({
  required String? token,
  required User me,
  required Box<String> authConfigBox,
}) {
  return ProviderScope(
    overrides: <Override>[
      authTokenProvider.overrideWith(() => _FakeAuthTokenNotifier(token)),
      // F3-T2 — override `meProvider` so the redirect predicate reads
      // the synthetic user instead of hitting the real repository.
      // `FutureProvider.overrideWith` returns the resolved value
      // synchronously on first read, so the redirect lands the gate
      // decision on the first frame.
      meProvider.overrideWith((ref) async => me),
      formFactorOverrideProvider.overrideWithValue(FormFactor.medium),
      authConfigBoxProvider.overrideWithValue(authConfigBox),
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

/// Returns the current router URI path from the mounted app.
String _currentPath(WidgetTester tester) {
  final routerContext = tester.element(find.byType(Navigator).first);
  return GoRouter.of(routerContext)
      .routerDelegate
      .currentConfiguration
      .uri
      .path;
}

/// Builds a fresh-user [User] — none of the four onboarding fields set.
User _freshUser() {
  return User(
    id: 'u_test',
    createdAt: DateTime(2026, 5, 1),
    updatedAt: DateTime(2026, 5, 1),
    // sex, birthDate, heightCm, activityLevel all default to null.
  );
}

/// Builds an onboarded [User] — all four onboarding fields set.
User _onboardedUser() {
  return User(
    id: 'u_test',
    createdAt: DateTime(2026, 5, 1),
    updatedAt: DateTime(2026, 5, 1),
    sex: Sex.female,
    birthDate: DateTime(1992, 4, 17),
    heightCm: Decimal.parse('165'),
    activityLevel: ActivityLevel.moderate,
  );
}

/// Builds a partially-onboarded [User] — `sex` set, the other three
/// onboarding fields still null. Per the FE plan §8 the predicate
/// bounces them back to step 1 regardless of which fields are set.
User _partiallyOnboardedUser() {
  return User(
    id: 'u_test',
    createdAt: DateTime(2026, 5, 1),
    updatedAt: DateTime(2026, 5, 1),
    sex: Sex.female,
    // birthDate, heightCm, activityLevel all still null.
  );
}

void main() {
  late Directory hiveDir;
  late Box<String> authConfigBox;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setMockLatencyForTesting();
    hiveDir = await Directory.systemTemp
        .createTemp('fulfilled-onboarding-redirect-');
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
    'Case 1: fresh authed user (all four onboarding fields null) → /onboarding/1',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _harness(
          token: 't',
          me: _freshUser(),
          authConfigBox: authConfigBox,
        ),
      );
      await tester.pumpAndSettle();

      // initialLocation is /today; the F3 redirect should sweep us to
      // /onboarding/1 once meProvider resolves the fresh user.
      expect(_currentPath(tester), equals('/onboarding/1'));
    },
  );

  testWidgets(
    'Case 2: already-onboarded user → /today (no redirect)',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _harness(
          token: 't',
          me: _onboardedUser(),
          authConfigBox: authConfigBox,
        ),
      );
      await tester.pumpAndSettle();

      expect(_currentPath(tester), equals(Routes.todayPath));
    },
  );

  testWidgets(
    'Case 3: partially-onboarded user (only sex set) → /onboarding/1',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _harness(
          token: 't',
          me: _partiallyOnboardedUser(),
          authConfigBox: authConfigBox,
        ),
      );
      await tester.pumpAndSettle();

      expect(_currentPath(tester), equals('/onboarding/1'));
    },
  );
}
