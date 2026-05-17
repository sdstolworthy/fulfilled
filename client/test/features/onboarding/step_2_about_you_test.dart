import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
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
import 'package:go_router/go_router.dart';

/// LU-008 — onboarding step 2 weight-unit chooser + WeightStepper wiring.
///
/// Five scenarios from the dev ticket:
///   (a) Locale default selects the matching segment on first build —
///       pin [localeDefaultWeightUnitProvider] to `lb` and assert the
///       "Pounds (lb)" segment is rendered as selected.
///   (b) Tapping a different segment updates `draft.weightUnit`.
///   (c) The WeightStepper renders the active unit's suffix — tap
///       `lb`, then expect `find.text('lb')` once the inner stepper
///       rebuilds in the new unit.
///   (d) Finishing onboarding emits `UserPatch.weightUnit: <picked>`.
///   (e) Null draft.weightUnit + locale default still PATCHes a
///       non-null weight_unit (falls back to
///       `defaultWeightUnitForLocale()` at submit time).

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

/// Minimal harness for pumping `Step2AboutYou` in isolation.
Widget _step2Harness({
  required ProviderContainer container,
}) {
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

/// Build a minimal go_router that hosts the onboarding screen at a
/// given step + a throwaway today route so the screen's
/// `context.go(Routes.todayPath)` after Finish lands somewhere real.
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
    '(a) locale default selects the matching segment on first build (US → lb)',
    (tester) async {
      tester.view.physicalSize = const Size(414, 896);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final handle = tester.ensureSemantics();
      addTearDown(handle.dispose);

      final container = ProviderContainer(
        overrides: <Override>[
          // Pin the locale fallback to `lb` so the test is independent
          // of the platform dispatcher's country code.
          localeDefaultWeightUnitProvider
              .overrideWithValue(WeightUnit.lb),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_step2Harness(container: container));
      await tester.pump();

      // All three chooser labels render.
      expect(find.text('Kilograms (kg)'), findsOneWidget);
      expect(find.text('Pounds (lb)'), findsOneWidget);
      expect(find.text('Stones (st)'), findsOneWidget);

      // The "Pounds (lb)" segment carries the selected semantics
      // because the active unit derives from the (overridden) locale
      // default — the draft has no explicit weightUnit yet.
      final lbSemantics =
          tester.getSemantics(find.bySemanticsLabel('Pounds (lb)'));
      expect(
        lbSemantics.hasFlag(SemanticsFlag.isSelected),
        isTrue,
        reason: 'US locale default should pre-select Pounds (lb).',
      );
      final kgSemantics =
          tester.getSemantics(find.bySemanticsLabel('Kilograms (kg)'));
      expect(kgSemantics.hasFlag(SemanticsFlag.isSelected), isFalse);
    },
  );

  testWidgets(
    'GB locale selects Stones (st) by default',
    (tester) async {
      tester.view.physicalSize = const Size(414, 896);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final handle = tester.ensureSemantics();
      addTearDown(handle.dispose);

      final container = ProviderContainer(
        overrides: <Override>[
          localeDefaultWeightUnitProvider
              .overrideWithValue(WeightUnit.st),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_step2Harness(container: container));
      await tester.pump();

      final stSemantics =
          tester.getSemantics(find.bySemanticsLabel('Stones (st)'));
      expect(
        stSemantics.hasFlag(SemanticsFlag.isSelected),
        isTrue,
        reason: 'GB locale default should pre-select Stones (st).',
      );
    },
  );

  testWidgets(
    '(b) tapping a segment updates the draft.weightUnit',
    (tester) async {
      tester.view.physicalSize = const Size(414, 896);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = ProviderContainer(
        overrides: <Override>[
          // Start from `kg` so the tap to `lb` is observable.
          localeDefaultWeightUnitProvider
              .overrideWithValue(WeightUnit.kg),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_step2Harness(container: container));
      await tester.pump();

      // Draft starts with no explicit unit.
      expect(container.read(onboardingDraftProvider).weightUnit, isNull);

      // Tap the lb segment.
      await tester.tap(find.text('Pounds (lb)'));
      await tester.pump();

      // Draft now carries the explicit user choice.
      expect(
        container.read(onboardingDraftProvider).weightUnit,
        WeightUnit.lb,
      );
      // And the derived provider reflects it.
      expect(
        container.read(onboardingWeightUnitProvider),
        WeightUnit.lb,
      );
    },
  );

  testWidgets(
    '(c) WeightStepper renders the active unit suffix after a tap',
    (tester) async {
      tester.view.physicalSize = const Size(414, 896);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = ProviderContainer(
        overrides: <Override>[
          localeDefaultWeightUnitProvider
              .overrideWithValue(WeightUnit.kg),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_step2Harness(container: container));
      await tester.pump();

      // Initially the kg suffix is rendered by the stepper inner cell.
      // (The chooser label `Kilograms (kg)` also contains "kg", so
      // count is >=1; we just need the suffix to be visible.)
      expect(find.text('kg'), findsWidgets);

      // Tap Pounds (lb): the WeightStepper should rebuild in lb mode
      // and render the `lb` suffix as a standalone Text.
      await tester.tap(find.text('Pounds (lb)'));
      await tester.pump();

      expect(
        find.text('lb'),
        findsWidgets,
        reason: 'WeightStepper should render the lb suffix after the '
            'unit chooser flips to Pounds.',
      );
    },
  );

  testWidgets(
    '(d) finishing onboarding PATCHes UserPatch.weightUnit with the picked unit',
    (tester) async {
      tester.view.physicalSize = const Size(414, 896);
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
        ],
      );
      addTearDown(container.dispose);

      // Pre-fill the draft so step 3's commit path passes its gate,
      // and explicitly set the weight unit to `lb`.
      container.read(onboardingDraftProvider.notifier)
        ..setSex(Sex.male)
        ..setBirthDate(DateTime(1990, 6, 1))
        ..setHeightCm(Decimal.parse('180'))
        ..setCurrentWeightKg(Decimal.parse('80'))
        ..setActivityLevel(ActivityLevel.moderate)
        ..setDirection(GoalDirection.lose)
        ..setRateKgPerWeek(Decimal.parse('0.5'))
        ..setWeightUnit(WeightUnit.lb);

      await tester.pumpWidget(
        _onboardingHarness(step: 3, container: container),
      );
      await tester.pump();

      await tester.tap(find.text('Start logging'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        fakeProfile.lastPatch?.weightUnit,
        WeightUnit.lb,
        reason: 'The chosen unit must travel on the UserPatch.',
      );
    },
  );

  testWidgets(
    '(e) null draft.weightUnit + locale default still PATCHes a non-null weight_unit',
    (tester) async {
      tester.view.physicalSize = const Size(414, 896);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fakeProfile = _FakeProfileRepository();
      final fakeGoal = _FakeGoalRepository();

      final container = ProviderContainer(
        overrides: <Override>[
          profileRepositoryProvider.overrideWithValue(fakeProfile),
          goalRepositoryProvider.overrideWithValue(fakeGoal),
          // Note: this only overrides the read side of
          // `onboardingWeightUnitProvider`. The submit path reads
          // `defaultWeightUnitForLocale()` directly — but the assertion
          // here just checks "non-null", so the platform-dispatcher
          // value (whatever it is) suffices.
          localeDefaultWeightUnitProvider
              .overrideWithValue(WeightUnit.kg),
        ],
      );
      addTearDown(container.dispose);

      // Pre-fill the draft WITHOUT calling setWeightUnit. The draft's
      // `weightUnit` stays null; the submit path must fall back.
      container.read(onboardingDraftProvider.notifier)
        ..setSex(Sex.female)
        ..setBirthDate(DateTime(1992, 3, 14))
        ..setHeightCm(Decimal.parse('170'))
        ..setCurrentWeightKg(Decimal.parse('65'))
        ..setActivityLevel(ActivityLevel.light)
        ..setDirection(GoalDirection.maintain);

      // Sanity: the draft really has no explicit unit.
      expect(
        container.read(onboardingDraftProvider).weightUnit,
        isNull,
      );

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
        fakeProfile.lastPatch?.weightUnit,
        isNotNull,
        reason: 'Submit must fall back to defaultWeightUnitForLocale() '
            'when the draft has no explicit unit.',
      );
    },
  );
}
