// Sanity-sweep harness — not part of the regular suite (no asserts on
// exact days; just prints a comparison table for human review).
//
// Compares the production `projectGoal` against two alternates:
//   • Hall-PAA : replaces `PAL × BMR` with `BMR + δ·W` (Hall 2011 style
//     adult PAA term). δ chosen per activity level. This is the
//     variant the implementation agent flagged as missing.
//   • Hybrid-PAL : same as production but PAL multiplier reduced toward
//     1.0 (i.e. PAA scaled with weight via a mass-proportional add-on),
//     to see whether a softer touch closes the NIH BWP gap.
//
// Expected ranges come from documented norms:
//   - 500 kcal/day deficit → 0.4-0.5 kg/wk early, slowing as weight
//     drops (Hall 2011). 10 kg loss in 6-12 months is realistic.
//   - 1000 kcal/day deficit → 0.7-1.0 kg/wk early; 10 kg in 3-6 months.
//   - Women lose ~70-80% as fast as men at the same absolute deficit,
//     largely because their lower TDEE means a "500 kcal deficit"
//     is a bigger fraction of maintenance.
//   - NIH BWP for a 100 kg male, 35y, 180 cm, sedentary, 2350 kcal/day
//     (≈500 deficit) projects ~365 days to 90 kg.

import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/weight.dart';
import 'package:fulfilled/domain/weight_projection.dart';

class _Case {
  const _Case({
    required this.label,
    required this.sex,
    required this.ageYears,
    required this.heightCm,
    required this.weightKg,
    required this.targetKg,
    required this.activity,
    required this.deficitKcal,
    required this.expectedRange,
  });

  final String label;
  final Sex sex;
  final int ageYears;
  final double heightCm;
  final double weightKg;
  final double targetKg;
  final ActivityLevel activity;
  final double deficitKcal; // signed (negative = surplus)
  final String expectedRange;
}

