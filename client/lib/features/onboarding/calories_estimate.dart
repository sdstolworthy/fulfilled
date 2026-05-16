import 'package:decimal/decimal.dart';

import '../../domain/enums.dart';

/// Mifflin-St Jeor BMR + activity-multiplier TDEE + goal-rate adjustment.
///
/// **Where this should live long-term.** Per architecture appendix the
/// canonical home is `lib/domain/calories/estimate.dart` (called out as a
/// gotcha in §9 screen 09: "Fence the calculation in one place"). The
/// foundation pass has not landed that file yet, so we co-locate it inside
/// the onboarding feature for v1 and flag it for lift.
///
/// **Lift checklist (when promoting):**
///   1. Move this file to `client/lib/domain/calories/estimate.dart`.
///   2. Update the single import in `widgets/step_3_goal.dart`.
///   3. Delete this copy.
/// Nothing else depends on it.
///
/// **Why these formulas.** Mifflin-St Jeor is the de-facto modern BMR
/// formula (more accurate than Harris-Benedict on contemporary
/// populations, used by the Mayo Clinic + the ADA). The architecture
/// brief leaves the choice to "whichever the backend uses — confirm in
/// section 10"; section 10 hasn't been finalised on the server side, so
/// we go with Mifflin-St Jeor and document the choice. When the backend
/// confirms, this file changes in one place.
///
/// ## Mifflin-St Jeor BMR
///
/// ```
/// BMR_male   = 10·kg + 6.25·cm − 5·age + 5
/// BMR_female = 10·kg + 6.25·cm − 5·age − 161
/// BMR_other  = average of the two (no biometric guidance; the
///              difference is small and predictable)
/// ```
///
/// Age is integer years at the calculation date; the standard formulas
/// take a single integer here, not fractional age.
///
/// ## Activity multipliers (standard Mifflin-St Jeor bands)
///
/// | Level           | Multiplier |
/// |-----------------|------------|
/// | sedentary       | 1.2        |
/// | light           | 1.375      |
/// | moderate        | 1.55       |
/// | active          | 1.725      |
/// | veryActive      | 1.9        |
///
/// ## Goal adjustment
///
/// A 1 kg/week deficit/surplus ≈ 7700 kcal/week ≈ 1100 kcal/day. The
/// goal `rateKgPerWeek` is signed by direction:
///   - lose: subtract `rate × 1100` from TDEE
///   - gain: add `rate × 1100` to TDEE
///   - maintain: no adjustment (rate ignored)
///
/// ## Rounding quirks (must match the server)
///
/// The wire `Goal.daily_calorie_target` is an `int` (per OpenAPI), so the
/// estimate is rounded to an integer at the seam. **We round half-up to
/// the nearest integer** via `Decimal.round(scale: 0).toBigInt()`. The
/// server is expected to use the same rule (its presumed
/// implementation: `(bmr * activity).round()` in Rust, which is
/// half-to-even by default — close enough that a single-unit drift won't
/// be user-visible, but flagged for the server agent to harmonise).
///
/// We also clamp at a floor of **1200 kcal** (women's safe minimum per
/// NIH guidance; the server is expected to enforce the same floor when
/// it computes its own value). The clamp prevents a "lose 1 kg/week +
/// tiny petite female" combo from producing a dangerously low target.
class CalorieEstimate {
  const CalorieEstimate({
    required this.bmrKcal,
    required this.tdeeKcal,
    required this.dailyTargetKcal,
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
  });

  /// Basal metabolic rate, rounded half-up.
  final int bmrKcal;

  /// Total daily energy expenditure (BMR × activity multiplier).
  final int tdeeKcal;

  /// Final calorie target after the goal-rate adjustment + 1200 floor.
  /// This is the integer that gets POSTed to `/goals` as
  /// `daily_calorie_target`.
  final int dailyTargetKcal;

  /// Macro splits derived from `dailyTargetKcal` with the default v1
  /// macro percentages (P 25% / C 50% / F 25%). The split is on energy,
  /// not grams: 4 kcal/g for protein and carbs, 9 kcal/g for fat. Rounded
  /// to integer grams (T-17 rule: Decimal in, formatted at the leaf).
  final int proteinG;
  final int carbsG;
  final int fatG;
}

/// Floor enforced on the final daily target. See file docstring.
const int kCalorieFloorKcal = 1200;

/// Calories per kg of body weight per week (loose anchor of the 7700 kcal/kg
/// rule of thumb). Used to translate a kg/week rate into a kcal/day delta.
const double _kKcalPerKgPerWeek = 7700.0;

