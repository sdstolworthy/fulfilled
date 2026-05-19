import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../domain/day_summary.dart';
import '../domain/units/energy.dart';
import '../theme/context_extensions.dart';
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
///
/// **Passive view (testing_guide.md §4.4).** This widget is a pure
/// presentation leaf — it imports nothing from `flutter_riverpod`. The two
/// async-backed surfaces (`Burned` kv row + `This week · N/7` pill) take
/// their resolved values via constructor parameters; the parent container
/// reads `caloriesBurnedTodayProvider` and `weeklyLogDaysProvider` and
/// passes the resolved values down. Pair with [RingSummaryCardSkeleton]
/// for the loading branch where the upstream `DaySummary` itself is not
/// yet available.
class RingSummaryCard extends StatelessWidget {
  const RingSummaryCard({
    required this.summary,
    this.compact = true,
    this.burnedKcal,
    this.weeklyLogDays = 0,
    super.key,
  });

  final DaySummary summary;

  /// `true` uses the mobile mock's "ringcard" geometry (88-px ring, side-by-
  /// side kv, 4-px macro bars). `false` switches to the right-rail card
  /// (108-px ring, "Today vs goal" eyebrow header, "Burned" row, 6-px
  /// macro bars). The screen branches at the root (T-15) and threads this.
  final bool compact;

  /// Resolved "Burned" kcal value for the expanded right-rail card (T-020
  /// / B8). `null` renders the silent `—` fallback — used for both the
  /// loading branch (a single brief `—` frame before the value lands)
  /// and the error branch (incomplete profile / missing weight). Ignored
  /// when `compact == true` (the compact variant omits the Burned row).
  ///
  /// The pre-refactor leaf rendered a [Skeleton] block during the
  /// upstream `caloriesBurnedTodayProvider`'s loading state; under the
  /// passive-view rule (testing_guide.md §4.4) the loading vs error
  /// distinction would require either an `AsyncValue` parameter
  /// (re-importing Riverpod into the leaf) or a parallel `bool` flag.
  /// `meProvider` resolves on the first frame in practice, so the
  /// degraded behavior is materially equivalent for the user and lets
  /// the leaf stay Riverpod-free.
  final Decimal? burnedKcal;

  /// Resolved "N / 7 days logged this week" count for the F10 pill
  /// (UX-110). `0` hides the pill entirely (PM doc §2 F10 AC), which
  /// also serves as the loading / error / genuinely-empty fall-through
  /// state — a transient blink before the count resolves is the right
  /// behavior; the next mutation re-ticks the upstream provider.
  final int weeklyLogDays;

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
              Expanded(
                child: _KvBlock(
                  summary: summary,
                  compact: compact,
                  burnedKcal: burnedKcal,
                ),
              ),
            ],
          ),
          // UX-110 / F10 — "N / 7 days logged this week" pill. Renders
          // between the ring row and the macro bars on both compact and
          // expanded card paths. Hidden when the week count is 0; ink2
          // for 1..6, accent at 7. See architect_ux_pack.md §7.3.
          _WeekProgressPill(count: weeklyLogDays),
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

/// Loading-state sibling for [RingSummaryCard]. Renders the card-sized
/// surface chrome so the surrounding layout doesn't shift when the
/// upstream `DaySummary` resolves. The container picks this widget for
/// the `AsyncLoading` branch of `daySummaryProvider(date)`.
class RingSummaryCardSkeleton extends StatelessWidget {
  const RingSummaryCardSkeleton({this.compact = true, super.key});

  /// Mirrors the geometry switch on [RingSummaryCard]. Compact uses the
  /// 196-px mobile card height (no Burned row, no eyebrow header);
  /// expanded uses the 296-px right-rail card height.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = BorderRadius.circular(context.radius.r3);
    final height = compact ? 196.0 : 296.0;
    return Semantics(
      label: 'Loading today summary',
      liveRegion: false,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border.all(color: colors.line),
          borderRadius: radius,
        ),
      ),
    );
  }
}

class _RingCenter {
  const _RingCenter({required this.label, required this.caption});
  final String label;
  final String caption;
}

class _KvBlock extends StatelessWidget {
  const _KvBlock({
    required this.summary,
    required this.compact,
    required this.burnedKcal,
  });
  final DaySummary summary;
  final bool compact;
  final Decimal? burnedKcal;

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
          // The "Burned" row is provider-backed upstream (T-020 / B8):
          // the value is derived from `meProvider` via the canonical
          // Mifflin-St Jeor TDEE math. The container resolves it and
          // passes it down; this leaf renders the formatted value when
          // it's non-null and silently falls back to `'—'` otherwise.
          _KvRow(
            label: 'Burned',
            value: burnedKcal == null
                ? '—'
                : '${formatKcal(burnedKcal!)} kcal',
          ),
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
class _WeekProgressPill extends StatelessWidget {
  const _WeekProgressPill({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    // Hidden at 0 (PM doc §2 F10 AC). Loading and error states from the
    // upstream provider also resolve here as 0 in the container — a
    // transient blink before the count resolves is the right behavior;
    // the next mutation re-ticks the provider and the parent rebuilds.
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