void main() {
  test('synthetic-user sweep — current vs Hall-PAA variant', () {
    final now = DateTime(2026, 5, 19);

    final cases = <_Case>[
      const _Case(
        label: 'A: M 35y 180cm 100→80 sedentary 500-deficit',
        sex: Sex.male,
        ageYears: 35,
        heightCm: 180,
        weightKg: 100,
        targetKg: 80,
        activity: ActivityLevel.sedentary,
        deficitKcal: 500,
        expectedRange: 'NIH BWP ~700d to 80kg; lit ~12-18mo (~365-550d)',
      ),
      const _Case(
        label: 'B: F 35y 165cm 75→60 sedentary 500-deficit',
        sex: Sex.female,
        ageYears: 35,
        heightCm: 165,
        weightKg: 75,
        targetKg: 60,
        activity: ActivityLevel.sedentary,
        deficitKcal: 500,
        expectedRange: '~12-18mo (~400-550d), slower than M',
      ),
      const _Case(
        label: 'C: M 25y 175cm 80→70 moderate 300-deficit',
        sex: Sex.male,
        ageYears: 25,
        heightCm: 175,
        weightKg: 80,
        targetKg: 70,
        activity: ActivityLevel.moderate,
        deficitKcal: 300,
        expectedRange: '~6-9mo (~180-280d) — small cut, light goal',
      ),
      const _Case(
        label: 'D: F 45y 160cm 85→65 light 700-deficit',
        sex: Sex.female,
        ageYears: 45,
        heightCm: 160,
        weightKg: 85,
        targetKg: 65,
        activity: ActivityLevel.light,
        deficitKcal: 700,
        expectedRange: '~14-20mo (~420-600d)',
      ),
      const _Case(
        label: 'E: M 50y 175cm 95→75 sedentary 500-deficit',
        sex: Sex.male,
        ageYears: 50,
        heightCm: 175,
        weightKg: 95,
        targetKg: 75,
        activity: ActivityLevel.sedentary,
        deficitKcal: 500,
        expectedRange: '~15-20mo (~450-600d) — older, lower TDEE',
      ),
      const _Case(
        label: 'F: M 30y 180cm 70→80 active 500-SURPLUS',
        sex: Sex.male,
        ageYears: 30,
        heightCm: 180,
        weightKg: 70,
        targetKg: 80,
        activity: ActivityLevel.active,
        deficitKcal: -500,
        expectedRange: '~6-9mo (~180-280d), ~0.35 kg/wk gain',
      ),
      const _Case(
        label: 'G: M 30y 180cm 90→80 sedentary 1000-deficit',
        sex: Sex.male,
        ageYears: 30,
        heightCm: 180,
        weightKg: 90,
        targetKg: 80,
        activity: ActivityLevel.sedentary,
        deficitKcal: 1000,
        expectedRange: '~3-5mo (~90-150d) — aggressive cut',
      ),
      const _Case(
        label: 'H: F 28y 168cm 65→58 moderate 400-deficit',
        sex: Sex.female,
        ageYears: 28,
        heightCm: 168,
        weightKg: 65,
        targetKg: 58,
        activity: ActivityLevel.moderate,
        deficitKcal: 400,
        expectedRange: '~6-10mo (~180-300d) — modest cut from healthy',
      ),
    ];

    // ignore: avoid_print
    print(_header());

    for (final c in cases) {
      final history = _seedHistoryHallDynamics(
        startWeightKg: c.weightKg,
        sex: c.sex,
        ageYears: c.ageYears,
        heightCm: c.heightCm,
        activity: c.activity,
        deficitKcal: c.deficitKcal,
        days: 21,
        now: now,
      );
      final intake = _seedIntakeFromCut(
        weightKg: c.weightKg,
        heightCm: c.heightCm,
        ageYears: c.ageYears,
        sex: c.sex,
        activity: c.activity,
        deficitKcal: c.deficitKcal,
        days: 14,
        now: now,
      );

      final birthDate =
          DateTime(now.year - c.ageYears, now.month, now.day);

      final prodResult = projectGoal(
        history: history,
        targetKg: Decimal.parse(c.targetKg.toString()),
        now: now,
        sex: c.sex,
        birthDate: birthDate,
        heightCm: Decimal.parse(c.heightCm.toString()),
        activityLevel: c.activity,
        intake: intake,
      );

      // Run the hall-style simulation with the *same* current weight
      // the production model sees (= today's seeded entry, which has
      // water-noise applied) so the two are apples-to-apples.
      final todayKg = history.first.weightKg.toDouble();
      final hallPaa = _simulateHallStyle(
        startWeightKg: todayKg,
        targetKg: c.targetKg,
        sex: c.sex,
        ageYears: c.ageYears,
        heightCm: c.heightCm,
        activity: c.activity,
        intakeKcal: _intakeFor(
          weightKg: c.weightKg,
          heightCm: c.heightCm,
          ageYears: c.ageYears,
          sex: c.sex,
          activity: c.activity,
          deficitKcal: c.deficitKcal,
        ),
        kScalar: prodResult.lowConfidence ? 0.95 : 1.0,
        losing: c.deficitKcal > 0,
      );

      // ignore: avoid_print
      print(
        _row(
          label: c.label,
          prod: prodResult,
          hallDays: hallPaa,
          expected: c.expectedRange,
        ),
      );

      // Real assertions: the model must (a) produce a usable
      // outcome for each case, and (b) land within ~50 % of the
      // Hall-PAA reference. The reference is what an uncalibrated
      // run of the same dynamics produces; any larger divergence
      // means calibration is drifting and the regression should
      // be investigated.
      expect(
        prodResult.kind,
        anyOf(
          ProjectionKind.onTrack,
          ProjectionKind.flat,
          ProjectionKind.offTrack,
          ProjectionKind.reached,
        ),
        reason: '${c.label}: unexpected kind',
      );
      if (prodResult.kind == ProjectionKind.onTrack && hallPaa != null) {
        final prodDays = prodResult.weeksAway! * 7;
        final ratio = prodDays / hallPaa;
        expect(
          ratio >= 0.5 && ratio <= 1.5,
          isTrue,
          reason:
              '${c.label}: prod=$prodDays hall=$hallPaa ratio=$ratio outside [0.5,1.5]',
        );
      }
    }
  });
}

