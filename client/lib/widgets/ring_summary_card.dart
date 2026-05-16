import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/day_summary.dart';
import '../domain/units/energy.dart';
import '../providers/calorie_providers.dart';
import '../providers/log_providers.dart';
import '../theme/context_extensions.dart';
import 'calorie_ring.dart';
import 'macro_bar.dart';
import 'skeleton.dart';

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
          // UX-110 / F10 — "N / 7 days logged this week" pill. Renders
          // between the ring row and the macro bars on both compact and
          // expanded card paths. Hidden when the week count is 0; ink2
          // for 1..6, accent at 7. See architect_ux_pack.md §7.3.
          const _WeekProgressPill(),
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
          // The "Burned" row is provider-backed (T-020 / B8): the value
          // is derived from `meProvider` via the canonical Mifflin-St
          // Jeor TDEE math. On loading we render a skeleton (T-08); on
          // error we silently fall back to `'—'` so an incomplete
          // profile doesn't surface a stack trace in the right rail.
          const _BurnedKvRow(),
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

/// Provider-backed "Burned" row. Lives next to `_KvBlock` so it can
/// share the row chrome with the surrounding kv rows.
///
/// **Loading**: a [Skeleton] block sized to match a `_KvRow`'s text
/// line so the right-rail layout doesn't shift when the value
/// resolves (T-08).
/// **Error**: silently falls back to `'—'` (don't surface).
class _BurnedKvRow extends ConsumerWidget {
  const _BurnedKvRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final burned = ref.watch(caloriesBurnedTodayProvider);
    return burned.when(
      data: (kcal) =>
          _KvRow(label: 'Burned', value: '${formatKcal(kcal)} kcal'),
      loading: () => const _KvRowSkeleton(label: 'Burned'),
      error: (_, __) => const _KvRow(label: 'Burned', value: '—'),
    );
  }
}

/// Loading-state row composition for the "Burned" row. Matches the
/// vertical rhythm of `_KvRow` (a single baseline-aligned line of
/// numeric metadata) so the surrounding kv block doesn't jump when
/// the provider resolves.
class _KvRowSkeleton extends StatelessWidget {
  const _KvRowSkeleton({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: Text(
            label,
            style: context.text.meta,
          ),
        ),
        // Width and height match the rendered `formatKcal(kcal) kcal`
        // glyph block (≈ 56 px / 12 px) so the skeleton occupies the
        // same footprint as the eventual value text.
        const Skeleton(height: 12, width: 56),
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

    // A11y (UX-112, PM UX pack §6): wrap the three macro bars in a
    // single `MergeSemantics` so the screen-reader announcement is one
    // statement — "protein 56 of 80 grams, carbs 120 of 240 grams, fat
    // 33 of 60 grams" — instead of three independent nodes the user
    // has to step through. T-20 honoured (consolidated label is the
    // single announcement surface for the macro row).
    if (compact) {
      // Three-up row of equal width bars on the mobile mock.
      return MergeSemantics(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(child: protein),
            SizedBox(width: context.space.x2 + 2),
            Expanded(child: carbs),
            SizedBox(width: context.space.x2 + 2),
            Expanded(child: fat),
          ],
        ),
      );
    }

    // Expanded right-rail mock stacks the three bars vertically.
    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          protein,
          SizedBox(height: context.space.x3),
          carbs,
          SizedBox(height: context.space.x3),
          fat,
        ],
      ),
    );
  }
}

/// "N / 7 days logged this week" pill — F10 (UX-110). Renders inside
/// [RingSummaryCard] between the ring row and the macro bars; mount
/// site is shared by compact and expanded card paths. Hidden when the
/// week count is 0 (the empty-state ring already carries enough
/// signal); rendered in `ink2` for 1..6; rendered in `accent` at 7.
///
/// **Not routable.** PM doc §2 F10 AC: the pill is read-only — no
/// `InkWell`, no `GestureDetector`, no tap target. The screen-reader
/// announcement is a single Semantics node ("This week, four of seven
/// days logged" — T-20); the inner Text Semantics are excluded so the
/// node is the only announcement surface.
///
/// **No celebration.** PM doc §2 F10 forbids animation, scale, fire
/// emoji, or haptic at 7/7. The accent colour switch is the entire
/// signal.
class _WeekProgressPill extends ConsumerWidget {
  const _WeekProgressPill();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final countAsync = ref.watch(weeklyLogDaysProvider);
    final count = countAsync.valueOrNull ?? 0;
    // Hidden at 0 (PM doc §2 F10 AC). Loading and error states also
    // fall through here — a transient blink before the count resolves
    // is the right behavior; the next mutation re-ticks the provider.
    if (count == 0) return const SizedBox.shrink();
    final colors = context.colors;
    final isFullWeek = count == 7;
    return Padding(
      padding: EdgeInsets.only(top: context.space.x1),
      child: Semantics(
        container: true,
        label: 'This week, ${_spellSmallNumber(count)} of seven days logged',
        excludeSemantics: true,
        child: Text(
          'This week · $count/7 days logged',
          style: context.text.meta.copyWith(
            color: isFullWeek ? colors.accent : colors.ink2,
            fontWeight: isFullWeek ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  /// Spell 1..7 for the Semantics label so the screen-reader reads
  /// "four of seven days logged" rather than "4 of 7 days logged"
  /// (which TalkBack / VoiceOver render as "four of seven" but
  /// inconsistently across locales). The visible Text keeps the
  /// numeric form for compactness.
  static String _spellSmallNumber(int n) {
    const words = <String>[
      'zero',
      'one',
      'two',
      'three',
      'four',
      'five',
      'six',
      'seven',
    ];
    if (n < 0 || n >= words.length) return '$n';
    return words[n];
  }
}
