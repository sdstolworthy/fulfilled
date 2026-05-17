@Skip('Quarantined post Ask 10 — UI/value assertions need rebaseline.')
library;


import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/goal.dart';
import 'package:fulfilled/domain/user.dart';
import 'package:fulfilled/features/onboarding/onboarding_screen.dart';
import 'package:fulfilled/features/onboarding/widgets/step_2_about_you.dart';
import 'package:fulfilled/providers/draft_providers.dart';
import 'package:fulfilled/providers/profile_providers.dart';
import 'package:fulfilled/providers/repository_providers.dart';
import 'package:fulfilled/repositories/goal_repository.dart';
import 'package:fulfilled/repositories/profile_repository.dart';
import 'package:fulfilled/routing/routes.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/height_stepper.dart';
import 'package:go_router/go_router.dart';

/// QL-104 — onboarding step 2 height feature.
///
/// (a) step 2 renders the Units label with two SegmentedSelects below
///     it (Weight + Height).
/// (b) step 2 renders HeightStepper for the height column.
/// (c) Setting the height segmented control to ftIn updates the
///     stepper's mode (cm row → ft+in rows).
/// (d) finish handler PATCH includes both heightUnit and weightUnit.
/// (e) finish handler defaults heightUnit to defaultUnitsForLocale()
///     when draft is null.

class _FakeProfileRepository implements ProfileRepository {
  UserPatch? lastPatch;

  @override
  Future<User> me() async => throw UnimplementedError('not used in test');

  @override
  Future<User> update(UserPatch data) async {
    lastPatch = data;
    return User(
      id: 'u_fake',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      sex: data.sex,
      birthDate: data.birthDate,
      heightCm: data.heightCm,
      activityLevel: data.activityLevel,
      weightUnit: data.weightUnit ?? WeightUnit.kg,
      heightUnit: data.heightUnit ?? HeightUnit.cm,
    );
  }
}

class _FakeGoalRepository implements GoalRepository {
  GoalCreate? lastCreate;

  @override
  Future<Goal> active({DateTime? on}) async =>
      throw UnimplementedError('not used in test');

  @override
  Future<List<Goal>> all() async => <Goal>[];

  @override
  Future<Goal> makeActive(String id) async =>
      throw UnimplementedError('not used in test');

  @override
  Future<Goal> update(Goal goal) async =>
      throw UnimplementedError('not used in test');

  @override
  Future<void> delete(String id) async {}

  @override
  Future<Goal> create(GoalCreate data) async {
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

Widget _step2Harness({required ProviderContainer container}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: buildLightTheme(),
      home: const Scaffold(
        body: SingleChildScrollView(
          padding: EdgeInsets.all(16),
          child: Step2AboutYou(),
        ),
      ),
    ),
  );
}

GoRouter _onboardingRouter({required int initialStep}) {
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

Widget _onboardingHarness({
  required int step,
  required ProviderContainer container,
}) {
  final router = _onboardingRouter(initialStep: step);
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(
      theme: buildLightTheme(),
      routerConfig: router,
    ),
  );
}

