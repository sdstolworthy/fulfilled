import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/goal.dart';
import '../../../domain/units/weight.dart';
import '../../../domain/weight.dart';
import '../../../providers/goal_providers.dart';
import '../../../providers/weight_providers.dart';
import '../../../theme/context_extensions.dart';

/// The hero card at the top of screen 06.
///
/// Layout mirrors `screen_06_weight_log.html`:
/// ```
/// ┌──────────────────────────────────────────┐
/// │ 78.4 kg                       [-1.8 kg ↘] │
/// │ Latest · this morning                    │
/// │ ──────────────────────────────────────── │
/// │ START      GOAL        AVG / WK           │
/// │ 82.1 kg    74.0 kg     -0.48 kg           │
/// └──────────────────────────────────────────┘
/// ```
///
/// **Data sources.**
/// - Now value: most-recent entry from [weightHistoryProvider].
/// - Delta pill: now − weight from ~30 days ago (closest entry).
/// - Start: `Goal.startWeightKg`.
/// - Goal: `Goal.targetWeightKg`.
/// - Avg / wk: average daily delta × 7, computed over the last 28 days
///   of history (Decimal math, T-17).
///
/// **No-goal handling.** When `activeGoalProvider` throws
/// `GoalNotFoundError` the start / goal stats render as em-dashes — the
/// "now" + "this month" delta still resolve from history alone.
class WeightSummaryCard extends ConsumerWidget {
  const WeightSummaryCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final historyAsync = ref.watch(weightHistoryProvider);
    final goalAsync = ref.watch(activeGoalProvider);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.space.x5,
        context.space.x2,
        context.space.x5,
        context.space.x3,
      ),
      child: _Card(
        child: historyAsync.when(
          data: (history) => _Body(
            history: history,
            goal: goalAsync.maybeWhen(
              data: (g) => g,
              orElse: () => null,
            ),
          ),
          loading: () => const _SummarySkeleton(),
          error: (_, __) => const _SummarySkeleton(),
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.colors.surface,
        borderRadius: BorderRadius.circular(context.radius.r4),
        border: Border.all(color: context.colors.line),
      ),
      padding: EdgeInsets.all(context.space.x4),
      child: child,
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.history, required this.goal});

  final List<WeightEntry> history;
  final Goal? goal;

  @override
  Widget build(BuildContext context) {
    if (history.isEmpty) {
      return _EmptyHero(goal: goal);
    }
    // history is newest-first per repository contract.
    final now = history.first;
    final monthDelta = _monthDelta(history);
    final avgWeeklyKg = _avgWeeklyKg(history);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Semantics(
                    label: 'Current weight ${formatWeightKg(now.weightKg)} '
                        'kilograms',
                    child: _NowReadout(weightKg: now.weightKg),
                  ),
                  SizedBox(height: context.space.x05),
                  Text(
                    _latestSubtitle(now),
                    style: context.text.meta,
                  ),
                ],
              ),
            ),
            if (monthDelta != null) _DeltaPill(deltaKg: monthDelta),
          ],
        ),
        SizedBox(height: context.space.x3),
        Divider(height: 1, color: context.colors.line2),
        SizedBox(height: context.space.x3),
        Row(
          children: <Widget>[
            Expanded(
              child: _Stat(
                label: 'START',
                weightKg: goal?.startWeightKg,
              ),
            ),
            Expanded(
              child: _Stat(
                label: 'GOAL',
                weightKg: goal?.targetWeightKg,
              ),
            ),
            Expanded(
              child: _Stat(
                label: 'AVG / WK',
                weightKg: avgWeeklyKg,
                signed: true,
              ),
            ),
          ],
        ),
      ],
    );
  }

  // Delta between now and the closest entry ~30 days back. Falls back to
  // the oldest entry in `history` if no 30d-aligned point exists.
  Decimal? _monthDelta(List<WeightEntry> history) {
    if (history.length < 2) return null;
    final now = history.first;
    // Find the entry whose `recordedOn` is closest to `now - 30 days`.
    final target = now.recordedOn.subtract(const Duration(days: 30));
    WeightEntry best = history.last;
    int bestDiff = (best.recordedOn.difference(target).inDays).abs();
    for (final e in history) {
      final diff = e.recordedOn.difference(target).inDays.abs();
      if (diff < bestDiff) {
        best = e;
        bestDiff = diff;
      }
    }
    // No useful month-back point — bail out instead of fabricating a
    // delta against today itself.
    if (best.id == now.id) return null;
    return now.weightKg - best.weightKg;
  }

  // Average per-week change in kg over the last 28 days (or all history,
  // if shorter). Uses Decimal math (T-17). Signed: negative = losing.
  Decimal? _avgWeeklyKg(List<WeightEntry> history) {
    if (history.length < 2) return null;
    final now = history.first;
    final cutoff = now.recordedOn.subtract(const Duration(days: 28));
    final window = <WeightEntry>[
      for (final e in history)
        if (!e.recordedOn.isBefore(cutoff)) e,
    ];
    if (window.length < 2) return null;
    // window is newest-first → oldest is last.
    final oldest = window.last;
    final spanDays = now.recordedOn.difference(oldest.recordedOn).inDays;
    if (spanDays <= 0) return null;
    final total = now.weightKg - oldest.weightKg;
    final perDay = (total / Decimal.fromInt(spanDays))
        .toDecimal(scaleOnInfinitePrecision: 4);
    return (perDay * Decimal.fromInt(7)).round(scale: 2);
  }

  String _latestSubtitle(WeightEntry e) {
    // Mock: "Latest · this morning". We hedge with a date-based phrasing
    // since there's no reliable time-of-day signal across all entries.
    final daysAgo = DateTime.now().difference(e.recordedOn).inDays;
    if (daysAgo <= 0) return 'Latest · today';
    if (daysAgo == 1) return 'Latest · yesterday';
    return 'Latest · $daysAgo days ago';
  }
}

