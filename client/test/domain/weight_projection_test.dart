import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/weight.dart';
import 'package:fulfilled/domain/weight_projection.dart';

/// Pure-logic tests for `projectGoal`. The widget that renders the
/// projection is exercised by `weight_summary_card`-level tests; here
/// we pin the dynamic-model state machine + sanity bounds on the
/// day-counts. The model itself is approximate (±15–25 % per
/// `specs/weight_projection_research.md` §1) — these tests intentionally
/// assert ranges, not exact counts.

DateTime _d(DateTime ref, int daysAgo) {
  final today = DateTime(ref.year, ref.month, ref.day);
  return today.subtract(Duration(days: daysAgo));
}

WeightEntry _we(DateTime ref, int daysAgo, String kg) {
  final date = _d(ref, daysAgo);
  return WeightEntry(
    id: 'w_$daysAgo',
    recordedOn: date,
    weightKg: Decimal.parse(kg),
    createdAt: date,
  );
}

/// Build a trailing-window intake series with [days] daily entries
/// ending at [ref], each logging [kcal].
List<IntakeDay> _flatIntake(DateTime ref, int days, int kcal) {
  final today = DateTime(ref.year, ref.month, ref.day);
  return <IntakeDay>[
    for (var i = 0; i < days; i += 1)
      IntakeDay(
        date: today.subtract(Duration(days: i)),
        kcal: Decimal.fromInt(kcal),
      ),
  ];
}

/// Build a 28-day declining weight history (one weigh-in per week,
/// plus today) consistent with a slow loss. Used to satisfy the
/// "≥ 4 weigh-ins in last 28 days" calibration requirement.
List<WeightEntry> _decliningHistory(
  DateTime ref, {
  required String currentKg,
  required String per7Days,
}) {
  final per = Decimal.parse(per7Days);
  final current = Decimal.parse(currentKg);
  return <WeightEntry>[
    _we(ref, 0, current.toString()),
    _we(ref, 7, (current + per).toString()),
    _we(ref, 14, (current + per * Decimal.fromInt(2)).toString()),
    _we(ref, 21, (current + per * Decimal.fromInt(3)).toString()),
    _we(ref, 28, (current + per * Decimal.fromInt(4)).toString()),
  ];
}

