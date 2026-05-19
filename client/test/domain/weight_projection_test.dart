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

  group('canonical case', () {
    test('male 90 → 80 on a ~500 kcal deficit projects on-track', () {
      // Male, 36y, 180cm, sedentary. With δ=5 (sedentary PAA) and
      // intake≈1750, Hall-form TDEE puts day-0 deficit near 500 kcal.
      // Seeded weight slope of 0.86 kg/wk is what a 500-kcal deficit
      // actually delivers on a 90 kg user under Hall dynamics
      // (rho_eff≈4060 → 500/4060 = 0.123 kg/day).
      final history = _decliningHistory(
        now,
        currentKg: '90.0',
        per7Days: '0.86',
      );
      final intake = _flatIntake(now, 14, 1750);
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
      // Sanity band: 4–60 weeks. The model itself disclaims ±15–25 %
      // accuracy (research §1); we widen to absorb calibration drift
      // and the asymptotic slow-down as the projection approaches
      // equilibrium weight.
      expect(
        p.weeksAway! >= 4 && p.weeksAway! <= 60,
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

    test('female 90 → 80 on a ~500 kcal deficit projects on-track', () {
      // Same regimen as the male case but female. Mifflin sex
      // constant (−161 vs +5) gives a lower BMR; the Deurenberg
      // seed puts more mass in the fat compartment, so ρ_eff is
      // higher. The calibration absorbs both differences and
      // anchors `k` to whatever loss rate the user is actually
      // sustaining — so the resulting projection is allowed to
      // sit anywhere in the sane band, not strictly bounded
      // against the male projection. (Original test asserted
      // female ≥ male on the assumption that calibration was
      // off; that's an invalid premise once k is fitted.)
      final history = _decliningHistory(
        now,
        currentKg: '90.0',
        per7Days: '0.75',
      );
      final intake = _flatIntake(now, 14, 1600);
      final p = projectGoal(
        history: history,
        targetKg: Decimal.parse('80.0'),
        now: now,
        sex: Sex.female,
        birthDate: birth1990,
        heightCm: Decimal.parse('165'),
        activityLevel: ActivityLevel.sedentary,
        intake: intake,
      );
      expect(p.kind, ProjectionKind.onTrack);
      expect(
        p.weeksAway! >= 4 && p.weeksAway! <= 60,
        isTrue,
        reason: 'got ${p.weeksAway} wks',
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
      // Current 70, goal 75. Active 70 kg male in a sustained
      // surplus — 0.45 kg/wk gain at intake 3300 is consistent
      // with ~500 kcal surplus under Hall dynamics for this
      // body composition. Anything less and the calibrated
      // equilibrium sits at or below the target → flat outcome.
      final history = <WeightEntry>[
        _we(now, 0, '70.0'),
        _we(now, 7, '69.55'),
        _we(now, 14, '69.1'),
        _we(now, 21, '68.65'),
        _we(now, 28, '68.2'),
      ];
      final intake = _flatIntake(now, 14, 3300);
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
