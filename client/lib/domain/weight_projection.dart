import 'package:decimal/decimal.dart';

import 'calories/estimate.dart' show ageInYears;
import 'enums.dart';
import 'weight.dart';

/// Projection of when the user will hit their target weight under their
/// observed intake.
///
/// **Model:** Mifflin-St Jeor BMR + Hall-style PAA (`δ × W`) + Forbes-
/// partitioned two-compartment (fat / fat-free mass) dynamic update,
/// iterated daily until the projected weight crosses the target or a
/// 730-day horizon is hit. A scalar `k` fitted to the trailing
/// 14–28 day window absorbs Mifflin error + chronic intake under-
/// reporting in one shot. See `specs/weight_projection_research.md`
/// §5 for the broader derivation; the TDEE term diverges from §5.3
/// in one place — see [_simulate] for the rationale.
///
/// **Why the inner loop uses `double`, not `Decimal`.** The model is
/// approximate (±15–25 % per the research §1). The inner loop performs
/// ~700 iterations of multi-step floating math (BMR, TDEE, Forbes
/// partition, deltas). Running that through `Decimal` would buy zero
/// physical accuracy at meaningful cost. Inputs and outputs stay
/// `Decimal` so the public surface keeps the T-17 contract; the
/// simulation just operates on doubles internally.
class GoalProjection {
  const GoalProjection({
    required this.kind,
    required this.targetKg,
    required this.gapKg,
    this.weeklyRateKg,
    this.eta,
    this.weeksAway,
    this.lowConfidence = false,
    this.impliedDeficitKcalPerDay,
  });

  final ProjectionKind kind;

  /// The active goal's `targetWeightKg` — echoed back so the renderer
  /// can format the headline `"Reach 74.0 kg by …"` without re-watching
  /// `activeGoalProvider`.
  final Decimal targetKg;

  /// Signed gap to target (`target − current`). Negative when the user
  /// is currently above the target weight, positive when below.
  final Decimal gapKg;

  /// Smoothed weekly delta (signed) observed over the trailing 28-day
  /// window. Negative = losing, positive = gaining. Null when the
  /// window is too short to compute.
  final Decimal? weeklyRateKg;

  /// Projected ETA date. Non-null only for [ProjectionKind.onTrack].
  final DateTime? eta;

  /// Whole weeks to ETA. Non-null only for [ProjectionKind.onTrack].
  final int? weeksAway;

  /// True when calibration was skipped (sparse intake or weight
  /// history) — the projection used the default `k = 0.95` instead
  /// of fitting to the user. Renderer should annotate the headline so
  /// the user knows the projection is a generic estimate.
  final bool lowConfidence;

  /// Average daily energy balance over the trailing window
  /// (signed; negative = deficit). Surfaced for debug/diagnostic
  /// display; not used by the headline copy. Null when the projection
  /// did not compute an intake-based balance (e.g. insufficient data).
  final Decimal? impliedDeficitKcalPerDay;
}

enum ProjectionKind {
  /// Trajectory is in the right direction and the model projects an
  /// ETA inside the horizon; [GoalProjection.eta] /
  /// [GoalProjection.weeksAway] are populated.
  onTrack,

  /// Already within the "close enough" band of the target (±0.2 kg).
  reached,

  /// Intake at or above the modelled TDEE while the user wants to
  /// lose (or vice versa) — i.e. the equilibrium weight under current
  /// intake is on the wrong side of the goal.
  offTrack,

  /// Within the horizon the predicted weight barely moves
  /// (< 0.05 kg / wk) so an ETA would be misleading. Reached when
  /// the user is near their equilibrium weight under current intake.
  flat,

  /// Missing profile fields, no weight history, or the dynamic model
  /// can't be initialised (e.g. body-fat seed estimate goes
  /// pathological).
  insufficientData,
}

/// One day of observed intake. Kept as a tiny struct so the provider
/// doesn't need to leak the full `DaySummary` shape into the domain
/// layer.
class IntakeDay {
  const IntakeDay({required this.date, required this.kcal});

  /// Local calendar date for the entry (no time-of-day component).
  final DateTime date;