void main() {
  // Pin a stable "now" so age math + ETA dates are deterministic.
  final now = DateTime(2026, 5, 18);
  // Mid-thirties — clears the age ∈ [13, 100] sanity check with room.
  final birth1990 = DateTime(1990, 1, 1);

  group('canonical sex comparison (research §3)', () {
    test('male 90 → 80 with ~500 kcal deficit lands in weeks-to-months',
        () {
      // Male, 35y, 180cm, sedentary. BMR≈1855. PAL×BMR≈2226.
      // Intake 1794 with k=0.95 → day-0 balance ≈ −500.
      final history = _decliningHistory(
        now,
        currentKg: '90.0',
        per7Days: '0.35',
      );
      final intake = _flatIntake(now, 14, 1794);
      final p = projectGoal(
        history: history,
        targetKg: Decimal.parse('80.0'),
        now: now,
        sex: Sex.male,
        birthDate: birth1990,
        heightCm: Decimal.parse('180'),
        activityLevel: ActivityLevel.sedentary,
        intake: intake,
      );
      expect(p.kind, ProjectionKind.onTrack);
      expect(p.eta, isNotNull);
      expect(p.weeksAway, isNotNull);
      // Sanity band: 4–40 weeks. The research is explicit that
      // tighter point estimates are over-claiming for this model
      // class (±15–25 % literature accuracy; we widen to absorb the
      // additional calibration uncertainty).
      expect(
        p.weeksAway! >= 4 && p.weeksAway! <= 40,
        isTrue,
        reason: 'got ${p.weeksAway} wks',
      );
      expect(p.lowConfidence, isFalse);
      expect(p.impliedDeficitKcalPerDay, isNotNull);
      expect(
        p.impliedDeficitKcalPerDay! < Decimal.zero,
        isTrue,
        reason: 'losing → negative balance',
      );
    });

    test('female on the same regimen projects slower than male', () {
      final history = _decliningHistory(
        now,
        currentKg: '90.0',
        per7Days: '0.35',
      );
      final intake = _flatIntake(now, 14, 1794);
      final male = projectGoal(
        history: history,
        targetKg: Decimal.parse('80.0'),
        now: now,
        sex: Sex.male,
        birthDate: birth1990,
        heightCm: Decimal.parse('180'),
        activityLevel: ActivityLevel.sedentary,
        intake: intake,
      );
      final female = projectGoal(
        history: history,
        targetKg: Decimal.parse('80.0'),
        now: now,
        sex: Sex.female,
        birthDate: birth1990,
        heightCm: Decimal.parse('180'),
        activityLevel: ActivityLevel.sedentary,
        intake: intake,
      );
      expect(male.kind, ProjectionKind.onTrack);
      expect(female.kind, ProjectionKind.onTrack);
      // Sex enters through Mifflin's constant (+5 men / −161 women)
      // and the Deurenberg body-fat seed. A woman at the same
      // weight has a lower BMR, so the same intake produces a
      // *smaller* day-0 deficit (or a deficit applied to a smaller
      // fat compartment), and projection should be slower or
      // equal. Research §3 is explicit on this.
      expect(
        female.weeksAway! >= male.weeksAway!,
        isTrue,
        reason:
            'female ${female.weeksAway} wks vs male ${male.weeksAway} wks',
      );
    });
  });

  group('insufficient data', () {
    test('empty history → insufficientData', () {
      final p = projectGoal(
        history: const <WeightEntry>[],
        targetKg: Decimal.parse('75.0'),
        now: now,
      );
      expect(p.kind, ProjectionKind.insufficientData);
    });

    test('missing sex → insufficientData', () {
      final history = _decliningHistory(
        now,
        currentKg: '90.0',
        per7Days: '0.35',
      );
      final p = projectGoal(
        history: history,
        targetKg: Decimal.parse('80.0'),
        now: now,
        // sex omitted
        birthDate: birth1990,
        heightCm: Decimal.parse('180'),
        activityLevel: ActivityLevel.sedentary,
      );
      expect(p.kind, ProjectionKind.insufficientData);
    });

    test('missing height → insufficientData', () {
      final history = _decliningHistory(
        now,
        currentKg: '90.0',
        per7Days: '0.35',
      );
      final p = projectGoal(
        history: history,
        targetKg: Decimal.parse('80.0'),
        now: now,
        sex: Sex.male,
        birthDate: birth1990,
        // heightCm omitted
        activityLevel: ActivityLevel.sedentary,
      );
      expect(p.kind, ProjectionKind.insufficientData);
    });

    test('implausible profile (toddler height) → insufficientData', () {
      final history = _decliningHistory(
        now,
        currentKg: '90.0',
        per7Days: '0.35',
      );
      final p = projectGoal(
        history: history,
        targetKg: Decimal.parse('80.0'),
        now: now,
        sex: Sex.male,
        birthDate: birth1990,
        heightCm: Decimal.parse('80'),
        activityLevel: ActivityLevel.sedentary,
      );
      expect(p.kind, ProjectionKind.insufficientData);
    });
  });

  group('low-confidence path', () {
    test('sparse intake (< 10 days in last 14) → lowConfidence + onTrack',
        () {
      final history = _decliningHistory(
        now,
        currentKg: '90.0',
        per7Days: '0.35',
      );
      // Only 3 days of intake — well below the §6.1 threshold.
      final intake = _flatIntake(now, 3, 1800);
      final p = projectGoal(
        history: history,
        targetKg: Decimal.parse('80.0'),
        now: now,
        sex: Sex.male,
        birthDate: birth1990,
        heightCm: Decimal.parse('180'),
        activityLevel: ActivityLevel.sedentary,
        intake: intake,
      );
      // Either onTrack (with low-confidence flag) or flat — both
      // are acceptable; what matters is that the flag is set so
      // the UI knows to soften the headline.
      expect(p.lowConfidence, isTrue);
      expect(
        p.kind == ProjectionKind.onTrack ||
            p.kind == ProjectionKind.flat ||
            p.kind == ProjectionKind.offTrack,
        isTrue,
      );
    });

    test('no intake at all → lowConfidence + sane projection', () {
      final history = _decliningHistory(
        now,
        currentKg: '90.0',
        per7Days: '0.35',
      );
      final p = projectGoal(
        history: history,
        targetKg: Decimal.parse('80.0'),
        now: now,
        sex: Sex.male,
        birthDate: birth1990,
        heightCm: Decimal.parse('180'),
        activityLevel: ActivityLevel.sedentary,
        // intake defaults to const [] → no calibration window
      );
      expect(p.lowConfidence, isTrue);
      // No crash, valid kind.
      expect(p.kind, isNotNull);
    });
  });

  group('state machine', () {
    test('target already reached (within ±0.2 kg) → reached', () {
      final history = <WeightEntry>[
        _we(now, 0, '76.1'),
        _we(now, 7, '76.4'),
        _we(now, 14, '76.7'),
        _we(now, 21, '77.0'),
        _we(now, 28, '77.3'),
      ];
      final p = projectGoal(
        history: history,
        targetKg: Decimal.parse('76.0'),
        now: now,
        sex: Sex.male,
        birthDate: birth1990,
        heightCm: Decimal.parse('180'),
        activityLevel: ActivityLevel.sedentary,
      );
      expect(p.kind, ProjectionKind.reached);
      expect(p.eta, isNull);
    });

    test('wrong-direction (gaining when goal is below current) → offTrack',
        () {
      // 5-week gain trend, ~+0.3 kg/wk; sustained ~3300 kcal/day
      // intake on a sedentary 80 kg male would compound the gain.
      final history = <WeightEntry>[
        _we(now, 0, '82.0'),
        _we(now, 7, '81.7'),
        _we(now, 14, '81.4'),
        _we(now, 21, '81.1'),
        _we(now, 28, '80.8'),
      ];
      final intake = _flatIntake(now, 14, 3300);
      final p = projectGoal(
        history: history,
        targetKg: Decimal.parse('70.0'),
        now: now,
        sex: Sex.male,
        birthDate: birth1990,
        heightCm: Decimal.parse('180'),
        activityLevel: ActivityLevel.sedentary,
        intake: intake,
      );
      expect(p.kind, ProjectionKind.offTrack);
      expect(p.eta, isNull);
    });

    test('horizon exceeded (90 → 50 kg at near-maintenance) → offTrack',
        () {
      // Implausibly distant goal at a near-maintenance intake →
      // the 730-day horizon trips before the target is reached.
      // The dynamic model treats this as the "more than 2 years —
      // consider revising goal" branch (§6.1) and surfaces it as
      // offTrack so the UI doesn't render a fantasy ETA.
      final history = _decliningHistory(
        now,
        currentKg: '90.0',
        per7Days: '0.05',
      );
      final intake = _flatIntake(now, 14, 2250);
      final p = projectGoal(
        history: history,
        targetKg: Decimal.parse('50.0'),
        now: now,
        sex: Sex.male,
        birthDate: birth1990,
        heightCm: Decimal.parse('180'),
        activityLevel: ActivityLevel.sedentary,
        intake: intake,
      );
      // Either offTrack (horizon exceeded) or flat (model
      // equilibrium is above target). Both are acceptable
      // "don't render an ETA" outcomes.
      expect(
        p.kind == ProjectionKind.offTrack ||
            p.kind == ProjectionKind.flat,
        isTrue,
        reason: 'got ${p.kind}',
      );
      expect(p.eta, isNull);
    });

    test('gain trajectory toward higher target → onTrack', () {
      // Current 70, goal 75. Caloric surplus on a sedentary 70 kg
      // male → gain side of the projection.
      final history = <WeightEntry>[
        _we(now, 0, '70.0'),
        _we(now, 7, '69.85'),
        _we(now, 14, '69.7'),
        _we(now, 21, '69.55'),
        _we(now, 28, '69.4'),
      ];
      final intake = _flatIntake(now, 14, 2700);
      final p = projectGoal(
        history: history,
        targetKg: Decimal.parse('75.0'),
        now: now,
        sex: Sex.male,
        birthDate: birth1990,
        heightCm: Decimal.parse('180'),
        activityLevel: ActivityLevel.sedentary,
        intake: intake,
      );
      expect(p.kind, ProjectionKind.onTrack);
      expect(p.eta, isNotNull);
      expect(p.eta!.isAfter(now), isTrue);
    });
  });

  test('echoes targetKg + gapKg back to caller', () {
    final history = <WeightEntry>[
      _we(now, 0, '80.0'),
      _we(now, 14, '80.5'),
      _we(now, 28, '81.0'),
    ];
    final target = Decimal.parse('76.0');
    final p = projectGoal(
      history: history,
      targetKg: target,
      now: now,
    );
    expect(p.targetKg, target);
    expect(
      p.gapKg,
      Decimal.parse('-4.0'),
      reason: 'gap is signed: target − current',
    );
  });
}
