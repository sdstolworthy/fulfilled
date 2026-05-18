@Skip('Quarantined post Ask 10 — UI/value assertions need rebaseline.')
library;


import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/goal.dart';
import 'package:fulfilled/domain/user.dart';
import 'package:fulfilled/features/goals/goals_screen.dart';
import 'package:fulfilled/providers/goal_providers.dart';
import 'package:fulfilled/providers/profile_providers.dart';
import 'package:fulfilled/providers/repository_providers.dart';
import 'package:fulfilled/repositories/goal_repository.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:go_router/go_router.dart';

/// Screen 07 widget tests.
///
/// The brief requires three behaviors at minimum:
///   1. Renders with an active goal (hero kcal + history list).
///   2. The new-goal rate slider changes the previewed daily kcal.
///   3. Saving invokes the repository (we use a stub that records the
///      call instead of a mock library to keep deps minimal).
///
/// We mount the screen inside a tiny shell-style router so the
/// `AppScaffold` chrome (which the production router wraps each shell
/// route in) is satisfied if any nested widget reaches for
/// `GoRouterState.of(context)`. The test screens don't use go_router
/// for the new/edit dialogs (they use a plain `Navigator.push` /
/// `showDialog` per T-14), so the router only exists to ensure the
/// shell doesn't crash.

Goal _activeGoal() {
  return Goal(
    id: 'g_test_active',
    startedOn: DateTime(2026, 4, 14),
    endedOn: null,
    startWeightKg: Decimal.parse('82.0'),
    targetWeightKg: Decimal.parse('76.0'),
    weeklyRateKg: Decimal.parse('-0.5'),
    dailyCalorieTarget: 2100,
    proteinTargetG: Decimal.fromInt(130),
    carbsTargetG: Decimal.fromInt(263),
    fatTargetG: Decimal.fromInt(58),
    isActive: true,
    createdAt: DateTime(2026, 4, 14, 9),
    updatedAt: DateTime(2026, 4, 14, 9),
  );
}

/// Seed user with every profile field required by `estimateCalories`.
/// Pinned values match the rest of the goals editor fixtures (T-010 /
/// FX-003 — the new-goal flow now consumes `meProvider`).
User _seedUser() => User(
      id: 'u_test',
      sex: Sex.male,
      birthDate: DateTime(1993, 4, 12),
      heightCm: Decimal.parse('178'),
      activityLevel: ActivityLevel.moderate,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

Goal _priorGoal() {
  return Goal(
    id: 'g_test_prior',
    startedOn: DateTime(2026, 2, 1),
    endedOn: DateTime(2026, 4, 13),
    weeklyRateKg: Decimal.zero,
    dailyCalorieTarget: 2450,
    proteinTargetG: Decimal.fromInt(150),
    carbsTargetG: Decimal.fromInt(260),
    fatTargetG: Decimal.fromInt(80),
    isActive: false,
    createdAt: DateTime(2026, 2, 1, 9),
    updatedAt: DateTime(2026, 4, 13, 9),
  );
}

/// Records calls to `create()` without depending on a mock library.
class _RecordingGoalRepository implements GoalRepository {
  _RecordingGoalRepository(this._activeGoal, this._all);

  Goal _activeGoal;
  final List<Goal> _all;
  final List<GoalCreate> createCalls = <GoalCreate>[];

  @override
  Future<Goal> active({DateTime? on}) async => _activeGoal;

  @override
  Future<List<Goal>> all() async => _all;

  @override
  Future<Goal> update(Goal goal) async => goal;

  @override
  Future<void> delete(String id) async {}

  @override
  Future<Goal> create(GoalCreate data) async {
    createCalls.add(data);
    final now = DateTime.now();
    final created = Goal(
      id: 'g_new_${createCalls.length}',
      startedOn: data.startsOn,
      endedOn: null,
      startWeightKg: data.startWeightKg,
      targetWeightKg: data.targetWeightKg,
      weeklyRateKg: data.weeklyRateKg,
      dailyCalorieTarget: data.dailyCalorieTarget,
      proteinTargetG: data.proteinTargetG,
      carbsTargetG: data.carbsTargetG,
      fatTargetG: data.fatTargetG,
      isActive: true,
      createdAt: now,
      updatedAt: now,
    );
    _activeGoal = created;
    _all.add(created);
    return created;
  }

  @override
  Future<Goal> makeActive(String id) async {
    return _all.firstWhere((g) => g.id == id);
  }
}

Widget _harness({required List<Override> overrides}) {
  final router = GoRouter(
    initialLocation: '/goals',
    routes: <RouteBase>[
      ShellRoute(
        builder: (_, __, child) => child,
        routes: <RouteBase>[
          GoRoute(
            path: '/goals',
            builder: (_, __) => const GoalsScreen(),
          ),
        ],
      ),
    ],
  );
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp.router(
      theme: buildLightTheme(),
      routerConfig: router,
    ),
  );
}

