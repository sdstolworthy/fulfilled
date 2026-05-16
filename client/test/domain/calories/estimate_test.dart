import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/calories/estimate.dart';
import 'package:fulfilled/domain/enums.dart';

/// Unit tests for the canonical calorie-target math (T-009 / A4).
///
/// Reference values are computed by hand from the Mifflin-St Jeor formula
/// + standard activity multiplier + 1 kg/wk ≈ 1100 kcal/day goal rule.
/// Each case below shows its derivation in a code comment so the
/// half-to-even rounding chain stays auditable.
///
/// All tests pin `now: DateTime(2026, 5, 16)` for deterministic age math.
void main() {
  final pinnedNow = DateTime(2026, 5, 16);

  group('ageInYears', () {
    test('returns full years when birthday already passed this year', () {
      // Born 1996-01-05, today 2026-05-16 → 30 years complete.
      expect(
        ageInYears(DateTime(1996, 1, 5), pinnedNow),
        30,
      );
    });

    test('decrements when birthday has not yet occurred this year', () {
      // Born 1996-12-31, today 2026-05-16 → 29 (birthday still ahead).
      expect(
        ageInYears(DateTime(1996, 12, 31), pinnedNow),
        29,
      );
    });

    test('birthday-today counts as the new year', () {
      // Born 1996-05-16, today 2026-05-16 → 30.
      expect(
        ageInYears(DateTime(1996, 5, 16), pinnedNow),
        30,
      );
    });
  });

  group('estimateCalories — reference Mifflin-St Jeor cases', () {
    test('male sedentary maintain @ 80 kg 180 cm 30y → 2136 kcal', () {
      // BMR = 10*80 + 6.25*180 - 5*30 + 5
      //     = 800 + 1125 - 150 + 5
      //     = 1780  (exact integer; rounds to 1780)
      // TDEE = 1780 * 1.2 = 2136 (exact integer)
      // Maintain → no goal adjustment → target = 2136
      final result = estimateCalories(
        sex: Sex.male,
        birthDate: DateTime(1996, 5, 16), // 30 on pinnedNow
        heightCm: Decimal.parse('180'),
        weightKg: Decimal.parse('80'),
        activityLevel: ActivityLevel.sedentary,
        direction: GoalDirection.maintain,
        rateKgPerWeek: Decimal.zero,
        now: pinnedNow,
      );

      expect(result, isNotNull);
      expect(result!.bmrKcal, 1780);
      expect(result.tdeeKcal, 2136);
      expect(result.dailyTargetKcal, 2136);
    });

    test('female active deficit @ 60 kg 165 cm 28y rate 0.5 → 1745 kcal', () {
      // BMR = 10*60 + 6.25*165 - 5*28 - 161
      //     = 600 + 1031.25 - 140 - 161
      //     = 1330.25  (frac .25 → rounds to 1330 for display)
      // TDEE (Decimal) = 1330.25 * 1.725 = 2294.68125 (rounds to 2295)
      // perDay delta = 0.5 * 7700 / 7 = 550
      // target raw = 2294.68125 - 550 = 1744.68125 → 1745 (frac .68125)
      final result = estimateCalories(
        sex: Sex.female,
        birthDate: DateTime(1998, 5, 16), // 28 on pinnedNow
        heightCm: Decimal.parse('165'),
        weightKg: Decimal.parse('60'),
        activityLevel: ActivityLevel.active,
        direction: GoalDirection.lose,
        rateKgPerWeek: Decimal.parse('0.5'),
        now: pinnedNow,
      );

      expect(result, isNotNull);
      expect(result!.bmrKcal, 1330);
      expect(result.tdeeKcal, 2295);
      expect(result.dailyTargetKcal, 1745);
    });

    test('returns null when any required field is missing', () {
      final result = estimateCalories(
        sex: null,
        birthDate: DateTime(1996, 5, 16),
        heightCm: Decimal.parse('180'),
        weightKg: Decimal.parse('80'),
        activityLevel: ActivityLevel.sedentary,
        direction: GoalDirection.maintain,
        rateKgPerWeek: Decimal.zero,
        now: pinnedNow,
      );
      expect(result, isNull);
    });
  });

  group('1200 kcal floor', () {
    test('clamps a small person at max rate to the safety floor', () {
      // 70-year-old, 45 kg, 150 cm, female, sedentary, lose 1.0 kg/wk.
      // BMR = 10*45 + 6.25*150 - 5*70 - 161
      //     = 450 + 937.5 - 350 - 161
      //     = 876.5
      // TDEE (Decimal) = 876.5 * 1.2 = 1051.8
      // perDay delta = 1.0 * 7700 / 7 = 1100
      // raw target = 1051.8 - 1100 = -48.2 → clamp to 1200.
      final result = estimateCalories(
        sex: Sex.female,
        birthDate: DateTime(1956, 5, 16), // 70 on pinnedNow
        heightCm: Decimal.parse('150'),
        weightKg: Decimal.parse('45'),
        activityLevel: ActivityLevel.sedentary,
        direction: GoalDirection.lose,
        rateKgPerWeek: Decimal.parse('1.0'),
        now: pinnedNow,
      );

      expect(result, isNotNull);
      expect(result!.dailyTargetKcal, kCalorieFloorKcal);
      expect(result.dailyTargetKcal, 1200);
    });

    test('exposes the floor as a public constant matching PM ruling', () {
      expect(kCalorieFloorKcal, 1200);
    });
  });

  group('half-to-even rounding at the .5 boundary (PM §10 #9)', () {
    test('1786.25 BMR × 1.2 = 2143.5 raw → rounds up to 2144 (even)', () {
      // weight 80, height 181, age 30, male, sedentary, maintain.
      // BMR = 800 + 1131.25 - 150 + 5 = 1786.25
      // TDEE raw = 1786.25 * 1.2 = 2143.5
      // maintain → target raw = 2143.5
      // Half-to-even: floor 2143 is ODD → round to nearest even = 2144.
      final result = estimateCalories(
        sex: Sex.male,
        birthDate: DateTime(1996, 5, 16),
        heightCm: Decimal.parse('181'),
        weightKg: Decimal.parse('80'),
        activityLevel: ActivityLevel.sedentary,
        direction: GoalDirection.maintain,
        rateKgPerWeek: Decimal.zero,
        now: pinnedNow,
      );

      expect(result, isNotNull);
      expect(
        result!.dailyTargetKcal,
        2144,
        reason: '2143.5 with floor=2143 (odd) rounds UP to even 2144',
      );
      expect(result.dailyTargetKcal.isEven, isTrue);
    });

    test('1798.75 BMR × 1.2 = 2158.5 raw → rounds down to 2158 (even)', () {
      // weight 80, height 183, age 30, male, sedentary, maintain.
      // BMR = 800 + 1143.75 - 150 + 5 = 1798.75
      // TDEE raw = 1798.75 * 1.2 = 2158.5
      // Half-to-even: floor 2158 is EVEN → stays at 2158.
      final result = estimateCalories(
        sex: Sex.male,
        birthDate: DateTime(1996, 5, 16),
        heightCm: Decimal.parse('183'),
        weightKg: Decimal.parse('80'),
        activityLevel: ActivityLevel.sedentary,
        direction: GoalDirection.maintain,
        rateKgPerWeek: Decimal.zero,
        now: pinnedNow,
      );

      expect(result, isNotNull);
      expect(
        result!.dailyTargetKcal,
        2158,
        reason: '2158.5 with floor=2158 (even) stays at even 2158',
      );
      expect(result.dailyTargetKcal.isEven, isTrue);
    });
  });

  group('estimateDailyTarget convenience wrapper', () {
    test('returns the same int as estimateCalories().dailyTargetKcal', () {
      // Round-trip: identical inputs → identical integer target.
      final args = <String, dynamic>{
        'sex': Sex.male,
        'birthDate': DateTime(1996, 5, 16),
        'heightCm': Decimal.parse('180'),
        'weightKg': Decimal.parse('80'),
        'activityLevel': ActivityLevel.sedentary,
        'direction': GoalDirection.maintain,
        'rateKgPerWeek': Decimal.zero,
        'now': pinnedNow,
      };

      final full = estimateCalories(
        sex: args['sex'] as Sex,
        birthDate: args['birthDate'] as DateTime,
        heightCm: args['heightCm'] as Decimal,
        weightKg: args['weightKg'] as Decimal,
        activityLevel: args['activityLevel'] as ActivityLevel,
        direction: args['direction'] as GoalDirection,
        rateKgPerWeek: args['rateKgPerWeek'] as Decimal,
        now: args['now'] as DateTime,
      );
      final target = estimateDailyTarget(
        sex: args['sex'] as Sex,
        birthDate: args['birthDate'] as DateTime,
        heightCm: args['heightCm'] as Decimal,
        weightKg: args['weightKg'] as Decimal,
        activityLevel: args['activityLevel'] as ActivityLevel,
        direction: args['direction'] as GoalDirection,
        rateKgPerWeek: args['rateKgPerWeek'] as Decimal,
        now: args['now'] as DateTime,
      );

      expect(full, isNotNull);
      expect(target, isNotNull);
      expect(target, full!.dailyTargetKcal);
    });

    test('returns null when a required field is missing', () {
      expect(
        estimateDailyTarget(
          sex: Sex.male,
          birthDate: null,
          heightCm: Decimal.parse('180'),
          weightKg: Decimal.parse('80'),
          activityLevel: ActivityLevel.sedentary,
          direction: GoalDirection.maintain,
          rateKgPerWeek: Decimal.zero,
          now: pinnedNow,
        ),
        isNull,
      );
    });
  });

  group('gain direction (sanity check)', () {
    test('adds the per-day delta for gain', () {
      // Male active gain @ 80 kg 180 cm 30y rate 0.5.
      // BMR = 1780; TDEE = 1780 * 1.725 = 3070.5 (half-to-even floor 3070
      //   even → 3070 for display); perDay = 0.5 * 7700 / 7 = 550.
      // raw target = 3070.5 + 550 = 3620.5 → floor 3620 (even) → 3620.
      final result = estimateCalories(
        sex: Sex.male,
        birthDate: DateTime(1996, 5, 16),
        heightCm: Decimal.parse('180'),
        weightKg: Decimal.parse('80'),
        activityLevel: ActivityLevel.active,
        direction: GoalDirection.gain,
        rateKgPerWeek: Decimal.parse('0.5'),
        now: pinnedNow,
      );

      expect(result, isNotNull);
      expect(result!.tdeeKcal, 3070);
      expect(result.dailyTargetKcal, 3620);
    });
  });
}
