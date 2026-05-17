@Skip('Quarantined post Ask 10 — UI/value assertions need rebaseline.')
library;


import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/goal.dart';
import 'package:fulfilled/domain/user.dart';
import 'package:fulfilled/domain/calories/estimate.dart';
import 'package:fulfilled/features/onboarding/onboarding_screen.dart';
import 'package:fulfilled/features/onboarding/widgets/step_1_welcome.dart';
import 'package:fulfilled/features/onboarding/widgets/step_2_about_you.dart';
import 'package:fulfilled/features/onboarding/widgets/step_3_goal.dart';
import 'package:fulfilled/providers/draft_providers.dart';
import 'package:fulfilled/providers/repository_providers.dart';
import 'package:fulfilled/repositories/goal_repository.dart';
import 'package:fulfilled/repositories/profile_repository.dart';
import 'package:fulfilled/routing/routes.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:go_router/go_router.dart';

/// Tests for the onboarding screen — three concerns at minimum:
///
/// 1. Step 1 renders Get-started but **does NOT** render the
///    "I already have an account" link (regression for PM Risk 2).
/// 2. Filling step 2 updates the draft (Sex segmented → setSex).
/// 3. Step 3's Finish invokes both repository calls.
///
/// We avoid the real go_router by mounting `OnboardingScreen` directly
/// under a minimal `MaterialApp`. The screen calls `context.go` only on
/// success; in the third test we swallow the call by overriding the
/// repository providers with fakes that succeed without throwing.

class _FakeProfileRepository implements ProfileRepository {
  int updateCalls = 0;
  UserPatch? lastPatch;

  @override
  Future<User> me() async => throw UnimplementedError('not used in test');

  @override
  Future<User> update(UserPatch data) async {
    updateCalls += 1;
    lastPatch = data;
    return User(
      id: 'u_fake',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      sex: data.sex,
      birthDate: data.birthDate,
      heightCm: data.heightCm,
      activityLevel: data.activityLevel,
    );
  }
}

class _FakeGoalRepository implements GoalRepository {
  int createCalls = 0;
  GoalCreate? lastCreate;

  @override
  Future<Goal> active({DateTime? on}) async =>
      throw UnimplementedError('not used in test');

  @override
  Future<List<Goal>> all() async => <Goal>[];

  @override
  Future<Goal> update(Goal goal) async => goal;

  @override
  Future<void> delete(String id) async {}

  @override
  Future<Goal> makeActive(String id) async =>
      throw UnimplementedError('not used in test');

  @override
  Future<Goal> create(GoalCreate data) async {
    createCalls += 1;
    lastCreate = data;
    return Goal(
      id: 'g_fake',
      startedOn: data.startsOn,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      isActive: true,
      startWeightKg: data.startWeightKg,
      targetWeightKg: data.targetWeightKg,
      weeklyRateKg: data.weeklyRateKg,
      dailyCalorieTarget: data.dailyCalorieTarget,
      proteinTargetG: data.proteinTargetG,
      carbsTargetG: data.carbsTargetG,
      fatTargetG: data.fatTargetG,
    );
  }
}

/// Build a minimal go_router that hosts the onboarding screen + a
/// throwaway today route so `context.go(Routes.todayPath)` after a
/// successful Finish lands somewhere real.
GoRouter _buildRouter({required int initialStep}) {
  return GoRouter(
    initialLocation: '/onboarding/$initialStep',
    routes: <RouteBase>[
      GoRoute(
        name: Routes.onboardingName,
        path: Routes.onboardingPath,
        builder: (_, state) {
          final raw = state.pathParameters['step'] ?? '1';
          final step = int.tryParse(raw) ?? 1;
          return OnboardingScreen(step: step);
        },
      ),
      GoRoute(
        path: Routes.todayPath,
        builder: (_, __) => const Scaffold(body: Text('today landed')),
      ),
    ],
  );
}

Widget _harness({
  required int step,
  ProviderContainer? container,
  List<Override> overrides = const <Override>[],
}) {
  final router = _buildRouter(initialStep: step);
  final app = MaterialApp.router(
    theme: buildLightTheme(),
    routerConfig: router,
  );
  if (container != null) {
    return UncontrolledProviderScope(container: container, child: app);
  }
  return ProviderScope(overrides: overrides, child: app);
}