  /// Total kcal logged on [date]. `Decimal` to keep the boundary
  /// honest with the rest of the food-log surface; converted to
  /// `double` once at the simulation seam.
  final Decimal kcal;
}

/// Pure, side-effect-free projection. Anchors ETA at [now] — not the
/// most recent weight entry's `recordedOn` — so the rendered date
/// matches the user's calendar expectation ("from today").
///
/// All upstream watching happens in `providers/goal_providers.dart`;
/// this function takes already-resolved values and is therefore
/// trivially testable without a `ProviderContainer`.
GoalProjection projectGoal({
  required List<WeightEntry> history,
  required Decimal targetKg,
  required DateTime now,
  // Profile inputs — all nullable so the caller can pass whatever
  // it has and we degrade gracefully.
  Sex? sex,
  DateTime? birthDate,
  Decimal? heightCm,
  ActivityLevel? activityLevel,
  // Trailing-window intake. Newest-first or oldest-first, both work
  // — we sort internally. Days outside the calibration window are
  // ignored.
  List<IntakeDay> intake = const <IntakeDay>[],
}) {
  if (history.isEmpty) {
    return _insufficient(targetKg, Decimal.zero);
  }
  // Contract: `weightHistoryProvider` is newest-first.
  final currentKg = history.first.weightKg;
  final gap = targetKg - currentKg;

  // Within band → already reached. 0.2 kg ≈ daily-fluctuation noise;
  // any tighter and a small drift would flip the state on/off.
  if (gap.abs() <= _reachedBandKg) {
    return GoalProjection(
      kind: ProjectionKind.reached,
      targetKg: targetKg,
      gapKg: gap,
      weeklyRateKg: _smoothedWeeklyRateKg(history),
    );
  }

  // Missing any required profile field → we can't run the dynamic
  // model. Surface as insufficientData so callers know to prompt
  // the user to finish onboarding.
  if (sex == null ||
      birthDate == null ||
      heightCm == null ||
      activityLevel == null) {
    return _insufficient(targetKg, gap);
  }

  final age = ageInYears(birthDate, now);
  // Sanity bounds on profile inputs — outside these the Mifflin /
  // Deurenberg estimates fall off the validated range and we'd be
  // extrapolating nonsense.
  final heightCmD = heightCm.toDouble();
  if (age < 13 || age > 100 || heightCmD < 120 || heightCmD > 230) {
    return _insufficient(targetKg, gap);
  }

  final currentKgD = currentKg.toDouble();
  if (currentKgD < 30 || currentKgD > 300) {
    return _insufficient(targetKg, gap);
  }

  // Initial body-fat seed (Deurenberg). See research §5.2 — rough,
  // ±5 pp absolute, but Forbes partitioning will self-correct over
  // the projection. Deurenberg returns a *percentage*, not a fraction.
  final bmi = currentKgD / ((heightCmD / 100.0) * (heightCmD / 100.0));
  // Sex.other → midpoint factor (0.5) — same hedge the calorie
  // estimator takes with the Mifflin sex constant.
  final sexFactorBF = switch (sex) {
    Sex.male => 1.0,
    Sex.female => 0.0,
    Sex.other => 0.5,
  };
  final bfPercent = 1.20 * bmi + 0.23 * age - 10.8 * sexFactorBF - 5.4;
  // Clamp to a sane band — Deurenberg goes negative on very lean
  // young men and pathologically high on very obese older women.
  final bf0 = (bfPercent / 100.0).clamp(0.08, 0.55).toDouble();

  final deltaPaa = _hallDeltaFor(activityLevel);

  // Calibration window — trailing 14–28 days of intake. See research
  // §5.5 and §6.1 ("intake sparsity"). We use the trailing-window
  // median (7-day-median trick) as the projected future intake.
  final calibration = _calibrate(
    history: history,
    intake: intake,
    now: now,
    weightKg: currentKgD,
    heightCm: heightCmD,
    ageYears: age,
    sex: sex,
    deltaPaa: deltaPaa,
  );
  final meanIntakeKcal = calibration.meanIntakeKcal;
  final kScalar = calibration.k;
  final isLowConfidence = calibration.lowConfidence;

  // If we have no usable intake at all → fall back to the maintenance
  // assumption (intake ≈ TDEE_0 × 0.95). That trips the offTrack /
  // flat branches sensibly without crashing.
  final assumedIntake = meanIntakeKcal ??
      _initialTdee(
            weightKg: currentKgD,
            heightCm: heightCmD,
            ageYears: age,
            sex: sex,
            deltaPaa: deltaPaa,
            kScalar: 0.95,
            intakeForTef: 2000.0,
          ) *
          0.95;

  // Simulate. Stop when the predicted weight crosses the goal, or
  // the trajectory stalls within the horizon.
  final sim = _simulate(
    startWeightKg: currentKgD,
    bf0: bf0,
    heightCm: heightCmD,
    sex: sex,
    ageYears: age,
    deltaPaa: deltaPaa,
    intakeKcal: assumedIntake,
    kScalar: kScalar,
    targetKg: targetKg.toDouble(),
    losing: gap < Decimal.zero,
  );

  final smoothedWeekly = _smoothedWeeklyRateKg(history);
  final balanceDec = _kcalBalanceAsDecimal(sim.dailyBalanceKcal);

  // Map simulation outcome → ProjectionKind.
  switch (sim.outcome) {
    case _SimOutcome.reached:
      final etaDays = sim.daysToReach!;
      final today = DateTime(now.year, now.month, now.day);
      final eta = today.add(Duration(days: etaDays));
      final weeksWhole = (etaDays / 7).round();
      return GoalProjection(
        kind: ProjectionKind.onTrack,
        targetKg: targetKg,
        gapKg: gap,
        weeklyRateKg: smoothedWeekly,
        eta: eta,
        weeksAway: weeksWhole,
        lowConfidence: isLowConfidence,
        impliedDeficitKcalPerDay: balanceDec,
      );
    case _SimOutcome.wrongDirection:
      return GoalProjection(
        kind: ProjectionKind.offTrack,
        targetKg: targetKg,
        gapKg: gap,
        weeklyRateKg: smoothedWeekly,
        lowConfidence: isLowConfidence,
        impliedDeficitKcalPerDay: balanceDec,
      );
    case _SimOutcome.flat:
      return GoalProjection(
        kind: ProjectionKind.flat,
        targetKg: targetKg,
        gapKg: gap,
        weeklyRateKg: smoothedWeekly,
        lowConfidence: isLowConfidence,
        impliedDeficitKcalPerDay: balanceDec,
      );
    case _SimOutcome.horizonExceeded:
      return GoalProjection(
        kind: ProjectionKind.offTrack,
        targetKg: targetKg,
        gapKg: gap,
        weeklyRateKg: smoothedWeekly,
        lowConfidence: isLowConfidence,
        impliedDeficitKcalPerDay: balanceDec,
      );
  }
}

