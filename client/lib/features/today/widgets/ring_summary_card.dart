import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../../../domain/day_summary.dart';
import '../../../domain/units/energy.dart';
import '../../../theme/context_extensions.dart';
import 'calorie_ring.dart';
import 'macro_bar.dart';

/// The "today vs goal" card — ring on the left, eaten/goal kv on the right
/// (compact stacks them into a single row, expanded gives them a 16-px gap
/// plus a "Burned" stub row), and three macro bars below.
///
/// **T-09 anchor**: this widget consumes a [DaySummary] directly and never
/// computes a total from a `LogEntry` list. The ring number, the eaten kv,
/// and every macro bar derive from the same instance.
///
/// **Empty / no-goal state.** When `summary.kcalTarget == null` the ring
/// renders the consumed total in the center with an "eaten" caption (not
/// "left" — there's nothing to subtract from), and the bars render at 0 %
/// fill with the value alone. Architect §9 screen-01 gotcha allows this
/// — `DaySummary.kcalTarget == null` is the "set a goal" affordance trigger
/// and the consuming screen may overlay its own CTA, but the card itself
/// stays renderable.
class RingSummaryCard extends StatelessWidget {
  const RingSummaryCard({
    required this.summary,
    this.compact = true,
    super.key,
  });

  final DaySummary summary;

  /// `true` uses the mobile mock's "ringcard" geometry (88-px ring, side-by-
  /// side kv, 4-px macro bars). `false` switches to the right-rail card
  /// (108-px ring, "Today vs goal" eyebrow header, "Burned" row, 6-px
  /// macro bars). The screen branches at the root (T-15) and threads this.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final ringSize = compact ? 88.0 : 108.0;

    final ringCenter = _ringCenter();
    final fraction = _ringFraction();

    final card = Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.line),
        borderRadius:
            BorderRadius.circular(compact ? context.radius.r3 : context.radius.r3),
      ),
      padding: EdgeInsets.all(compact ? context.space.x4 : context.space.x4 + 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (!compact) ...<Widget>[
            Text(
              'Today vs goal',
              style: context.text.eyebrow.copyWith(color: colors.ink3),
            ),
            SizedBox(height: context.space.x3),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              CalorieRing(
                progress: fraction,
                overBudget: summary.isOverKcal,
                centerLabel: ringCenter.label,
                centerCaption: ringCenter.caption,
                size: ringSize,
              ),
              SizedBox(width: context.space.x4),
              Expanded(child: _KvBlock(summary: summary, compact: compact)),
            ],
          ),
          SizedBox(height: compact ? context.space.x2 + 2 : context.space.x4),
          _MacroBars(summary: summary, compact: compact),
        ],
      ),
    );

    return card;
  }

  _RingCenter _ringCenter() {
    final target = summary.kcalTarget;
    if (target == null) {
      // No goal yet: surface the consumed total instead of a remaining count.
      return _RingCenter(
        label: formatKcal(summary.kcal),
        caption: 'eaten',
      );
    }
    final remaining = target - summary.kcal;
    if (remaining < Decimal.zero) {
      // T-05 — over budget. Show a negative "over" count.
      return _RingCenter(
        label: '-${formatKcal(remaining.abs())}',
        caption: 'over',
      );
    }
    return _RingCenter(
      label: formatKcal(remaining),
      caption: 'left',
    );
  }

  double _ringFraction() {
    final target = summary.kcalTarget;
    if (target == null || target == Decimal.zero) return 0;
    // Cap visual sweep at 1.0 — the over-budget state is signalled by color
    // (T-05) and by the "over" caption, not by sweeping past the start.
    return (summary.kcal / target).toDouble().clamp(0.0, 1.0);
  }
}

class _RingCenter {
  const _RingCenter({required this.label, required this.caption});
  final String label;
  final String caption;
}

class _KvBlock extends StatelessWidget {
  const _KvBlock({required this.summary, required this.compact});
  final DaySummary summary;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final eaten = '${formatKcal(summary.kcal)} kcal';
    final goal = summary.kcalTarget == null
        ? '—'
        : '${formatKcal(summary.kcalTarget!)} kcal';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _KvRow(label: 'Eaten', value: eaten),
        SizedBox(height: context.space.x1),
        _KvRow(label: 'Goal', value: goal),
        if (!compact) ...<Widget>[
          SizedBox(height: context.space.x1),
          // The expanded right-rail mock includes a "Burned" row stubbed
          // at "—" until activity integration ships. Carry the stub so the
          // card matches the mock's vertical rhythm.
          _KvRow(label: 'Burned', value: '—'),
        ],
        if (compact && summary.isOverKcal) ...<Widget>[
          SizedBox(height: context.space.x1),
          Text(
            'Over by ${formatKcal((summary.kcal - summary.kcalTarget!).abs())} kcal',
            style: context.text.metaNumeric.copyWith(color: colors.dangerOver),
          ),
        ],
      ],
    );
  }
}

class _KvRow extends StatelessWidget {
  const _KvRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        Expanded(
          child: Text(
            label,
            style: context.text.meta,
          ),
        ),
        Text(
          value,
          style: context.text.metaNumeric.copyWith(
            color: context.colors.ink,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _MacroBars extends StatelessWidget {
  const _MacroBars({required this.summary, required this.compact});
  final DaySummary summary;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final protein = MacroBar(
      kind: MacroKind.protein,
      value: summary.protein,
      target: summary.proteinTarget,
      compact: compact,
    );
    final carbs = MacroBar(
      kind: MacroKind.carbs,
      value: summary.carbs,
      target: summary.carbsTarget,
      compact: compact,
    );
    final fat = MacroBar(
      kind: MacroKind.fat,
      value: summary.fat,
      target: summary.fatTarget,
      compact: compact,
    );

    if (compact) {
      // Three-up row of equal width bars on the mobile mock.
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(child: protein),
          SizedBox(width: context.space.x2 + 2),
          Expanded(child: carbs),
          SizedBox(width: context.space.x2 + 2),
          Expanded(child: fat),
        ],
      );
    }

    // Expanded right-rail mock stacks the three bars vertically.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        protein,
        SizedBox(height: context.space.x3),
        carbs,
        SizedBox(height: context.space.x3),
        fat,
      ],
    );
  }
}