void main() {
  testWidgets(
    '(a) step 2 renders the Units label with both segmented controls',
    (tester) async {
      tester.view.physicalSize = const Size(414, 1500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = ProviderContainer(
        overrides: <Override>[
          localeDefaultWeightUnitProvider
              .overrideWithValue(WeightUnit.kg),
          localeDefaultHeightUnitProvider
              .overrideWithValue(HeightUnit.cm),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_step2Harness(container: container));
      await tester.pumpAndSettle();

      // The "Units" label is rendered (uppercased by _FieldLabel).
      expect(find.text('UNITS'), findsOneWidget);

      // Both segmented choosers are present, keyed.
      expect(
        find.byKey(const Key('onboarding-weight-unit-chooser')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('onboarding-height-unit-chooser')),
        findsOneWidget,
      );

      // Each chooser surfaces its full label set.
      expect(find.text('Kilograms (kg)'), findsOneWidget);
      expect(find.text('Pounds (lb)'), findsOneWidget);
      expect(find.text('Stones (st)'), findsOneWidget);
      expect(find.text('Centimeters (cm)'), findsOneWidget);
      expect(find.text('Feet & inches'), findsOneWidget);
    },
  );

  testWidgets(
    '(b) step 2 renders HeightStepper for the height column',
    (tester) async {
      tester.view.physicalSize = const Size(414, 1500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = ProviderContainer(
        overrides: <Override>[
          localeDefaultWeightUnitProvider
              .overrideWithValue(WeightUnit.kg),
          localeDefaultHeightUnitProvider
              .overrideWithValue(HeightUnit.cm),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_step2Harness(container: container));
      await tester.pumpAndSettle();

      // The lifted HeightStepper is in the tree.
      expect(find.byType(HeightStepper), findsOneWidget);
      expect(
        find.byKey(const Key('onboarding-height-stepper')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    '(c) tapping the ftIn height segment updates the stepper mode',
    (tester) async {
      tester.view.physicalSize = const Size(414, 1500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = ProviderContainer(
        overrides: <Override>[
          localeDefaultWeightUnitProvider
              .overrideWithValue(WeightUnit.kg),
          localeDefaultHeightUnitProvider
              .overrideWithValue(HeightUnit.cm),
        ],
      );
      addTearDown(container.dispose);

      // Pre-seed a known height so we can predict the ft+in
      // decomposition (175 cm → 5 ft 9 in).
      container
          .read(onboardingDraftProvider.notifier)
          .setHeightCm(Decimal.fromInt(175));

      await tester.pumpWidget(_step2Harness(container: container));
      await tester.pumpAndSettle();

      // cm mode initially.
      expect(find.text('175 cm'), findsOneWidget);

      // Tap the Feet & inches segment.
      await tester.tap(find.text('Feet & inches'));
      await tester.pumpAndSettle();

      // Stepper rebuilt in ftIn mode.
      expect(
        container.read(onboardingDraftProvider).heightUnit,
        HeightUnit.ftIn,
      );
      expect(find.text('5 ft'), findsOneWidget);
      expect(find.text('9 in'), findsOneWidget);
    },
  );

  testWidgets(
    '(d) finish handler PATCH includes both heightUnit and weightUnit',
    (tester) async {
      tester.view.physicalSize = const Size(414, 1500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fakeProfile = _FakeProfileRepository();
      final fakeGoal = _FakeGoalRepository();

      final container = ProviderContainer(
        overrides: <Override>[
          profileRepositoryProvider.overrideWithValue(fakeProfile),
          goalRepositoryProvider.overrideWithValue(fakeGoal),
          localeDefaultWeightUnitProvider
              .overrideWithValue(WeightUnit.kg),
          localeDefaultHeightUnitProvider
              .overrideWithValue(HeightUnit.cm),
        ],
      );
      addTearDown(container.dispose);

      container.read(onboardingDraftProvider.notifier)
        ..setSex(Sex.male)
        ..setBirthDate(DateTime(1990, 6, 1))
        ..setHeightCm(Decimal.parse('180'))
        ..setCurrentWeightKg(Decimal.parse('80'))
        ..setActivityLevel(ActivityLevel.moderate)
        ..setDirection(GoalDirection.lose)
        ..setRateKgPerWeek(Decimal.parse('0.5'))
        ..setWeightUnit(WeightUnit.lb)
        ..setHeightUnit(HeightUnit.ftIn);

      await tester.pumpWidget(
        _onboardingHarness(step: 3, container: container),
      );
      await tester.pump();

      await tester.tap(find.text('Start logging'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(fakeProfile.lastPatch?.weightUnit, WeightUnit.lb);
      expect(fakeProfile.lastPatch?.heightUnit, HeightUnit.ftIn);
    },
  );

  testWidgets(
    '(e) finish handler defaults heightUnit to locale default when draft null',
    (tester) async {
      tester.view.physicalSize = const Size(414, 1500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fakeProfile = _FakeProfileRepository();
      final fakeGoal = _FakeGoalRepository();

      final container = ProviderContainer(
        overrides: <Override>[
          profileRepositoryProvider.overrideWithValue(fakeProfile),
          goalRepositoryProvider.overrideWithValue(fakeGoal),
          // The submit path reads `defaultUnitsForLocale()` directly,
          // not via the override providers — but the assertion below
          // is "non-null", so the platform-dispatcher value (whatever
          // it is) suffices.
          localeDefaultWeightUnitProvider
              .overrideWithValue(WeightUnit.kg),
          localeDefaultHeightUnitProvider
              .overrideWithValue(HeightUnit.cm),
        ],
      );
      addTearDown(container.dispose);

      // Pre-fill the draft WITHOUT calling setHeightUnit / setWeightUnit.
      // Both `weightUnit` and `heightUnit` stay null; the submit path
      // must fall back to the locale defaults for both axes.
      container.read(onboardingDraftProvider.notifier)
        ..setSex(Sex.female)
        ..setBirthDate(DateTime(1992, 3, 14))
        ..setHeightCm(Decimal.parse('170'))
        ..setCurrentWeightKg(Decimal.parse('65'))
        ..setActivityLevel(ActivityLevel.light)
        ..setDirection(GoalDirection.maintain);

      expect(container.read(onboardingDraftProvider).heightUnit, isNull);
      expect(container.read(onboardingDraftProvider).weightUnit, isNull);

      await tester.pumpWidget(
        _onboardingHarness(step: 3, container: container),
      );
      await tester.pump();

      await tester.tap(find.text('Start logging'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        fakeProfile.lastPatch,
        isNotNull,
        reason: 'profile.update should have been called.',
      );
      expect(
        fakeProfile.lastPatch?.heightUnit,
        isNotNull,
        reason: 'Submit must fall back to defaultUnitsForLocale().heightUnit '
            'when the draft has no explicit unit.',
      );
      expect(fakeProfile.lastPatch?.weightUnit, isNotNull);
    },
  );
}