const Map<ActivityLevel, double> _activityMultipliers = <ActivityLevel, double>{
  ActivityLevel.sedentary: 1.2,
  ActivityLevel.light: 1.375,
  ActivityLevel.moderate: 1.55,
  ActivityLevel.active: 1.725,
  ActivityLevel.veryActive: 1.9,
};

/// Integer years from [birthDate] to [today] (inclusive of today). Matches
/// the standard age-calc the BMR formulas assume.
int ageInYears(DateTime birthDate, DateTime today) {
  var years = today.year - birthDate.year;
  final hadBirthdayThisYear = (today.month > birthDate.month) ||
      (today.month == birthDate.month && today.day >= birthDate.day);
  if (!hadBirthdayThisYear) years -= 1;
  return years;
}

/// Round half-up to integer. We use this everywhere a Decimal becomes an
/// int — matches the architecture comment "round on the client the same
/// way the server rounds". (The Decimal package's default rounding mode
/// is half-up.)
int _roundHalfUp(double value) {
  // Use Decimal to avoid the IEEE-754 banker's-rounding surprise on `.round()`
  // for values like 0.5 / 1.5 / 2.5.
  return Decimal.parse(value.toString()).round(scale: 0).toBigInt().toInt();
}

/// Compute BMR via Mifflin-St Jeor. All inputs are required — the caller
/// (step 3) gates on `OnboardingDraft.isStep2Complete` before invoking.
int _bmr({
  required Sex sex,
  required double weightKg,
  required double heightCm,
  required int ageYears,
}) {
  final base = 10 * weightKg + 6.25 * heightCm - 5 * ageYears;
  final adjusted = switch (sex) {
    Sex.male => base + 5,
    Sex.female => base - 161,
    // `other` is the average of male and female offsets ((5 + −161) / 2 = −78).
    // Defensive: there's no clinical guidance here; the difference between
    // sexes in Mifflin-St Jeor is small (166 kcal), and splitting the
    // difference is the least-wrong default without asking for biometric
    // data we don't store.
    Sex.other => base - 78,
  };
  return _roundHalfUp(adjusted);
}

/// Full estimate. [now] is the clock used for age math — tests pin it.
///
/// Returns `null` when any required field on the draft is missing
/// (caller checks `OnboardingDraft.isStep2Complete` first; the null
/// here is belt-and-braces).
CalorieEstimate? estimateCalories({
  required Sex? sex,
  required DateTime? birthDate,
  required Decimal? heightCm,
  required Decimal? weightKg,
  required ActivityLevel? activityLevel,
  required GoalDirection? direction,
  required Decimal? rateKgPerWeek,
  DateTime? now,
}) {
  if (sex == null ||
      birthDate == null ||
      heightCm == null ||
      weightKg == null ||
      activityLevel == null ||
      direction == null) {
    return null;
  }

  final clock = now ?? DateTime.now();
  final age = ageInYears(birthDate, clock);

  final bmr = _bmr(
    sex: sex,
    weightKg: weightKg.toDouble(),
    heightCm: heightCm.toDouble(),
    ageYears: age,
  );

  final multiplier = _activityMultipliers[activityLevel] ?? 1.2;
  final tdee = _roundHalfUp(bmr * multiplier);

  // Goal-rate adjustment. `rateKgPerWeek` is unsigned on the draft;
  // direction carries the sign (lose → negative, gain → positive, maintain
  // → zero regardless of rate).
  double deltaKcal = 0;
  if (direction != GoalDirection.maintain && rateKgPerWeek != null) {
    final rate = rateKgPerWeek.toDouble();
    final perDay = rate * _kKcalPerKgPerWeek / 7.0;
    deltaKcal = direction == GoalDirection.lose ? -perDay : perDay;
  }

  final target = _roundHalfUp(tdee + deltaKcal);
  final clamped = target < kCalorieFloorKcal ? kCalorieFloorKcal : target;

  // Macro split. Defaults are P 25% / C 50% / F 25% on energy. Architecture
  // doesn't pin the exact ratio; this is a defensible v1 default and the
  // user can later edit the goal screen-side to adjust.
  final proteinKcal = clamped * 0.25;
  final carbsKcal = clamped * 0.50;
  final fatKcal = clamped * 0.25;

  return CalorieEstimate(
    bmrKcal: bmr,
    tdeeKcal: tdee,
    dailyTargetKcal: clamped,
    proteinG: _roundHalfUp(proteinKcal / 4.0),
    carbsG: _roundHalfUp(carbsKcal / 4.0),
    fatG: _roundHalfUp(fatKcal / 9.0),
  );
}