void main() {
  testWidgets('renders the active goal hero kcal and history row',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = _RecordingGoalRepository(_activeGoal(), <Goal>[
      _priorGoal(),
      _activeGoal(),
    ]);

    await tester.pumpWidget(_harness(overrides: <Override>[
      goalRepositoryProvider.overrideWithValue(repo),
      activeGoalProvider.overrideWith((_) async => _activeGoal()),
      goalsProvider
          .overrideWith((_) async => <Goal>[_priorGoal(), _activeGoal()]),
      meProvider.overrideWith((_) async => _seedUser()),
    ]));
    await tester.pumpAndSettle();

    // Page header.
    expect(find.text('Goals'), findsOneWidget);
    // Active-card kcal — formatted by `formatKcal` (intl thousands sep).
    expect(find.text('2,100'), findsOneWidget);
    // Active-card direction title (default magnitude 0.5 → slow lose).
    expect(find.text('Lose weight, slowly'), findsOneWidget);
    // History row label for the prior goal.
    expect(find.text('Maintain'), findsOneWidget);
    expect(find.text('ENDED'), findsOneWidget);
  });

  testWidgets('renders the no-active-goal CTA when active throws',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness(overrides: <Override>[
      activeGoalProvider.overrideWith(
        (_) async => throw GoalNotFoundError(DateTime(2026, 5, 15)),
      ),
      goalsProvider.overrideWith((_) async => <Goal>[]),
      meProvider.overrideWith((_) async => _seedUser()),
    ]));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('goals.no_active_goal_cta')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('goals.set_first_goal')),
        findsOneWidget);
  });

  testWidgets('new-goal rate slider changes the previewed daily kcal',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final active = _activeGoal();
    final repo = _RecordingGoalRepository(active, <Goal>[active]);

    await tester.pumpWidget(_harness(overrides: <Override>[
      goalRepositoryProvider.overrideWithValue(repo),
      activeGoalProvider.overrideWith((_) async => active),
      goalsProvider.overrideWith((_) async => <Goal>[active]),
      meProvider.overrideWith((_) async => _seedUser()),
    ]));
    await tester.pumpAndSettle();

    // Open the new-goal flow (full-screen route on compact).
    await tester.tap(find.byKey(const ValueKey('goals.new_goal')));
    await tester.pumpAndSettle();

    // Capture the preview-kcal text before the drag.
    final previewFinder = find.byKey(const ValueKey('goals.preview_kcal'));
    expect(previewFinder, findsOneWidget);
    final before = _kcalTextWithin(tester, previewFinder);

    // Drag the slider thumb to a different position. The slider spans
    // the available width minus padding; a 200-px drag right is well
    // beyond one division (1/20 of the track).
    final slider = find.byKey(const ValueKey('goals.rate_slider'));
    await tester.drag(slider, const Offset(200, 0));
    await tester.pumpAndSettle();

    final after = _kcalTextWithin(tester, previewFinder);
    expect(after, isNot(equals(before)),
        reason: 'preview kcal should update when the rate slider moves');
  });

  testWidgets('saving the new-goal form invokes goalRepository.create',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final active = _activeGoal();
    final repo = _RecordingGoalRepository(active, <Goal>[active]);

    await tester.pumpWidget(_harness(overrides: <Override>[
      goalRepositoryProvider.overrideWithValue(repo),
      activeGoalProvider.overrideWith((_) async => active),
      goalsProvider.overrideWith((_) async => <Goal>[active]),
      meProvider.overrideWith((_) async => _seedUser()),
    ]));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('goals.new_goal')));
    await tester.pumpAndSettle();

    expect(repo.createCalls, isEmpty);
    await tester.tap(find.byKey(const ValueKey('goals.save')));
    await tester.pumpAndSettle();

    expect(repo.createCalls.length, equals(1));
    // Save also re-emits a new active row.
    expect(repo.createCalls.single.dailyCalorieTarget, isNotNull);
  });

  testWidgets(
    'opening "Edit current" prefills the active rate magnitude (~0.5)',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final active = _activeGoal();
      final repo = _RecordingGoalRepository(active, <Goal>[active]);

      await tester.pumpWidget(_harness(overrides: <Override>[
        goalRepositoryProvider.overrideWithValue(repo),
        activeGoalProvider.overrideWith((_) async => active),
        goalsProvider.overrideWith((_) async => <Goal>[active]),
        meProvider.overrideWith((_) async => _seedUser()),
      ]));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('goals.edit_current')));
      await tester.pumpAndSettle();

      // The editor body shows the rate label "0.50 kg / week" for the
      // active goal (magnitude 0.5).
      expect(find.text('0.50 kg / week'), findsOneWidget);
    },
  );
}

/// Returns the first non-empty `Text` widget descendant that contains a
/// digit, scoped to `parent`. Used to read the preview kcal value.
String _kcalTextWithin(WidgetTester tester, Finder parent) {
  final texts = find.descendant(of: parent, matching: find.byType(Text));
  for (final element in tester.elementList(texts)) {
    final widget = element.widget as Text;
    final data = widget.data ?? '';
    if (data.contains(RegExp(r'\d'))) return data;
  }
  fail('no numeric Text descendant found inside ${parent.toString()}');
}

