import 'package:decimal/decimal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/calories/estimate.dart';
import '../domain/enums.dart';
import 'profile_providers.dart';
import 'weight_providers.dart';

/// Calorie-derivation providers. Today's "Burned" row binds here.
///
/// **T-09 anchor — one source of truth for the burned number.** The
/// burned-kcal value is derived from the authenticated user's profile
/// (sex / age / height / current weight / activity level) via the
/// canonical TDEE math in `lib/domain/calories/estimate.dart`. There is
/// no separate `/activity` fetch — `meProvider` is the only upstream.
///
/// **Loading / error contract.** Per architect §B8 and PM B8: the
/// consumer renders a skeleton (T-08) while loading and falls back to
/// `'—'` silently on error so a fresh profile (no sex / no birthDate /
/// no height / no weight / no activity level) doesn't surface a stack
/// trace in the Today right rail.

/// Calories burned today, derived from the user's profile via the
/// canonical Mifflin-St Jeor TDEE math.
///
/// The "Burned" total is the user's maintenance TDEE — i.e. BMR plus
/// activity expenditure. Per the canonical [estimateCalories], TDEE =
/// BMR × activity-multiplier, which already encompasses both terms.
/// Equivalent to the user's daily calorie target if they were
/// maintaining (no goal-rate adjustment).
///
/// Returns `Decimal.zero` clamped if the math somehow produces a
/// negative value (shouldn't happen — TDEE ≥ BMR for every activity
/// band — belt-and-braces for the consumer).
///
/// Throws [_BurnedUnavailable] when the upstream profile is missing
/// any of the required inputs (sex, birthDate, heightCm,
/// currentWeightKg, activityLevel). The screen consumer catches the
/// error in the `AsyncValue.when` `error` arm and renders `'—'`
/// silently (don't surface).
final caloriesBurnedTodayProvider = FutureProvider<Decimal>((ref) async {
  final user = await ref.watch(meProvider.future);
  // Current weight is a derivation of the weight feed, not a field
  // on `User`. Awaiting the weight provider's future keeps this
  // computation purely declarative — a weight log invalidates
  // `weightHistoryProvider` and this provider recomputes.
  final currentKg = await ref.watch(currentWeightKgProvider.future);

  // `estimateCalories` is the single seam for BMR / TDEE math. We pass
  // `direction: maintain` + `rateKgPerWeek: 0` so no goal-rate delta
  // is applied — TDEE is what we want for "Burned".
  final estimate = estimateCalories(
    sex: user.sex,
    birthDate: user.birthDate,
    heightCm: user.heightCm,
    weightKg: currentKg,
    activityLevel: user.activityLevel,
    direction: GoalDirection.maintain,
    rateKgPerWeek: Decimal.zero,
  );

  if (estimate == null) {
    // Missing a required profile field — surface as error so the
    // consumer falls back to `'—'`. Don't return `Decimal.zero`,
    // which would render as "0 kcal" and be misleading.
    throw const _BurnedUnavailable();
  }

  final tdee = Decimal.fromInt(estimate.tdeeKcal);
  // Belt-and-braces clamp: TDEE ≥ BMR ≥ 0 for every supported
  // activity band, but a defensive non-negative guarantee keeps the
  // public contract honest.
  return tdee < Decimal.zero ? Decimal.zero : tdee;
});

/// Internal sentinel error indicating the user's profile is missing a
/// field required for the TDEE math. The Today screen consumer
/// catches this in `AsyncValue.when`'s `error` arm and renders `'—'`
/// silently — it is not a user-visible failure.
class _BurnedUnavailable implements Exception {
  const _BurnedUnavailable();
  @override
  String toString() => 'Burned unavailable: profile incomplete';
}