GoalProjection _insufficient(Decimal targetKg, Decimal gap) => GoalProjection(
      kind: ProjectionKind.insufficientData,
      targetKg: targetKg,
      gapKg: gap,
    );

// ─── Calibration ───────────────────────────────────────────────────────────

class _Calibration {
  const _Calibration({
    required this.k,
    required this.meanIntakeKcal,
    required this.lowConfidence,
  });
  final double k;
  final double? meanIntakeKcal;
  final bool lowConfidence;
}

/// Fit the `k` scalar to the trailing 14–28 day window. See research
/// §5.5: solve for `k` such that the dynamic-model predicted ΔW
/// over the window matches the observed (smoothed) ΔW. We constrain
/// `k ∈ [0.7, 1.3]`.
///
/// When intake or weight history is too sparse we skip calibration
/// and return `k = 0.95` (small downward bias against intake under-
/// reporting) with `lowConfidence = true`, per §5.5 / §6.1.
///
/// Note: we don't run the full forward model inside the fit — that
/// would be O(window × iterations) for the bisection. Instead we
/// approximate the in-window relationship as linear in `k` around
/// `k = 1.0`, which is accurate to better than 1 % over a 28-day
/// window. The forward projection runs the full dynamic model.
_Calibration _calibrate({
  required List<WeightEntry> history,
  required List<IntakeDay> intake,
  required DateTime now,
  required double weightKg,
  required double heightCm,
  required int ageYears,
  required Sex sex,
  required double deltaPaa,
}) {
  // Intake window — 14 most recent days of available log data.
  // §6.1 requires ≥ 10 logged days in the last 14 for calibration.
  final windowEnd = DateTime(now.year, now.month, now.day);
  final windowStart = windowEnd.subtract(const Duration(days: 14));
  final inWindow = <IntakeDay>[
    for (final d in intake)
      if (!_dateOf(d.date).isBefore(windowStart) &&
          !_dateOf(d.date).isAfter(windowEnd))
        d,
  ];

  double? meanIntake;
  if (inWindow.isNotEmpty) {
    var sum = 0.0;
    for (final d in inWindow) {
      sum += d.kcal.toDouble();
    }
    meanIntake = sum / inWindow.length;
  }

  // Weight history requirements: ≥ 4 weigh-ins in the last 28 days
  // for calibration to be meaningful (§6.1).
  final weightWindowStart =
      windowEnd.subtract(const Duration(days: 28));
  final recentWeights = <WeightEntry>[
    for (final w in history)
      if (!_dateOf(w.recordedOn).isBefore(weightWindowStart) &&
          !_dateOf(w.recordedOn).isAfter(windowEnd))
        w,
  ];

  // Low-confidence triggers: §6.1 — < 10 intake days in last 14, or
  // < 4 weigh-ins in last 28. Either → bail to default k and flag.
  final intakeSparse = inWindow.length < 10;
  final weightSparse = recentWeights.length < 4;
  if (intakeSparse || weightSparse) {
    return _Calibration(
      k: 0.95,
      meanIntakeKcal: meanIntake,
      lowConfidence: true,
    );
  }

  // We have enough data — fit `k`. We approximate the relationship
  // observed-ΔW vs k as monotone increasing (more activity → larger
  // deficit on a losing trend → larger observed |ΔW|). Bisect in
  // `[0.7, 1.3]` against the residual:
  //   residual(k) = simulated_ΔW(k) − observed_ΔW
  // The forward model is cheap (28 days × O(10) flops) so bisecting
  // is fine.
  final sortedByDate = <WeightEntry>[...recentWeights]
    ..sort((a, b) => a.recordedOn.compareTo(b.recordedOn));
  // §6.1 water-weight transient: drop the first 3 days of the
  // available weight series before computing ΔW_obs.
  final usable = sortedByDate.length > 3
      ? sortedByDate.sublist(3)
      : sortedByDate;
  if (usable.length < 2) {
    return _Calibration(
      k: 0.95,
      meanIntakeKcal: meanIntake,
      lowConfidence: true,
    );
  }
  final spanDays = usable.last.recordedOn
      .difference(usable.first.recordedOn)
      .inDays;
  if (spanDays < 7) {
    return _Calibration(
      k: 0.95,
      meanIntakeKcal: meanIntake,
      lowConfidence: true,
    );
  }
  // §6.1 — water-weight noise on single observations is ±0.5 kg even
  // for honest daily weighers. Compute ΔW from the median of the
  // trailing and leading thirds of the usable window so a single
  // noisy day doesn't pivot the fit. Window size adapts to entry
  // count: 7 entries each side for daily weighers, fewer (≥ 1) for
  // weekly-cadence users. Span used in the rate calc is the gap
  // between the medians of the two window date-ranges.
  final windowSize = (usable.length ~/ 3).clamp(1, 7);
  final headWindow = usable.take(windowSize).toList();
  final tailWindow =
      usable.reversed.take(windowSize).toList().reversed.toList();
  final headMedianKg = _medianKg(headWindow);
  final tailMedianKg = _medianKg(tailWindow);
  final headCenter = headWindow[headWindow.length ~/ 2].recordedOn;
  final tailCenter = tailWindow[tailWindow.length ~/ 2].recordedOn;
  final smoothedSpanDays = tailCenter.difference(headCenter).inDays;
  if (smoothedSpanDays < 7) {
    return _Calibration(
      k: 0.95,
      meanIntakeKcal: meanIntake,
      lowConfidence: true,
    );
  }
  final observedDeltaKg = tailMedianKg - headMedianKg;

  // Linearise the forward model around `k = 1` and solve for the `k`
  // that matches the observed ΔW over the window:
  //
  //   balance(k) = intake − tef − k × activeEnergy
  //   ΔW(k)     = balance(k) × span / ρ_eff
  //   solve     ΔW(k) == observed
  //
  // `activeEnergy = BMR + δ·W` — the part of TDEE that the scalar
  // `k` modulates (TEF is intake-driven and AT is small over a
  // 14-day window, so neither belongs inside the k-scaled term).
  //
  // `ρ_eff` is the per-user effective energy density of mass change,
  // derived from the Forbes partition + tissue densities the forward
  // sim uses. A fixed 7700 kcal/kg overstates ρ_eff by ~40 % for
  // typical body comps, which silently inflates the implied deficit
  // and over-corrects `k`. The Deurenberg-seeded F₀ gives a good
  // first estimate: at F=30 kg, ρ_eff ≈ 4500; at F=10 kg, ρ_eff ≈
  // 3400; at F=50 kg, ρ_eff ≈ 5500.
  final bmr0 = 10.0 * weightKg +
      6.25 * heightCm -
      5.0 * ageYears +
      _mifflinSexConstant(sex);
  final activeEnergy = bmr0 + deltaPaa * weightKg;
  final tef = 0.10 * meanIntake!;

  // Deurenberg seed (same as the projection path) → ρ_eff.
  final bmi0 = weightKg / ((heightCm / 100.0) * (heightCm / 100.0));
  final sexFactorBF = switch (sex) {
    Sex.male => 1.0,
    Sex.female => 0.0,
    Sex.other => 0.5,
  };
  final bf0Frac =
      ((1.20 * bmi0 + 0.23 * ageYears - 10.8 * sexFactorBF - 5.4) / 100.0)
          .clamp(0.08, 0.55)
          .toDouble();
  final f0 = bf0Frac * weightKg;
  final pPartition = 10.4 / (10.4 + f0);
  // ρ_eff = 1 / ((1-p)/ρ_F + p/ρ_L). Energy densities in §5.1.
  final rhoEff = 1.0 /
      ((1.0 - pPartition) / 9440.0 + pPartition / 1800.0);

  final implied = (meanIntake -
          tef -
          observedDeltaKg * rhoEff / smoothedSpanDays) /
      activeEnergy;
  final kFit = implied.clamp(0.7, 1.3).toDouble();

  return _Calibration(
    k: kFit,
    meanIntakeKcal: meanIntake,
    lowConfidence: false,
  );
}

