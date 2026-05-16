import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../../../domain/enums.dart';
import '../../../domain/goal.dart';
import '../../../domain/units/energy.dart';
import '../../../theme/context_extensions.dart';
import '../../../widgets/empty_state.dart';

/// History list under the active-goal hero. Per architecture §9 the
/// filter rule lives at the call site (not the repository):
/// `endedOn != null OR id != active.id`. The widget accepts the full
/// goals list and applies the filter defensively so the call site can be
/// a one-liner.
///
/// Visually mirrors the mock's `.glist` / `.gitem` rows — a surface
/// card with hairline dividers, one row per historical goal showing
/// the date range, label + `Ended` pill, kcal + rate meta line, and a
/// right-aligned `N days` duration stat.
class GoalHistoryList extends StatelessWidget {
  const GoalHistoryList({
    required this.goals,
    this.activeGoalId,
    super.key,
  });

  /// Every goal the user owns.
  final List<Goal> goals;

  /// Id of the active goal, used to filter it out of history. May be null
  /// when there's no active goal (first-goal case).
  final String? activeGoalId;

  @override
  Widget build(BuildContext context) {
    // Filter: end-dated OR not the active id. Newest-started first.
    final history = <Goal>[
      for (final g in goals)
        if (g.endedOn != null || g.id != activeGoalId) g,
    ]..sort((a, b) => b.startedOn.compareTo(a.startedOn));

    if (history.isEmpty) {
      return const _EmptyHistoryCard();
    }

    final colors = context.colors;
    final tokens = context.tokens;

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(tokens.radius.r3),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(tokens.radius.r3),
        child: Column(
          children: <Widget>[
            for (var i = 0; i < history.length; i++) ...<Widget>[
              if (i > 0)
                Divider(height: 1, thickness: 1, color: colors.line2),
              _HistoryRow(goal: history[i]),
            ],
          ],
        ),
      ),
    );
  }
}

/// Bordered-card wrapper around the lifted [EmptyState] for the "no
/// prior goals" branch. T-013 — the surrounding card preserves the
/// surface/line silhouette the populated list draws, so the layout
/// doesn't shift when the user creates a second goal and history
/// flips from empty to populated. The lifted `EmptyState` covers the
/// icon + title + body composition; the card chrome lives here.
class _EmptyHistoryCard extends StatelessWidget {
  const _EmptyHistoryCard();
  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tokens = context.tokens;
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(tokens.radius.r3),
      ),
      child: const EmptyState(
        icon: Icons.flag_outlined,
        title: 'No prior goals yet',
        body: 'Past goals will show up here once you set a new one.',
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.goal});
  final Goal goal;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final colors = context.colors;

    final when = _formatRange(goal.startedOn, goal.endedOn);
    final duration = _durationDays(goal.startedOn, goal.endedOn);
    final what = _goalLabel(goal);
    final meta = _metaLine(goal);

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.space.x4,
        vertical: tokens.space.x3 + tokens.space.x05,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  when,
                  style: context.text.meta.copyWith(
                    color: colors.ink2,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
                SizedBox(height: tokens.space.x05),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        what,
                        style: context.text.body.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (goal.endedOn != null) ...<Widget>[
                      SizedBox(width: tokens.space.x1 + tokens.space.x05),
                      const _EndedPill(),
                    ],
                  ],
                ),
                SizedBox(height: tokens.space.x05),
                Text(
                  meta,
                  style: context.text.meta.copyWith(
                    color: colors.ink2,
                    fontSize: 12,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: tokens.space.x3),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Text(
                duration,
                style: context.text.meta.copyWith(
                  color: colors.ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
              SizedBox(height: tokens.space.x05),
              Text(
                'DURATION',
                style: context.text.eyebrow.copyWith(
                  color: colors.ink2,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _goalLabel(Goal g) {
    switch (g.direction) {
      case GoalDirection.lose:
        return 'Cut';
      case GoalDirection.gain:
        return 'Bulk';
      case GoalDirection.maintain:
        return 'Maintain';
    }
  }

  static String _metaLine(Goal g) {
    final kcal = g.dailyCalorieTarget;
    final kcalLabel =
        kcal == null ? '— kcal' : '${formatKcal(Decimal.fromInt(kcal))} kcal';

    final rate = g.weeklyRateKg;
    String rateLabel;
    if (rate == null) {
      rateLabel = '0 kg/week';
    } else {
      final d = rate.toDouble();
      if (d == 0) {
        rateLabel = '0 kg/week';
      } else {
        final sign = d > 0 ? '+' : '−';
        var mag = d.abs().toStringAsFixed(2);
        // Trim trailing zeros: "0.50" → "0.5", "1.00" → "1".
        if (mag.contains('.')) {
          while (mag.endsWith('0')) {
            mag = mag.substring(0, mag.length - 1);
          }
          if (mag.endsWith('.')) {
            mag = mag.substring(0, mag.length - 1);
          }
        }
        rateLabel = '$sign$mag kg/week';
      }
    }
    return '$kcalLabel · $rateLabel';
  }

  static String _formatRange(DateTime start, DateTime? end) {
    final s = _monthDay(start);
    final e = end == null ? 'now' : _monthDay(end);
    return '$s — $e';
  }

  static String _monthDay(DateTime d) {
    const months = <String>[
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[d.month - 1]} ${d.day}';
  }

  static String _durationDays(DateTime start, DateTime? end) {
    final last = end ?? DateTime.now();
    final s = DateTime(start.year, start.month, start.day);
    final l = DateTime(last.year, last.month, last.day);
    final days = l.difference(s).inDays;
    return '$days days';
  }
}

class _EndedPill extends StatelessWidget {
  const _EndedPill();
  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.space.x1 + context.space.x05,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: colors.line2,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'ENDED',
        style: context.text.eyebrow.copyWith(
          color: colors.ink2,
          fontSize: 10,
          letterSpacing: 0.06 * 10,
        ),
      ),
    );
  }
}