class _NowReadout extends StatelessWidget {
  const _NowReadout({required this.weightKg});

  final Decimal weightKg;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          formatWeightKg(weightKg),
          style: context.text.heroNumeric,
        ),
        SizedBox(width: context.space.x1),
        Text(
          'kg',
          style: context.text.body.copyWith(color: context.colors.ink2),
        ),
      ],
    );
  }
}

class _DeltaPill extends StatelessWidget {
  const _DeltaPill({required this.deltaKg});

  final Decimal deltaKg;

  @override
  Widget build(BuildContext context) {
    final negative = deltaKg < Decimal.zero;
    final isZero = deltaKg == Decimal.zero;
    final magnitude = deltaKg.abs();

    final sign = isZero ? '' : (negative ? '−' : '+');
    final label = '$sign${formatWeightKg(magnitude)} kg this month';

    final iconData = isZero
        ? Icons.horizontal_rule
        : (negative ? Icons.arrow_downward : Icons.arrow_upward);

    return Semantics(
      label: '$label change',
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: context.space.x3,
          vertical: context.space.x1,
        ),
        decoration: BoxDecoration(
          color: context.colors.accentSoft,
          borderRadius: BorderRadius.circular(context.radius.rPill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(iconData, size: 12, color: context.colors.accent),
            SizedBox(width: context.space.x1),
            Text(
              label,
              style: context.text.metaNumeric.copyWith(
                color: context.colors.accent,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.weightKg,
    this.signed = false,
  });

  final String label;
  final Decimal? weightKg;
  final bool signed;

  @override
  Widget build(BuildContext context) {
    final value = weightKg;
    final formatted = value == null
        ? '—'
        : (signed
            ? '${value < Decimal.zero ? '−' : (value > Decimal.zero ? '+' : '')}'
                '${formatWeightKg(value.abs())}'
            : formatWeightKg(value));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: context.text.eyebrow.copyWith(color: context.colors.ink2),
        ),
        SizedBox(height: context.space.x05),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: <Widget>[
            Text(formatted, style: context.text.bodyStrongNumeric),
            if (value != null) ...<Widget>[
              SizedBox(width: context.space.x05),
              Text(
                'kg',
                style: context.text.meta
                    .copyWith(color: context.colors.ink2, fontSize: 11),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _EmptyHero extends StatelessWidget {
  const _EmptyHero({required this.goal});
  final Goal? goal;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: <Widget>[
            Text('—', style: context.text.heroNumeric),
            SizedBox(width: context.space.x1),
            Text(
              'kg',
              style: context.text.body.copyWith(color: context.colors.ink2),
            ),
          ],
        ),
        SizedBox(height: context.space.x05),
        Text(
          'No entries yet',
          style: context.text.meta,
        ),
        SizedBox(height: context.space.x3),
        Divider(height: 1, color: context.colors.line2),
        SizedBox(height: context.space.x3),
        Row(
          children: <Widget>[
            Expanded(child: _Stat(label: 'START', weightKg: goal?.startWeightKg)),
            Expanded(child: _Stat(label: 'GOAL', weightKg: goal?.targetWeightKg)),
            const Expanded(child: _Stat(label: 'AVG / WK', weightKg: null, signed: true)),
          ],
        ),
      ],
    );
  }
}

// ─── Skeleton (T-08) ───────────────────────────────────────────────────────

class _SummarySkeleton extends StatelessWidget {
  const _SummarySkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _SkeletonBox(width: 120, height: 32),
            _SkeletonBox(width: 96, height: 22),
          ],
        ),
        SizedBox(height: context.space.x2),
        const _SkeletonBox(width: 140, height: 12),
        SizedBox(height: context.space.x3),
        Divider(height: 1, color: context.colors.line2),
        SizedBox(height: context.space.x3),
        Row(
          children: const <Widget>[
            Expanded(child: _SkeletonStat()),
            Expanded(child: _SkeletonStat()),
            Expanded(child: _SkeletonStat()),
          ],
        ),
      ],
    );
  }
}

class _SkeletonStat extends StatelessWidget {
  const _SkeletonStat();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const _SkeletonBox(width: 48, height: 10),
        SizedBox(height: context.space.x1),
        const _SkeletonBox(width: 64, height: 16),
      ],
    );
  }
}

class _SkeletonBox extends StatelessWidget {
  const _SkeletonBox({required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: context.colors.line2,
        borderRadius: BorderRadius.circular(context.radius.r1),
      ),
    );
  }
}
