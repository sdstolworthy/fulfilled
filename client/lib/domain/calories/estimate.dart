import 'package:decimal/decimal.dart';

import '../_rounding.dart';
import '../enums.dart';

/// Mifflin-St Jeor BMR + activity-multiplier TDEE + goal-rate adjustment.
///
/// **Canonical home** for the calorie-target math (per architecture appendix
/// §A4). This file is the single seam: onboarding step 3 consumes
/// [estimateCalories] for its rich preview block; the goals editor and any
/// other surface that needs only the integer target should consume
/// [estimateDailyTarget].
///
/// **Why these formulas.** Mifflin-St Jeor is the de-facto modern BMR
/// formula (more accurate than Harris-Benedict on contemporary
/// populations, used by the Mayo Clinic + the ADA). When/if the backend
/// confirms a different formula in §10, this file changes in one place.
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
///   - lose: subtract `rate × 7700 / 7` from TDEE
///   - gain: add `rate × 7700 / 7` to TDEE
///   - maintain: no adjustment (rate ignored)
///
/// ## Rounding (must match the server)
///
/// The wire `Goal.daily_calorie_target` is an `int` (per OpenAPI), so the
/// estimate is rounded to an integer at the seam. We round **half-to-even**
/// (banker's rounding) per PM §10 #9 — this matches Rust's `f64::round()`
/// behavior on the server so client and server produce identical integers
/// given the same inputs.
///
/// We also clamp at a floor of **1200 kcal** (women's safe minimum per
/// NIH guidance; the server is expected to enforce the same floor when
/// it computes its own value). The clamp prevents a "lose 1 kg/week +
/// tiny petite female" combo from producing a dangerously low target.
///
/// ## Tenants
///
/// - **T-17 (Decimal in, formatted out)**: all internal math is `Decimal`;
///   the only `int`s on the public surface are the final
///   half-to-even-rounded results.
class CalorieEstimate {
  const CalorieEstimate({
    required this.bmrKcal,
    required this.tdeeKcal,
    required this.dailyTargetKcal,
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
  });

  /// Basal metabolic rate, rounded half-to-even.
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
final Decimal _kKcalPerKgPerWeek = Decimal.parse('7700');

/// Days-per-week divisor used to translate the weekly kcal delta into a
/// per-day kcal delta. Stays `Decimal` to keep the math out of IEEE-754.
final Decimal _kDaysPerWeek = Decimal.fromInt(7);

/// Activity multipliers parsed from string literals to keep the exact
/// decimal value (and to stay aligned with the "Decimal everywhere" rule).
final Map<ActivityLevel, Decimal> _activityMultipliers = <ActivityLevel, Decimal>{
  ActivityLevel.sedentary: Decimal.parse('1.2'),
  ActivityLevel.light: Decimal.parse('1.375'),
  ActivityLevel.moderate: Decimal.parse('1.55'),
  ActivityLevel.active: Decimal.parse('1.725'),
  ActivityLevel.veryActive: Decimal.parse('1.9'),
};

/// Mifflin-St Jeor offset by sex. `other` is the midpoint of the male
/// (+5) and female (−161) offsets — see file docstring.
final Map<Sex, Decimal> _sexOffset = <Sex, Decimal>{
  Sex.male: Decimal.fromInt(5),
  Sex.female: Decimal.fromInt(-161),
  Sex.other: Decimal.fromInt(-78),
};

final Decimal _ten = Decimal.fromInt(10);
final Decimal _five = Decimal.fromInt(5);
final Decimal _sixTwoFive = Decimal.parse('6.25');

/// Integer years from [birthDate] to [today] (inclusive of today). Matches
/// the standard age-calc the BMR formulas assume.
int ageInYears(DateTime birthDate, DateTime today) {
  var years = today.year - birthDate.year;
  final hadBirthdayThisYear = (today.month > birthDate.month) ||
      (today.month == birthDate.month && today.day >= birthDate.day);
  if (!hadBirthdayThisYear) years -= 1;
  return years;
}

/// Compute BMR via Mifflin-St Jeor. Returns the unrounded `Decimal` so
/// the caller can roll the rounding into the TDEE step if it wants the
/// minimum-error chain; we round once here too so the public
/// [CalorieEstimate.bmrKcal] is half-to-even per the contract.
Decimal _bmrDecimal({
  required Sex sex,
  required Decimal weightKg,
  required Decimal heightCm,
  required int ageYears,
}) {
  final base = (_ten * weightKg) +
      (_sixTwoFive * heightCm) -
      (_five * Decimal.fromInt(ageYears));
  return base + (_sexOffset[sex] ?? Decimal.zero);
}

/// Full estimate. [now] is the clock used for age math — tests pin it.
///
/// Returns `null` when any required field is missing (caller checks
/// `OnboardingDraft.isStep2Complete` first; the null here is
/// belt-and-braces).
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