DateTime _dateOf(DateTime d) => DateTime(d.year, d.month, d.day);

double _medianKg(List<WeightEntry> entries) {
  final values = <double>[
    for (final e in entries) e.weightKg.toDouble(),
  ]..sort();
  final n = values.length;
  if (n.isOdd) return values[n ~/ 2];
  return 0.5 * (values[n ~/ 2 - 1] + values[n ~/ 2]);
}

// ─── Simulation ────────────────────────────────────────────────────────────

enum _SimOutcome { reached, wrongDirection, flat, horizonExceeded }

class _SimResult {
  const _SimResult({
    required this.outcome,
    required this.dailyBalanceKcal,
    this.daysToReach,
  });
  final _SimOutcome outcome;

  /// Average daily energy balance during the simulated trajectory
  /// (signed; negative = deficit). Returned even when the goal isn't
  /// reached so the caller can surface "implied deficit" for debug.
  final double dailyBalanceKcal;

  /// Days from day 0 to crossing the target. Non-null only when
  /// `outcome == reached`.
  final int? daysToReach;
}

/// Per research §5.6 — Forbes-partitioned two-compartment dynamic
/// update, iterated daily.
///
/// **TDEE form deviates from research §5.3.** §5.3 specifies
/// `TDEE = k·PAL·BMR + 0.10·intake − AT`. A synthetic-user sweep
/// (see `test/domain/weight_projection_sweep_test.dart`) showed
/// that form predicting ~2-4× faster loss than NIH BWP + literature
/// norms across every test case — the `PAL × BMR` product amplifies
/// Mifflin's 10 kcal/kg/day weight-sensitivity by ~1.55×, but the
/// real physiology of physical-activity expenditure scales with
/// mass at a flatter slope. We instead use Hall's PAA form:
/// `TDEE = k·(BMR + δ·W) + 0.10·intake − AT` with δ keyed to
/// activity level (5/9/13/17/21 kcal/kg/day across the ladder, per
/// Hall 2011 Lancet + Hall 2010 AJCN). Same TDEE *level* at the
/// starting weight, more accurate dTDEE/dW as the user converges
/// on their equilibrium weight.
_SimResult _simulate({
  required double startWeightKg,
  required double bf0,
  required double heightCm,
  required Sex sex,
  required int ageYears,
  required double deltaPaa,
  required double intakeKcal,
  required double kScalar,
  required double targetKg,
  required bool losing,
}) {
  const horizon = 730; // 2 years; research says cap at 1095, we trim
  // for the mobile UX — anything > 2 years is "consider revising goal"
  // territory per §6.1.
  const flatThresholdKgPerWeek = 0.05;
  // Energy densities (research §5.1, citing Hall 2010).
  const rhoF = 9440.0; // kcal/kg fat tissue
  const rhoL = 1800.0; // kcal/kg fat-free tissue
  // Adaptive thermogenesis coefficient (research §5.4).
  const beta = 6.0; // kcal/day per kg lost

  var W = startWeightKg;
  var F = bf0 * startWeightKg;
  var L = W - F;
  final startW = W;
  final sexConst = _mifflinSexConstant(sex);

  // Sanity-clamp the energy balance to keep the model in its
  // validated range (research §6.1). Below −1500 kcal/day the
  // partition function gets unreliable + we shouldn't be projecting
  // implausibly aggressive deficits anyway.
  const minBalance = -1500.0;
  const maxBalance = 1500.0;

  var balanceSum = 0.0;
  var balanceDays = 0;
  var lastWeekW = W;

  for (var day = 1; day <= horizon; day += 1) {
    final bmr = 10.0 * W + 6.25 * heightCm - 5.0 * ageYears + sexConst;
    final at = beta * (startW - W > 0 ? (startW - W) : 0.0);
    final tdee = kScalar * (bmr + deltaPaa * W) + 0.10 * intakeKcal - at;
    var balance = intakeKcal - tdee;
    if (balance < minBalance) balance = minBalance;
    if (balance > maxBalance) balance = maxBalance;
    balanceSum += balance;
    balanceDays += 1;

    // Forbes partition: fraction of imbalance going to FFM. The
    // canonical Hall-Forbes form is `p = c / (c + F)` (equivalently
    // `1 / (1 + F/c)`); the research report's text gives the same
    // numerical claims (p≈0.26 at F=30, p≈0.51 at F=10) but its
    // symbolic formula in §5.6 is the complementary fraction. We
    // implement the form that matches the literature and the
    // report's *numbers*. See specs/weight_projection_research.md
    // §5.6 + Hall 2010 (cited in §7).
    //
    // Pathological tiny-fat-mass case is guarded by clamping F to
    // a positive floor.
    final fSafe = F < 1.0 ? 1.0 : F;
    final p = 10.4 / (10.4 + fSafe);
    final dF = (1.0 - p) * balance / rhoF;
    final dL = p * balance / rhoL;
    F = F + dF;
    L = L + dL;
    if (F < 1.0) F = 1.0;
    if (L < 20.0) L = 20.0; // implausibly low LBM — clamp
    W = F + L;

    // Reached?
    if (losing && W <= targetKg) {
      return _SimResult(
        outcome: _SimOutcome.reached,
        dailyBalanceKcal: balanceSum / balanceDays,
        daysToReach: day,
      );
    }
    if (!losing && W >= targetKg) {
      return _SimResult(
        outcome: _SimOutcome.reached,
        dailyBalanceKcal: balanceSum / balanceDays,
        daysToReach: day,
      );
    }

    // Weekly check for flatness / wrong direction. Done every 7th
    // day so a single noisy day doesn't trip a state.
    if (day % 7 == 0) {
      final weeklyDelta = W - lastWeekW;
      // Wrong-direction: gaining when we wanted to lose, or vice
      // versa. Only assertable once we've moved enough to be sure.
      if (losing && weeklyDelta > 0.02 && day >= 14) {
        return _SimResult(
          outcome: _SimOutcome.wrongDirection,
          dailyBalanceKcal: balanceSum / balanceDays,
        );
      }
      if (!losing && weeklyDelta < -0.02 && day >= 14) {
        return _SimResult(
          outcome: _SimOutcome.wrongDirection,
          dailyBalanceKcal: balanceSum / balanceDays,
        );
      }
      lastWeekW = W;
    }
  }

  // Horizon exhausted. If the last simulated week was flat-ish,
  // surface as flat (the user is at their equilibrium); else
  // horizonExceeded means "more than 2 years — revise goal".
  final finalWeeklyDelta = (W - startWeightKg) / (horizon / 7.0);
  if (finalWeeklyDelta.abs() < flatThresholdKgPerWeek) {
    return _SimResult(
      outcome: _SimOutcome.flat,
      dailyBalanceKcal: balanceSum / balanceDays,
    );
  }
  return _SimResult(
    outcome: _SimOutcome.horizonExceeded,
    dailyBalanceKcal: balanceSum / balanceDays,
  );
}