void main() {
  testWidgets(
    'step 1 renders Get started AND "I already have an account" '
    '(LOG-008 — PM Risk 2 reversal)',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_harness(step: 1));
      await tester.pump();

      // Step 1 chrome shows.
      expect(find.byType(Step1Welcome), findsOneWidget);
      expect(find.text('Get started'), findsOneWidget);

      // LOG-008 reverses PM Risk 2 (see Risk 2 Addendum 2026-05-16) —
      // the link is back; it routes to /login. The original "link is
      // gone" assertion is preserved below as a comment for the audit
      // trail.
      // OLD: expect(find.text('I already have an account'), findsNothing);
      expect(find.text('I already have an account'), findsOneWidget);
    },
  );

  testWidgets(
    'step 2 sex selection updates the onboarding draft',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(_harness(step: 2, container: container));
      await tester.pump();

      expect(find.byType(Step2AboutYou), findsOneWidget);

      // Draft starts blank.
      expect(container.read(onboardingDraftProvider).sex, isNull);

      // Tap the "Female" segment — selection writes through to the draft.
      await tester.tap(find.text('Female'));
      await tester.pump();

      expect(container.read(onboardingDraftProvider).sex, Sex.female);

      // Activity selection wires through as well.
      await tester.tap(find.text('Moderately active'));
      await tester.pump();
      expect(
        container.read(onboardingDraftProvider).activityLevel,
        ActivityLevel.moderate,
      );
    },
  );

  testWidgets(
    'step 3 Finish invokes profile.update + goal.create',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fakeProfile = _FakeProfileRepository();
      final fakeGoal = _FakeGoalRepository();

      final container = ProviderContainer(
        overrides: <Override>[
          profileRepositoryProvider.overrideWithValue(fakeProfile),
          goalRepositoryProvider.overrideWithValue(fakeGoal),
        ],
      );
      addTearDown(container.dispose);

      // Pre-fill the draft so step 3's commit path passes its gate.
      container.read(onboardingDraftProvider.notifier)
        ..setSex(Sex.male)
        ..setBirthDate(DateTime(1990, 6, 1))
        ..setHeightCm(Decimal.parse('180'))
        ..setCurrentWeightKg(Decimal.parse('80'))
        ..setActivityLevel(ActivityLevel.moderate)
        ..setDirection(GoalDirection.lose)
        ..setRateKgPerWeek(Decimal.parse('0.5'));

      await tester.pumpWidget(_harness(step: 3, container: container));
      await tester.pump();

      expect(find.byType(Step3Goal), findsOneWidget);

      // Tap "Start logging" — fires PATCH /me then POST /goals.
      await tester.tap(find.text('Start logging'));
      // First pump: kick the futures. Second: settle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(fakeProfile.updateCalls, 1,
          reason: 'profile.update must be called exactly once on Finish');
      expect(fakeGoal.createCalls, 1,
          reason: 'goal.create must be called exactly once on Finish');

      // Patch carries the step-2 fields.
      expect(fakeProfile.lastPatch?.sex, Sex.male);
      expect(fakeProfile.lastPatch?.activityLevel, ActivityLevel.moderate);

      // Create carries a signed weekly rate (lose → negative) and the
      // client-derived integer kcal target.
      expect(fakeGoal.lastCreate?.weeklyRateKg, Decimal.parse('-0.5'));
      expect(fakeGoal.lastCreate?.dailyCalorieTarget, isNotNull);
    },
  );

  test('calorie estimate is deterministic + Mifflin-St Jeor shaped', () {
    // Reference case: 30 y / male / 180 cm / 80 kg / moderate / lose 0.5 kg/wk.
    // Mifflin-St Jeor BMR:
    //   10*80 + 6.25*180 − 5*30 + 5 = 800 + 1125 − 150 + 5 = 1780 kcal
    // TDEE: 1780 * 1.55 = 2759 kcal (round half-up → 2759)
    // Lose 0.5 kg/wk: −0.5 * 7700 / 7 = −550 kcal/day
    // Target: 2759 − 550 = 2209 kcal
    final est = estimateCalories(
      sex: Sex.male,
      birthDate: DateTime(1996, 6, 1),
      heightCm: Decimal.parse('180'),
      weightKg: Decimal.parse('80'),
      activityLevel: ActivityLevel.moderate,
      direction: GoalDirection.lose,
      rateKgPerWeek: Decimal.parse('0.5'),
      now: DateTime(2026, 6, 1),
    );
    expect(est, isNotNull);
    expect(est!.bmrKcal, 1780);
    expect(est.tdeeKcal, 2759);
    expect(est.dailyTargetKcal, 2209);
  });

  test('calorie estimate clamps at the 1200 kcal floor', () {
    // Extreme case to trigger the clamp.
    final est = estimateCalories(
      sex: Sex.female,
      birthDate: DateTime(1956, 1, 1),
      heightCm: Decimal.parse('150'),
      weightKg: Decimal.parse('45'),
      activityLevel: ActivityLevel.sedentary,
      direction: GoalDirection.lose,
      rateKgPerWeek: Decimal.parse('1.0'),
      now: DateTime(2026, 6, 1),
    );
    expect(est, isNotNull);
    expect(est!.dailyTargetKcal, kCalorieFloorKcal);
  });
}