  final bmrDecimal = _bmrDecimal(
    sex: sex,
    weightKg: weightKg,
    heightCm: heightCm,
    ageYears: age,
  );
  final bmr = roundHalfToEven(bmrDecimal);

  final multiplier = _activityMultipliers[activityLevel] ??
      _activityMultipliers[ActivityLevel.sedentary]!;
  // TDEE: BMR × multiplier. We keep BMR in `Decimal` form (not rounded
  // first) to minimise the chain rounding error — the public `bmrKcal`
  // is still rounded for display, but TDEE is computed from the
  // exact BMR.
  final tdeeDecimal = bmrDecimal * multiplier;
  final tdee = roundHalfToEven(tdeeDecimal);

  // Goal-rate adjustment. `rateKgPerWeek` is unsigned on the draft;
  // direction carries the sign (lose → negative, gain → positive,
  // maintain → zero regardless of rate).
  Decimal deltaKcal = Decimal.zero;
  if (direction != GoalDirection.maintain && rateKgPerWeek != null) {
    final perDay = (rateKgPerWeek * _kKcalPerKgPerWeek) / _kDaysPerWeek;
    // `/` on Decimal returns Rational in 3.x; coerce to Decimal at a
    // safe scale. 6 fractional digits is plenty for kcal-precision
    // intermediate; the final rounding is half-to-even at scale 0.
    final perDayDecimal = perDay.toDecimal(scaleOnInfinitePrecision: 12);
    deltaKcal = direction == GoalDirection.lose
        ? Decimal.zero - perDayDecimal
        : perDayDecimal;
  }

  final rawTarget = tdeeDecimal + deltaKcal;
  final targetInt = roundHalfToEven(rawTarget);
  final clamped = targetInt < kCalorieFloorKcal ? kCalorieFloorKcal : targetInt;

  // Macro split. Defaults are P 25% / C 50% / F 25% on energy. The
  // ratio is not architecture-pinned; this is a defensible v1 default
  // and the user can later edit the goal to adjust.
  final clampedDecimal = Decimal.fromInt(clamped);
  final proteinKcal = clampedDecimal * Decimal.parse('0.25');
  final carbsKcal = clampedDecimal * Decimal.parse('0.50');
  final fatKcal = clampedDecimal * Decimal.parse('0.25');

  final four = Decimal.fromInt(4);
  final nine = Decimal.fromInt(9);

  return CalorieEstimate(
    bmrKcal: bmr,
    tdeeKcal: tdee,
    dailyTargetKcal: clamped,
    proteinG: roundHalfToEven(
      (proteinKcal / four).toDecimal(scaleOnInfinitePrecision: 12),
    ),
    carbsG: roundHalfToEven(
      (carbsKcal / four).toDecimal(scaleOnInfinitePrecision: 12),
    ),
    fatG: roundHalfToEven(
      (fatKcal / nine).toDecimal(scaleOnInfinitePrecision: 12),
    ),
  );
}

/// Convenience wrapper returning only the integer daily target (the
/// value that gets POSTed to `/goals` as `daily_calorie_target`).
///
/// Returns `null` if any required field is missing — mirrors
/// [estimateCalories]'s belt-and-braces contract.
///
/// Use this when the caller only needs the int and doesn't care about
/// the full `CalorieEstimate` (BMR / TDEE / macros). Onboarding step 3
/// uses the full value type; the goals editor (T-010) and the burned
/// provider (B8) will use this.
int? estimateDailyTarget({
  required Sex? sex,
  required DateTime? birthDate,
  required Decimal? heightCm,
  required Decimal? weightKg,
  required ActivityLevel? activityLevel,
  required GoalDirection? direction,
  required Decimal? rateKgPerWeek,
  DateTime? now,
}) {
  final estimate = estimateCalories(
    sex: sex,
    birthDate: birthDate,
    heightCm: heightCm,
    weightKg: weightKg,
    activityLevel: activityLevel,
    direction: direction,
    rateKgPerWeek: rateKgPerWeek,
    now: now,
  );
  return estimate?.dailyTargetKcal;
}