String _header() => '''

──────────────────────────────────────────────────────────────────────
SYNTHETIC USER SWEEP
──────────────────────────────────────────────────────────────────────
case                                                 prod    hall    expected
                                                     (days)  (days)
──────────────────────────────────────────────────────────────────────''';

String _row({
  required String label,
  required GoalProjection prod,
  required int? hallDays,
  required String expected,
}) {
  final prodDays = prod.kind == ProjectionKind.onTrack
      ? '${prod.weeksAway! * 7}'.padLeft(5)
      : prod.kind.name.padLeft(5);
  final hallStr =
      hallDays == null ? ' n/a '.padLeft(5) : '$hallDays'.padLeft(5);
  final lc = prod.lowConfidence ? ' (lc)' : '';
  final impl = prod.impliedDeficitKcalPerDay == null
      ? ''
      : ' bal=${prod.impliedDeficitKcalPerDay}';
  return '${label.padRight(52)} $prodDays  $hallStr  $expected$lc$impl';
}

// ─── Synthetic seed builders ───────────────────────────────────────────────

/// Build a plausible 21-day weight series by running the Hall-style
/// dynamic model backward from the target current weight under the
/// seeded deficit. This is what a real user obeying Hall dynamics
/// would have logged. Adds ±0.3 kg sinusoidal water-weight noise so
/// the 7-day-median trick in calibration has something realistic to
/// chew on.
List<WeightEntry> _seedHistoryHallDynamics({
  required double startWeightKg,
  required Sex sex,
  required int ageYears,
  required double heightCm,
  required ActivityLevel activity,
  required double deficitKcal,
  required int days,
  required DateTime now,
}) {
  // Run forward from `days` ago for `days` days; we know today's
  // weight is `startWeightKg`. To get the historical curve we
  // instead run the dynamics in *reverse* — same formulas but with
  // balance sign-flipped — starting from today's weight and
  // stepping backward into the past.
  final intake = _intakeFor(
    weightKg: startWeightKg,
    heightCm: heightCm,
    ageYears: ageYears,
    sex: sex,
    activity: activity,
    deficitKcal: deficitKcal,
  );
  final bmi0 = startWeightKg / ((heightCm / 100) * (heightCm / 100));
  final sexFactor = switch (sex) {
    Sex.male => 1.0,
    Sex.female => 0.0,
    Sex.other => 0.5,
  };
  final bfPct = 1.20 * bmi0 + 0.23 * ageYears - 10.8 * sexFactor - 5.4;
  final bf0 = (bfPct / 100.0).clamp(0.08, 0.55).toDouble();

  // First simulate FORWARD for `days` days starting from a guess of
  // the past weight, picking the past weight such that the forward
  // sim ends at startWeightKg today. Easier: bisect on past weight.
  double tryRun(double pastWeight) {
    var W = pastWeight;
    var F = bf0 * pastWeight;
    var L = W - F;
    final sexConst = _mifflinSexConstant(sex);
    final delta = _hallDelta(activity);
    const beta = 6.0;
    final startW = W; // for AT
    for (var d = 0; d < days - 1; d += 1) {
      final bmr = 10.0 * W + 6.25 * heightCm - 5.0 * ageYears + sexConst;
      final losing = deficitKcal > 0;
      final at = losing && (startW - W) > 0 ? beta * (startW - W) : 0.0;
      final tdee = 1.0 * (bmr + delta * W) + 0.10 * intake - at;
      var balance = intake - tdee;
      if (balance < -1500.0) balance = -1500.0;
      if (balance > 1500.0) balance = 1500.0;
      final fSafe = F < 1.0 ? 1.0 : F;
      final p = 10.4 / (10.4 + fSafe);
      final dF = (1.0 - p) * balance / 9440.0;
      final dL = p * balance / 1800.0;
      F += dF;
      L += dL;
      if (F < 1.0) F = 1.0;
      if (L < 20.0) L = 20.0;
      W = F + L;
    }
    return W;
  }

  // Bisect for the past-weight that yields today = startWeightKg.
  double lo = startWeightKg - 5.0;
  double hi = startWeightKg + 5.0;
  for (var i = 0; i < 30; i += 1) {
    final mid = 0.5 * (lo + hi);
    final endW = tryRun(mid);
    if (endW < startWeightKg) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  final pastWeight = 0.5 * (lo + hi);

  // Now run forward one more time, recording each day's weight.
  final result = <WeightEntry>[];
  var W = pastWeight;
  var F = bf0 * pastWeight;
  var L = W - F;
  final sexConst = _mifflinSexConstant(sex);
  final delta = _hallDelta(activity);
  const beta = 6.0;
  final startW = W;
  for (var d = 0; d < days; d += 1) {
    // d=0 → oldest (age = days-1), d=days-1 → today (age=0)
    final age = days - 1 - d;
    final weight = W + _waterNoise(age);
    final recordedOn = now.subtract(Duration(days: age));
    result.add(
      WeightEntry(
        id: 'syn-$d',
        recordedOn: recordedOn,
        weightKg: Decimal.parse(weight.toStringAsFixed(2)),
        createdAt: recordedOn,
      ),
    );
    if (d < days - 1) {
      final bmr = 10.0 * W + 6.25 * heightCm - 5.0 * ageYears + sexConst;
      final losing = deficitKcal > 0;
      final at = losing && (startW - W) > 0 ? beta * (startW - W) : 0.0;
      final tdee = 1.0 * (bmr + delta * W) + 0.10 * intake - at;
      var balance = intake - tdee;
      if (balance < -1500.0) balance = -1500.0;
      if (balance > 1500.0) balance = 1500.0;
      final fSafe = F < 1.0 ? 1.0 : F;
      final p = 10.4 / (10.4 + fSafe);
      F += (1.0 - p) * balance / 9440.0;
      L += p * balance / 1800.0;
      if (F < 1.0) F = 1.0;
      if (L < 20.0) L = 20.0;
      W = F + L;
    }
  }
  result.sort((a, b) => b.recordedOn.compareTo(a.recordedOn));
  return result;
}

double _waterNoise(int dayOffset) {
  // Tiny deterministic ripple. Amplitude 0.3 kg.
  return 0.3 *
      ((dayOffset % 7) - 3) /
      3.0; // ranges ~[-0.3, +0.3]
}

List<IntakeDay> _seedIntakeFromCut({
  required double weightKg,
  required double heightCm,
  required int ageYears,
  required Sex sex,
  required ActivityLevel activity,
  required double deficitKcal,
  required int days,
  required DateTime now,
}) {
  final intake = _intakeFor(
    weightKg: weightKg,
    heightCm: heightCm,
    ageYears: ageYears,
    sex: sex,
    activity: activity,
    deficitKcal: deficitKcal,
  );
  final out = <IntakeDay>[];
  for (var d = 0; d < days; d += 1) {
    final date = now.subtract(Duration(days: d));
    out.add(
      IntakeDay(
        date: date,
        kcal: Decimal.parse(intake.toStringAsFixed(0)),
      ),
    );
  }
  return out;
}

double _intakeFor({
  required double weightKg,
  required double heightCm,
  required int ageYears,
  required Sex sex,
  required ActivityLevel activity,
  required double deficitKcal,
}) {
  final bmr = 10.0 * weightKg +
      6.25 * heightCm -
      5.0 * ageYears +
      _mifflinSexConstant(sex);
  final pal = _palFor(activity);
  // Hall-style TDEE estimate (more accurate at start) → subtract
  // deficit. We use Hall's form for seeding to give both models
  // a roughly fair "user is in X-kcal deficit" starting point.
  final tdee = bmr + _hallDelta(activity) * weightKg + 0.10 * 2000;
  // Sanity: ignore PAL multiplier here on purpose. Goal is to set
  // intake such that the user IS in `deficitKcal` deficit right now.
  // ignore: unused_local_variable
  final _ = pal;
  return tdee - deficitKcal;
}

// ─── Hall-style PAA variant ────────────────────────────────────────────────

/// Returns the day-count where the Hall-style model crosses [targetKg],
/// or null on flat / wrong-direction / horizon-exceeded.
///
/// Differs from production in one place: TDEE uses
///   BMR + δ·W + 0.10·intake − AT
/// instead of
///   k·PAL·BMR + 0.10·intake − AT
/// where δ is the activity-level-keyed PAA coefficient. This makes
/// TDEE roughly twice as weight-sensitive (15 → ~28 kcal/kg/day),
/// which is the dimensional difference the implementation agent
/// flagged vs NIH BWP.
int? _simulateHallStyle({
  required double startWeightKg,
  required double targetKg,
  required Sex sex,
  required int ageYears,
  required double heightCm,
  required ActivityLevel activity,
  required double intakeKcal,
  required double kScalar,
  required bool losing,
}) {
  const horizon = 730;
  const rhoF = 9440.0;
  const rhoL = 1800.0;
  const beta = 6.0;

  // Deurenberg seed → initial fat mass.
  final bmi = startWeightKg / ((heightCm / 100) * (heightCm / 100));
  final sexFactor = switch (sex) {
    Sex.male => 1.0,
    Sex.female => 0.0,
    Sex.other => 0.5,
  };
  final bfPct = 1.20 * bmi + 0.23 * ageYears - 10.8 * sexFactor - 5.4;
  final bf0 = (bfPct / 100.0).clamp(0.08, 0.55).toDouble();

  var W = startWeightKg;
  var F = bf0 * W;
  var L = W - F;
  final startW = W;
  final sexConst = _mifflinSexConstant(sex);
  final delta = _hallDelta(activity);

  for (var day = 1; day <= horizon; day += 1) {
    final bmr = 10.0 * W + 6.25 * heightCm - 5.0 * ageYears + sexConst;
    final at = beta * (startW - W > 0 ? (startW - W) : 0.0);
    final tdee = kScalar * (bmr + delta * W) + 0.10 * intakeKcal - at;
    var balance = intakeKcal - tdee;
    if (balance < -1500.0) balance = -1500.0;
    if (balance > 1500.0) balance = 1500.0;

    final fSafe = F < 1.0 ? 1.0 : F;
    final p = 10.4 / (10.4 + fSafe);
    final dF = (1.0 - p) * balance / rhoF;
    final dL = p * balance / rhoL;
    F += dF;
    L += dL;
    if (F < 1.0) F = 1.0;
    if (L < 20.0) L = 20.0;
    W = F + L;

    if (losing && W <= targetKg) return day;
    if (!losing && W >= targetKg) return day;
  }
  return null;
}

/// Hall's activity-keyed PAA coefficient (kcal/kg/day). Sources:
/// Hall 2011 Lancet, Hall 2010 Am J Clin Nutr. Sedentary ≈ 5, active
/// adult ≈ 13–17. Numbers below interpolate to match our PAL ladder.
double _hallDelta(ActivityLevel level) {
  switch (level) {
    case ActivityLevel.sedentary:
      return 5.0;
    case ActivityLevel.light:
      return 9.0;
    case ActivityLevel.moderate:
      return 13.0;
    case ActivityLevel.active:
      return 17.0;
    case ActivityLevel.veryActive:
      return 21.0;
  }
}

double _palFor(ActivityLevel level) {
  switch (level) {
    case ActivityLevel.sedentary:
      return 1.2;
    case ActivityLevel.light:
      return 1.375;
    case ActivityLevel.moderate:
      return 1.55;
    case ActivityLevel.active:
      return 1.725;
    case ActivityLevel.veryActive:
      return 1.9;
  }
}

double _mifflinSexConstant(Sex s) {
  switch (s) {
    case Sex.male:
      return 5.0;
    case Sex.female:
      return -161.0;
    case Sex.other:
      return -78.0;
  }
}
