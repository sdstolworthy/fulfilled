import 'package:decimal/decimal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/calories/estimate.dart';
import '../../domain/goal.dart';
import '../../providers/goal_providers.dart';
import '../../providers/log_providers.dart';
import '../../providers/profile_providers.dart';
import '../../providers/repository_providers.dart';
import '../../repositories/goal_repository.dart';

/// Recompute the active goal's daily kcal target + macros against
/// the freshly-PATCHed profile and write the result back via
/// `PATCH /goals/:id`. Call after any profile mutation that feeds
/// `estimateCalories` (activity level, current weight, height,
/// birth date, sex) so the goal doesn't silently fall out of sync
/// with the user's stats.
///
/// Direction + rate come off the active goal itself — the user's
/// chosen weekly rate isn't a profile field, so changing activity
/// must not change the rate.
///
/// Bails (no-op, no throw) when:
/// - no active goal exists (`GoalNotFoundError`);
/// - any required estimator input is still missing (profile is
///   not yet ready to drive a goal);
/// - the recomputed target matches the stored value (avoids a
///   noisy PATCH per repeat save of the same picker value);
/// - the goal repo throws — recompute is best-effort and shouldn't
///   block the profile-save flow. The picker has already returned
///   success to the user.
///
/// On success, invalidates `activeGoalProvider`, `goalsProvider`,
/// and today's `daySummaryProvider` so the dashboard ring / macro
/// bars + weight summary reflect the new target on next paint.
///
/// The function assumes `meProvider` has been invalidated by the
/// caller already (every Profile picker does this). The
/// `read(meProvider.future)` below then resolves against the
/// fresh `/me` response.
Future<void> recomputeActiveGoalAfterProfileChange(WidgetRef ref) async {
  final user = await ref.read(meProvider.future);

  final Goal active;
  try {
    active = await ref.read(activeGoalProvider.future);
  } on GoalNotFoundError {
    return;
  } catch (_) {
    return;
  }

  final estimate = estimateCalories(
    sex: user.sex,
    birthDate: user.birthDate,
    heightCm: user.heightCm,
    weightKg: user.currentWeightKg,
    activityLevel: user.activityLevel,
    direction: active.direction,
    rateKgPerWeek: active.rateKgPerWeek ?? Decimal.zero,
  );
  if (estimate == null) return;
  if (estimate.dailyTargetKcal == active.dailyCalorieTarget) return;

  try {
    final goalRepo = ref.read(goalRepositoryProvider);
    await goalRepo.update(
      active.copyWith(
        dailyCalorieTarget: estimate.dailyTargetKcal,
        proteinTargetG: Decimal.fromInt(estimate.proteinG),
        carbsTargetG: Decimal.fromInt(estimate.carbsG),
        fatTargetG: Decimal.fromInt(estimate.fatG),
      ),
    );
  } catch (_) {
    return;
  }

  ref.invalidate(activeGoalProvider);
  ref.invalidate(goalsProvider);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  ref.invalidate(daySummaryProvider(today));
}
