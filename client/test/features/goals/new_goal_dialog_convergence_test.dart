// FX-003 — new-goal flow converges on `estimateCalories`.
//
// LU-010 rewired `edit_goal_sheet.dart` to consume the canonical
// Mifflin-St Jeor + macro-split helper in `lib/domain/calories/estimate.dart`.
// `new_goal_dialog.dart` kept its file-private `_macroGrams` / `_signedRate`
// helpers + a 2000-kcal-baseline shift as a deliberate v1.1 split — same
// formula, but not gated on LU-010. FX-003 finished the split: the
// new-goal flow now reads `meProvider` and delegates the math to
// `estimateCalories`, mirroring the edit-goal sheet.
//
// This file pins three behaviors:
//   1. Preview kcal at the default inputs matches the same kcal the
//      onboarding finish step would compute for the same direction +
//      rate (a direct equality against `estimateCalories(...)`).
//   2. Macros saved to the repository come straight off the
//      `CalorieEstimate` (i.e. the P 25% / C 50% / F 25% energy split
//      from `estimateCalories`), not the legacy `_macroGrams` helper
//      that hard-coded a kcal-share table.
//   3. While `meProvider` is loading, the preview block renders a
//      [Skeleton] — same affordance the edit-goal sheet uses (T-08).

import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/calories/estimate.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/goal.dart';
import 'package:fulfilled/domain/units/energy.dart';
import 'package:fulfilled/domain/user.dart';
import 'package:fulfilled/features/goals/widgets/new_goal_dialog.dart';
import 'package:fulfilled/providers/goal_providers.dart';
import 'package:fulfilled/providers/profile_providers.dart';
import 'package:fulfilled/providers/repository_providers.dart';
import 'package:fulfilled/repositories/goal_repository.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/skeleton.dart';

/// Seed user with every field `estimateCalories` requires. Same shape as
/// `goals_screen_test.dart`'s `_seedUser()` so the two test files agree
/// on the canonical FX-003 fixture: male / 178 cm / 79.4 kg / moderate
/// / DOB 1993-04-12.
User _seedUser() => User(
      id: 'u_test',
      sex: Sex.male,
      birthDate: DateTime(1993, 4, 12),
      heightCm: Decimal.parse('178'),
      currentWeightKg: Decimal.parse('79.4'),
      activityLevel: ActivityLevel.moderate,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

/// Records calls to `create()` without depending on a mock library.
/// Mirrors the helper in `goals_screen_test.dart`.
class _RecordingGoalRepository implements GoalRepository {
  final List<GoalCreate> createCalls = <GoalCreate>[];

  @override
  Future<Goal> active({DateTime? on}) async {
    throw GoalNotFoundError(on ?? DateTime(2026, 5, 16));
  }

  @override
  Future<List<Goal>> all() async => const <Goal>[];

  @override
  Future<Goal> create(GoalCreate data) async {
    createCalls.add(data);
    final now = DateTime.now();
    return Goal(
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
  }

  @override
  Future<Goal> makeActive(String id) async {
    throw UnimplementedError();
  }
}

/// Mounts the new-goal *screen* (full-screen variant) directly. The
/// shell-router-wrapped harness in `goals_screen_test.dart` opens the
/// screen via a Navigator tap; for FX-003 we mount the screen on its
/// own so the assertions target the editor without depending on the
/// goals-screen shell.
Widget _harness({
  required List<Override> overrides,
}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: buildLightTheme(),
      home: const NewGoalScreen(),
    ),
  );
}

