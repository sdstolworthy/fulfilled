import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/weight.dart';
import 'package:fulfilled/domain/weight_projection.dart';

/// Pure-logic tests for `projectGoal`. The widget that renders the
/// projection is exercised by `weight_summary_card`-level tests; here
/// we pin only the math + state machine so regressions stay
/// debuggable without firing up a `ProviderContainer`.

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

void main() {
  final now = DateTime(2026, 5, 18);

  test('on-track: losing toward target yields a future ETA', () {
    // 28 days of losing 1.4 kg total → -0.35 kg/wk. Current 80, goal
    // 76.5 → 3.5 kg to lose → 10 weeks → ~70 days from `now`.
    final history = <WeightEntry>[
      _we(now, 0, '80.0'),
      _we(now, 7, '80.35'),
      _we(now, 14, '80.7'),
      _we(now, 21, '81.05'),
      _we(now, 28, '81.4'),
    ];
    final p = projectGoal(
      history: history,
      targetKg: Decimal.parse('76.5'),
      now: now,
    );
    expect(p.kind, ProjectionKind.onTrack);
    expect(p.eta, isNotNull);
    expect(
      p.eta!.isAfter(now),
      isTrue,
      reason: 'losing toward a lower target → eta is in the future',
    );
    expect(p.weeksAway, 10);
  });

  test('reached: current within ±0.2 kg of target', () {
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
    );
    expect(p.kind, ProjectionKind.reached);
    expect(p.eta, isNull);
  });

  test('off-track: gaining when goal is below current', () {
    // Current 82.0, goal 76.0 → need to lose. Trajectory is +0.3/wk
    // (gaining). That's the wrong direction.
    final history = <WeightEntry>[
      _we(now, 0, '82.0'),
      _we(now, 7, '81.7'),
      _we(now, 14, '81.4'),
      _we(now, 21, '81.1'),
      _we(now, 28, '80.8'),
    ];
    final p = projectGoal(
      history: history,
      targetKg: Decimal.parse('76.0'),
      now: now,
    );
    expect(p.kind, ProjectionKind.offTrack);
    expect(p.eta, isNull);
    expect(p.weeklyRateKg, isNotNull);
    expect(p.weeklyRateKg! > Decimal.zero, isTrue);
  });

  test('flat: trajectory below 0.05 kg/wk noise threshold', () {
    // 28 days of essentially-zero drift.
    final history = <WeightEntry>[
      _we(now, 0, '80.00'),
      _we(now, 7, '80.01'),
      _we(now, 14, '80.00'),
      _we(now, 21, '79.99'),
      _we(now, 28, '80.00'),
    ];
    final p = projectGoal(
      history: history,
      targetKg: Decimal.parse('75.0'),
      now: now,
    );
    expect(p.kind, ProjectionKind.flat);
    expect(p.eta, isNull);
  });

  test('insufficient: single entry has no trend', () {
    final history = <WeightEntry>[_we(now, 0, '80.0')];
    final p = projectGoal(
      history: history,
      targetKg: Decimal.parse('75.0'),
      now: now,
    );
    expect(p.kind, ProjectionKind.insufficientData);
  });

  test('insufficient: empty history', () {
    final p = projectGoal(
      history: const <WeightEntry>[],
      targetKg: Decimal.parse('75.0'),
      now: now,
    );
    expect(p.kind, ProjectionKind.insufficientData);
  });

  test('gain trajectory yields on-track when goal is above current', () {
    // Current 70.0, goal 75.0. Gaining ~+0.35 kg/wk.
    final history = <WeightEntry>[
      _we(now, 0, '70.0'),
      _we(now, 7, '69.65'),
      _we(now, 14, '69.3'),
      _we(now, 21, '68.95'),
      _we(now, 28, '68.6'),
    ];
    final p = projectGoal(
      history: history,
      targetKg: Decimal.parse('75.0'),
      now: now,
    );
    expect(p.kind, ProjectionKind.onTrack);
    expect(p.eta, isNotNull);
    expect(p.eta!.isAfter(now), isTrue);
  });

  test('echoes targetKg + gapKg back to caller', () {
    final history = <WeightEntry>[
      _we(now, 0, '80.0'),
      _we(now, 14, '80.5'),
      _we(now, 28, '81.0'),
    ];
    final target = Decimal.parse('76.0');
    final p = projectGoal(history: history, targetKg: target, now: now);
    expect(p.targetKg, target);
    expect(
      p.gapKg,
      Decimal.parse('-4.0'),
      reason: 'gap is signed: target − current',
    );
  });
}
