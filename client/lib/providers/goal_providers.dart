import 'package:decimal/decimal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/calories/estimate.dart';
import '../domain/day_summary.dart';
import '../domain/goal.dart';
import 'profile_providers.dart';
import 'repository_providers.dart';
import 'weight_providers.dart';

/// Goal-domain providers. Screen 07's hero card binds to
/// [activeGoalProvider]; the history list binds to [goalsProvider].
///
/// **No-active-goal handling.** [activeGoalProvider] throws
/// [GoalNotFoundError] (from `goal_repository.dart`) when the caller has
/// no goal covering today. Screens that consume it should catch the
/// error in the `AsyncValue.when` `error` arm and render a "Set a goal"
/// affordance instead of bubbling. The day summary path swallows the
/// same error internally and renders the "Set a goal" affordance on
/// screen 01 via `DaySummary.kcalTarget == null`.

/// Currently-active goal. Throws `GoalNotFoundError` when the user has
/// never created a goal — see file docstring.
final activeGoalProvider = FutureProvider<Goal>((ref) {
  final repo = ref.watch(goalRepositoryProvider);
  return repo.active();
});

/// Every goal the user owns, newest started first. Screen 07's history
/// list filters this client-side.
final goalsProvider = FutureProvider<List<Goal>>((ref) {
  final repo = ref.watch(goalRepositoryProvider);
  return repo.all();
});

/// **Derived** today's-goal targets, computed from the user's current
/// profile and the active goal's intent (direction + weekly rate).
///
/// Today's UI reads this instead of [Goal.dailyCalorieTarget] so a
/// profile change (activity level, weight, height, birth date, sex)
/// flows through automatically: `meProvider` invalidates → this
/// provider rebuilds → consumers re-render. No imperative goal
/// PATCH cascade across pickers, no five-files-deep coupling.
///
/// Returns `null` when either upstream is missing — no active goal,
/// or profile incomplete (any of sex / birthDate / heightCm /
/// currentWeightKg / activityLevel still unset). Consumers fall back
/// to the stored [Goal.dailyCalorieTarget] (which is itself a
/// snapshot of the user's last explicit intent edit) or render the
/// "Set a goal" / "Finish your profile" affordances.
///
/// **Snapshot semantics on save.** The goal editor still PATCHes the
/// freshly-computed kcal target + macros into the goal record on a
/// user-initiated save. The stored value is a memoised snapshot of
/// the user's last explicit intent edit — used as a cold-start
/// fallback and to keep other clients reading the goal record in
/// sync — not as the live target. The live target is *this provider*.
///
/// Historical days (any date other than today) intentionally keep
/// reading the BE's `active_goal.daily_calorie_target` from
/// [daySummaryProvider]; that's the closest thing to a per-day
/// snapshot until the BE persists targets per `DayLog`. Live
/// overriding past days from today's derived value would be wrong —
/// the user logged against the number that was active at the time.
final effectiveActiveGoalTargetsProvider =
    Provider<CalorieEstimate?>((ref) {
  final user = ref.watch(meProvider).valueOrNull;
  final goal = ref.watch(activeGoalProvider).valueOrNull;
  final currentKg = ref.watch(currentWeightKgProvider).valueOrNull;
  if (user == null || goal == null) return null;
  return estimateCalories(
    sex: user.sex,
    birthDate: user.birthDate,
    heightCm: user.heightCm,
    weightKg: currentKg,
    activityLevel: user.activityLevel,
    direction: goal.direction,
    rateKgPerWeek: goal.rateKgPerWeek ?? Decimal.zero,
  );
});

/// Swap the BE-returned (stored, possibly stale) kcal + macro
/// targets on [summary] for the derived live values when one is
/// available. Caller is responsible for deciding *whether* to call
/// this — typically only for today's date; past days keep their
/// per-day historical snapshot from the BE. Returns [summary]
/// unchanged when [effective] is null.
DaySummary overrideDaySummaryWithEffective(
  DaySummary summary,
  CalorieEstimate? effective,
) {
  if (effective == null) return summary;
  return summary.copyWith(
    kcalTarget: Decimal.fromInt(effective.dailyTargetKcal),
    proteinTarget: Decimal.fromInt(effective.proteinG),
    carbsTarget: Decimal.fromInt(effective.carbsG),
    fatTarget: Decimal.fromInt(effective.fatG),
  );
}