void main() {
  testWidgets(
    'preview kcal at default inputs equals estimateCalories(lose, 0.5)',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = _RecordingGoalRepository();
      final user = _seedUser();

      await tester.pumpWidget(
        _harness(
          overrides: <Override>[
            goalRepositoryProvider.overrideWithValue(repo),
            meProvider.overrideWith((_) async => user),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // The seed defaults: lose / 0.5 kg/week (these are the values the
      // _NewGoalForm seeds when there's no template).
      final expected = estimateCalories(
        sex: user.sex,
        birthDate: user.birthDate,
        heightCm: user.heightCm,
        weightKg: user.currentWeightKg,
        activityLevel: user.activityLevel,
        direction: GoalDirection.lose,
        rateKgPerWeek: Decimal.parse('0.5'),
      );
      expect(expected, isNotNull,
          reason: 'seed user has all profile fields populated');

      // The preview hero renders the formatted kcal (with thousands
      // separator) — match the same formatter the widget uses.
      final expectedText =
          formatKcal(Decimal.fromInt(expected!.dailyTargetKcal));
      final previewFinder = find.byKey(const ValueKey('goals.preview_kcal'));
      expect(previewFinder, findsOneWidget);
      expect(
        find.descendant(of: previewFinder, matching: find.text(expectedText)),
        findsOneWidget,
        reason: 'preview kcal at default inputs must equal '
            'estimateCalories(...).dailyTargetKcal — the same value '
            'onboarding-finish would POST for these inputs',
      );
    },
  );

  testWidgets(
    'macros saved to the repository come from CalorieEstimate, '
    'not the legacy file-private split',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = _RecordingGoalRepository();
      final user = _seedUser();

      await tester.pumpWidget(
        _harness(
          overrides: <Override>[
            goalRepositoryProvider.overrideWithValue(repo),
            meProvider.overrideWith((_) async => user),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // Trigger save with the default direction + rate (lose / 0.5).
      await tester.tap(find.byKey(const ValueKey('goals.save')));
      await tester.pumpAndSettle();

      expect(repo.createCalls, hasLength(1));
      final saved = repo.createCalls.single;

      final expected = estimateCalories(
        sex: user.sex,
        birthDate: user.birthDate,
        heightCm: user.heightCm,
        weightKg: user.currentWeightKg,
        activityLevel: user.activityLevel,
        direction: GoalDirection.lose,
        rateKgPerWeek: Decimal.parse('0.5'),
      )!;

      // kcal target equality — pre-FX-003 this used a 2000-kcal baseline
      // shifted by 1100 × rate. Post-FX-003 it must equal the BMR /
      // activity / goal-rate chain in `estimateCalories`.
      expect(saved.dailyCalorieTarget, expected.dailyTargetKcal);

      // Macro equality — pre-FX-003 the dialog used a `_macroGrams(kcal,
      // share, kcalPerG)` helper that rounded a different decimal chain.
      // Post-FX-003 the integer grams come straight off the
      // CalorieEstimate's `proteinG / carbsG / fatG`.
      expect(saved.proteinTargetG, Decimal.fromInt(expected.proteinG));
      expect(saved.carbsTargetG, Decimal.fromInt(expected.carbsG));
      expect(saved.fatTargetG, Decimal.fromInt(expected.fatG));

      // weeklyRateKg encodes the direction's sign (lose ⇒ negative).
      expect(saved.weeklyRateKg, Decimal.parse('-0.5'));
    },
  );

  testWidgets(
    'meProvider loading state renders Skeleton in the preview block',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // A future that never resolves — keeps meProvider in `loading`.
      final never = Completer<User>();
      addTearDown(() {
        // Drain the future on teardown so Riverpod's internal listeners
        // don't outlive the test runtime.
        if (!never.isCompleted) never.complete(_seedUser());
      });

      final repo = _RecordingGoalRepository();

      await tester.pumpWidget(
        _harness(
          overrides: <Override>[
            goalRepositoryProvider.overrideWithValue(repo),
            meProvider.overrideWith((_) => never.future),
          ],
        ),
      );
      // Don't pumpAndSettle — meProvider is stuck loading by design.
      await tester.pump();

      // The preview block exists.
      final previewFinder = find.byKey(const ValueKey('goals.preview_kcal'));
      expect(previewFinder, findsOneWidget);

      // …and renders the kcal-hero Skeleton, not a numeric Text. The
      // skeleton's key (`goals.preview_kcal_skeleton`) is the
      // load-bearing affordance for T-08 — assert it directly.
      expect(
        find.byKey(const ValueKey('goals.preview_kcal_skeleton')),
        findsOneWidget,
        reason: 'while meProvider is loading the preview hero renders '
            'a Skeleton in place of the kcal number (T-08)',
      );
      // And the Skeleton type is in the preview block (defensive — the
      // ValueKey alone is enough but pinning the type guards against a
      // future refactor that renames the key).
      expect(
        find.descendant(of: previewFinder, matching: find.byType(Skeleton)),
        findsOneWidget,
      );
    },
  );
}