double _mifflinSexConstant(Sex s) {
  switch (s) {
    case Sex.male:
      return 5.0;
    case Sex.female:
      return -161.0;
    case Sex.other:
      // Midpoint of male / female constants — same hedge the
      // calorie estimator takes (see `domain/calories/estimate.dart`).
      return -78.0;
  }
}

/// Hall's activity-keyed PAA coefficient (kcal/kg/day). Sources:
/// Hall 2011 Lancet, Hall 2010 AJCN. Sedentary ≈ 5, very-active
/// adult ≈ 21. The ladder interpolates linearly between the two
/// to match our 5-level activity enum.
double _hallDeltaFor(ActivityLevel level) {
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

double _initialTdee({
  required double weightKg,
  required double heightCm,
  required int ageYears,
  required Sex sex,
  required double deltaPaa,
  required double kScalar,
  required double intakeForTef,
}) {
  final bmr = 10.0 * weightKg +
      6.25 * heightCm -
      5.0 * ageYears +
      _mifflinSexConstant(sex);
  return kScalar * (bmr + deltaPaa * weightKg) + 0.10 * intakeForTef;
}

// ─── Decimal helpers ───────────────────────────────────────────────────────

Decimal? _kcalBalanceAsDecimal(double balance) {
  if (balance.isNaN || balance.isInfinite) return null;
  // One decimal place is plenty for a debug surface; keep parse-safe
  // by going through `toStringAsFixed`.
  return Decimal.parse(balance.toStringAsFixed(1));
}

// ─── Smoothed weekly rate (unchanged from the prior naive impl) ────────────

/// "Close enough" — within 0.2 kg either side counts as reached.
final Decimal _reachedBandKg = Decimal.parse('0.2');

/// 28-day average per-week delta (signed). Surfaces as
/// `weeklyRateKg` on the projection result so callers (the summary
/// card's AVG / WK stat) keep a single source of truth.
Decimal? _smoothedWeeklyRateKg(List<WeightEntry> history) {
  if (history.length < 2) return null;
  final now = history.first;
  final cutoff = now.recordedOn.subtract(const Duration(days: 28));
  final window = <WeightEntry>[
    for (final e in history)
      if (!e.recordedOn.isBefore(cutoff)) e,
  ];
  if (window.length < 2) return null;
  final oldest = window.last;
  final spanDays = now.recordedOn.difference(oldest.recordedOn).inDays;
  if (spanDays <= 0) return null;
  final total = now.weightKg - oldest.weightKg;
  final perDay = (total / Decimal.fromInt(spanDays))
      .toDecimal(scaleOnInfinitePrecision: 4);
  return (perDay * Decimal.fromInt(7)).round(scale: 2);
}
