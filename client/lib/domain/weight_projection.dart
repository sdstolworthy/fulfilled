import 'package:decimal/decimal.dart';

import 'weight.dart';

/// Projection of when the user will hit their target weight at their
/// current observed trajectory.
///
/// "Observed trajectory" is the same 28-day per-week delta the weight
/// summary card already renders as AVG / WK — projection is purely a
/// re-interpretation of that number against the gap to target, so the
/// two stats can never disagree. Math is `Decimal` end-to-end (T-17);
/// the only `.toDouble()` is at the `Duration` boundary.
class GoalProjection {
  const GoalProjection({
    required this.kind,
    required this.targetKg,
    required this.gapKg,
    required this.weeklyRateKg,
    this.eta,
    this.weeksAway,
  });

  final ProjectionKind kind;

  /// The active goal's `targetWeightKg` — echoed back so the renderer
  /// can format the headline `"Reach 74.0 kg by …"` without re-watching
  /// `activeGoalProvider`.
  final Decimal targetKg;

  /// Signed gap to target (`target − current`). Negative when the user
  /// is currently above the target weight, positive when below. Encoded
  /// so callers don't have to recompute it to decide trajectory sign.
  final Decimal gapKg;

  /// Observed weekly delta (signed) — negative = losing, positive =
  /// gaining. Sourced from the 28-day window the summary card uses.
  /// Null when the trend window is empty (history too short).
  final Decimal? weeklyRateKg;

  /// Projected ETA date. Non-null only for [ProjectionKind.onTrack].
  final DateTime? eta;

  /// Whole weeks to ETA. Non-null only for [ProjectionKind.onTrack].
  final int? weeksAway;
}

enum ProjectionKind {
  /// Trajectory is in the right direction and large enough to project;
  /// [GoalProjection.eta] / [GoalProjection.weeksAway] are populated.
  onTrack,

  /// Already within the "close enough" band of the target (±0.2 kg).
  reached,

  /// Trajectory's sign opposes the gap — the user is moving away from
  /// the target.
  offTrack,

  /// Trajectory's magnitude is below the noise threshold (0.05 kg/wk)
  /// so an ETA would be misleading.
  flat,

  /// History too short to compute a 28-day window at all.
  insufficientData,
}

/// Closed-form, side-effect-free projection. Anchors ETA at [now] —
/// not the most recent entry's `recordedOn` — so the rendered date
/// matches the user's calendar expectation ("from today"). The minor
/// loss of fidelity from a stale weigh-in is acceptable; the
/// trajectory itself is the load-bearing signal.
GoalProjection projectGoal({
  required List<WeightEntry> history,
  required Decimal targetKg,
  required DateTime now,
}) {
  if (history.isEmpty) {
    return GoalProjection(
      kind: ProjectionKind.insufficientData,
      targetKg: targetKg,
      gapKg: Decimal.zero,
      weeklyRateKg: null,
    );
  }
  // Contract: `weightHistoryProvider` is newest-first.
  final current = history.first.weightKg;
  final gap = targetKg - current;

  // Within band → already reached. 0.2 kg ≈ daily-fluctuation noise;
  // tighter than that and a 78.3-kg user with a 78.0-kg goal would
  // see a spurious ETA two days out.
  if (gap.abs() <= _reachedBandKg) {
    return GoalProjection(
      kind: ProjectionKind.reached,
      targetKg: targetKg,
      gapKg: gap,
      weeklyRateKg: _weeklyRateKg(history),
    );
  }

  final rate = _weeklyRateKg(history);
  if (rate == null) {
    return GoalProjection(
      kind: ProjectionKind.insufficientData,
      targetKg: targetKg,
      gapKg: gap,
      weeklyRateKg: null,
    );
  }

  if (rate.abs() < _flatThresholdKg) {
    return GoalProjection(
      kind: ProjectionKind.flat,
      targetKg: targetKg,
      gapKg: gap,
      weeklyRateKg: rate,
    );
  }

  // Sign mismatch → trending the wrong way.
  final losingNeeded = gap < Decimal.zero;
  final gaining = rate > Decimal.zero;
  if (losingNeeded == gaining) {
    return GoalProjection(
      kind: ProjectionKind.offTrack,
      targetKg: targetKg,
      gapKg: gap,
      weeklyRateKg: rate,
    );
  }

  // Both signed and aligned → weeks is positive.
  final weeks = (gap / rate).toDecimal(scaleOnInfinitePrecision: 4);
  final days = (weeks * Decimal.fromInt(7))
      .round(scale: 0)
      .toBigInt()
      .toInt();
  final today = DateTime(now.year, now.month, now.day);
  final eta = today.add(Duration(days: days));
  final weeksWhole = weeks.abs().round(scale: 0).toBigInt().toInt();

  return GoalProjection(
    kind: ProjectionKind.onTrack,
    targetKg: targetKg,
    gapKg: gap,
    weeklyRateKg: rate,
    eta: eta,
    weeksAway: weeksWhole,
  );
}

/// "Close enough" — within 0.2 kg either side counts as reached.
final Decimal _reachedBandKg = Decimal.parse('0.2');

/// Below 0.05 kg/wk we treat the trajectory as flat — any ETA would
/// be in the high triple digits of weeks and meaningless.
final Decimal _flatThresholdKg = Decimal.parse('0.05');

/// 28-day average per-week delta (signed). Mirrors the AVG / WK
/// computation in `WeightSummaryCard` so the two can never disagree.
/// Returns null when fewer than two entries fall inside the window.
Decimal? _weeklyRateKg(List<WeightEntry> history) {
  if (history.length < 2) return null;
  final now = history.first;
  final cutoff = now.recordedOn.subtract(const Duration(days: 28));
  final window = <WeightEntry>[
    for (final e in history)
      if (!e.recordedOn.isBefore(cutoff)) e,
  ];
  if (window.length < 2) return null;
  // window inherits the newest-first ordering of `history`.
  final oldest = window.last;
  final spanDays = now.recordedOn.difference(oldest.recordedOn).inDays;
  if (spanDays <= 0) return null;
  final total = now.weightKg - oldest.weightKg;
  final perDay = (total / Decimal.fromInt(spanDays))
      .toDecimal(scaleOnInfinitePrecision: 4);
  return (perDay * Decimal.fromInt(7)).round(scale: 2);
}
