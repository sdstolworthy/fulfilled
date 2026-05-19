import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../../../domain/calories/estimate.dart';
import '../../../domain/enums.dart';
import '../../../domain/goal.dart';
import '../../../domain/units/energy.dart';
import '../../../domain/units/macros.dart';
import '../../../theme/context_extensions.dart';
import '../../../widgets/primary_button.dart';

/// Dark-gradient hero card on screen 07 — the active goal.
///
/// Renders the active goal's kcal target, signed weekly-rate pill, a
/// protein/carbs/fat split bar with legend, the macro gram grid, and the
/// `Edit current` / `+ New goal` action row.
///
/// **T-01 / Screen 07 gotcha.** The macro colors on this card are the
/// *on-dark* token variants — `proteinOnDark / carbsOnDark / fatOnDark`
/// and `mutedTealOnDark` for caption ink. Do NOT derive them at the call
/// site with `.withOpacity` against the dark teal background. They are
/// real tokens, calibrated for the gradient (see colors.dart). The card
/// also paints the gradient with two literal teal stops; those stops are
/// the `accent` token and a darker sibling lifted from the mock — both
/// referenced through the token sheet (`accent` and a derived darker
/// shade computed in `_HeroBackground`).
///
/// **T-04 (UX-112, PM UX pack §4 — Goals button hierarchy fix).**
/// "Edit current" is the canonical [PrimaryButton] (the 90% case —
/// users adjust their current goal far more often than they start
/// over). "New goal" is the secondary [OutlinedButton] — the
/// "deliberate restart" affordance that should read as quieter than
/// the edit path. Previously both buttons read as primary-styled and
/// the user paused to disambiguate.
///
/// **Pure presentation widget** — all inputs arrive via constructor
/// parameters (see `specs/testing_guide.md` §4.4). The container
/// (`GoalsScreen`) reads `effectiveActiveGoalTargetsProvider` and
/// passes the resolved [CalorieEstimate] (or `null` when the profile
/// is incomplete / upstream is still hydrating) down. The provider
/// is a plain `Provider<CalorieEstimate?>` (not async), so `null` is
/// the "no override" branch and the card falls back to the stored
/// snapshot on [Goal] — no sibling skeleton widget is needed.
class GoalActiveCard extends StatelessWidget {
  const GoalActiveCard({
    required this.goal,
    required this.effective,
    required this.onEditCurrent,
    required this.onNewGoal,
    super.key,
  });

  final Goal goal;

  /// Derived live calorie + macro target. `null` when the profile is
  /// incomplete or upstream providers haven't resolved yet — the card
  /// falls back to the stored snapshot on [Goal] in that case.
  final CalorieEstimate? effective;

  final VoidCallback onEditCurrent;
  final VoidCallback onNewGoal;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tokens = context.tokens;
    final mutedTeal = colors.mutedTealOnDark;

    // Local copy so Dart's flow analysis can promote the nullable
    // through the `eff == null` checks below — instance fields can't
    // be promoted directly.
    final eff = effective;

    // Prefer the derived live target so changing activity / weight /
    // etc. on the profile page reflects here on next paint. Fall
    // back to the stored snapshot when the derived value isn't
    // available (profile incomplete, or upstream still hydrating).
    final kcalTarget = eff?.dailyTargetKcal ?? goal.dailyCalorieTarget;
    final kcalLabel = kcalTarget == null
        ? '—'
        : formatKcal(Decimal.fromInt(kcalTarget));

    // Prefer the derived macro grams when available — the kcal
    // headline above already uses the live value, so the split bar
    // and gram grid below have to track or the card disagrees with
    // itself after a profile edit.
    final proteinG = eff == null
        ? goal.proteinTargetG
        : Decimal.fromInt(eff.proteinG);
    final carbsG = eff == null
        ? goal.carbsTargetG
        : Decimal.fromInt(eff.carbsG);
    final fatG = eff == null
        ? goal.fatTargetG
        : Decimal.fromInt(eff.fatG);
    final percents = _macroPercents(proteinG, carbsG, fatG);

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            colors.accent,
            // Darker sibling for the gradient bottom stop — the mock paints
            // it at ~85% lightness of `accent`. Pinned as `accentDark` in
            // `colors.dart` so widget code never references `Colors.black`
            // to derive the darken (FX-006 / T-01).
            colors.accentDark,
          ],
        ),
        borderRadius: BorderRadius.circular(tokens.radius.r4),
      ),
      child: Padding(
        padding: EdgeInsets.all(tokens.space.x4 + tokens.space.x05),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _ActiveEyebrow(goal: goal, color: mutedTeal),
            SizedBox(height: tokens.space.x05 + tokens.space.x1),
            Text(
              _goalTitle(goal),
              style: context.text.title.copyWith(
                color: colors.surface,
                fontSize: 20,
              ),
            ),
            SizedBox(height: tokens.space.x3),
            _KcalRow(kcalLabel: kcalLabel, captionColor: mutedTeal),
            SizedBox(height: tokens.space.x3),
            _RatePill(goal: goal),
            SizedBox(height: tokens.space.x4),
            _SplitBar(percents: percents, trackColor: colors.surface.withAlpha(30)),
            SizedBox(height: tokens.space.x1 + tokens.space.x05),
            _SplitLegend(percents: percents, color: mutedTeal),
            SizedBox(height: tokens.space.x3 + tokens.space.x05),
            _MacroGrid(
              proteinG: proteinG,
              carbsG: carbsG,
              fatG: fatG,
              mutedTeal: mutedTeal,
            ),
            SizedBox(height: tokens.space.x4),
            _ActionRow(
              onEditCurrent: onEditCurrent,
              onNewGoal: onNewGoal,
            ),
          ],
        ),
      ),
    );
  }

  static String _goalTitle(Goal g) {
    final dir = g.direction;
    final rate = g.rateKgPerWeek;
    switch (dir) {
      case GoalDirection.lose:
        if (rate != null) {
          final isFast = rate >= Decimal.parse('0.75');
          return isFast ? 'Lose weight' : 'Lose weight, slowly';
        }
        return 'Lose weight';
      case GoalDirection.maintain:
        return 'Maintain';
      case GoalDirection.gain:
        return 'Gain weight';
    }
  }

  /// Returns a triple of `(protein%, carbs%, fat%)` rounded so they sum to
  /// 100. Falls back to `25 / 50 / 25` (the mock's default) when the goal
  /// has no macro targets.
  static _MacroPercents _macroPercents(
    Decimal? p,
    Decimal? c,
    Decimal? f,
  ) {
    if (p == null || c == null || f == null) {
      return const _MacroPercents(25, 50, 25);
    }
    // Convert grams → kcal contribution (4/4/9).
    final pKcal = p * Decimal.fromInt(4);
    final cKcal = c * Decimal.fromInt(4);
    final fKcal = f * Decimal.fromInt(9);
    final total = pKcal + cKcal + fKcal;
    if (total <= Decimal.zero) return const _MacroPercents(25, 50, 25);

    int pct(Decimal v) =>
        ((v / total).toDecimal(scaleOnInfinitePrecision: 4) *
                Decimal.fromInt(100))
            .round(scale: 0)
            .toBigInt()
            .toInt();

    final pp = pct(pKcal);
    final cc = pct(cKcal);
    // Force sum to 100 by giving the remainder to fat.
    final ff = 100 - pp - cc;
    return _MacroPercents(pp, cc, ff);
  }
}

/// Eyebrow row — "Active · since Apr 14".
class _ActiveEyebrow extends StatelessWidget {
  const _ActiveEyebrow({required this.goal, required this.color});
  final Goal goal;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final since = _formatMonthDay(goal.startedOn);
    return Text(
      'ACTIVE · SINCE $since',
      style: context.text.eyebrow.copyWith(color: color),
    );
  }

  static String _formatMonthDay(DateTime d) {
    const months = <String>[
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[d.month - 1]} ${d.day}';
  }
}

class _KcalRow extends StatelessWidget {
  const _KcalRow({required this.kcalLabel, required this.captionColor});
  final String kcalLabel;
  final Color captionColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        Text(
          kcalLabel,
          style: context.text.displayNumeric.copyWith(
            color: context.colors.surface,
          ),
        ),
        SizedBox(width: context.space.x2),
        Text(
          'kcal / day',
          style: context.text.meta.copyWith(color: captionColor),
        ),
      ],
    );
  }
}

class _RatePill extends StatelessWidget {
  const _RatePill({required this.goal});
  final Goal goal;

  @override
  Widget build(BuildContext context) {
    final dir = goal.direction;
    final rate = goal.rateKgPerWeek;
    final IconData icon;
    final String sign;
    switch (dir) {
      case GoalDirection.lose:
        icon = Icons.arrow_downward_rounded;
        sign = '−';
        break;
      case GoalDirection.gain:
        icon = Icons.arrow_upward_rounded;
        sign = '+';
        break;
      case GoalDirection.maintain:
        icon = Icons.horizontal_rule_rounded;
        sign = '';
        break;
    }

    final rateStr = rate == null
        ? '0 kg / week'
        : '$sign${_formatRate(rate)} kg / week';

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: context.space.x3,
          vertical: context.space.x1 + context.space.x05,
        ),
        decoration: BoxDecoration(
          color: context.colors.surface.withAlpha(31),
          borderRadius: BorderRadius.circular(context.radius.rPill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 12, color: context.colors.surface),
            SizedBox(width: context.space.x1 + context.space.x05),
            Text(
              rateStr,
              style: context.text.meta.copyWith(
                color: context.colors.surface,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatRate(Decimal rate) {
    // One decimal place. Mock shows "0.5"; round half-up through Decimal
    // arithmetic so we never let an IEEE-754 surprise reach the leaf.
    final r = rate.round(scale: 1);
    return r.toDouble().toStringAsFixed(1);
  }
}

class _SplitBar extends StatelessWidget {
  const _SplitBar({required this.percents, required this.trackColor});
  final _MacroPercents percents;
  final Color trackColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: Container(
        height: 6,
        color: trackColor,
        child: Row(
          children: <Widget>[
            Expanded(
              flex: percents.protein,
              child: Container(color: colors.proteinOnDark),
            ),
            Expanded(
              flex: percents.carbs,
              child: Container(color: colors.carbsOnDark),
            ),
            Expanded(
              flex: percents.fat,
              child: Container(color: colors.fatOnDark),
            ),
          ],
        ),
      ),
    );
  }
}

class _SplitLegend extends StatelessWidget {
  const _SplitLegend({required this.percents, required this.color});
  final _MacroPercents percents;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final s = context.text.meta.copyWith(
      color: color,
      fontSize: 11,
      fontWeight: FontWeight.w500,
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        Text('Protein ${percents.protein}%', style: s),
        Text('Carbs ${percents.carbs}%', style: s),
        Text('Fat ${percents.fat}%', style: s),
      ],
    );
  }
}

class _MacroGrid extends StatelessWidget {
  const _MacroGrid({
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
    required this.mutedTeal,
  });
  final Decimal? proteinG;
  final Decimal? carbsG;
  final Decimal? fatG;
  final Color mutedTeal;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: _MacroCell(
            label: 'Protein',
            grams: proteinG,
            kcalPerGram: 4,
            mutedTeal: mutedTeal,
          ),
        ),
        SizedBox(width: tokens.space.x2 + tokens.space.x05),
        Expanded(
          child: _MacroCell(
            label: 'Carbs',
            grams: carbsG,
            kcalPerGram: 4,
            mutedTeal: mutedTeal,
          ),
        ),
        SizedBox(width: tokens.space.x2 + tokens.space.x05),
        Expanded(
          child: _MacroCell(
            label: 'Fat',
            grams: fatG,
            kcalPerGram: 9,
            mutedTeal: mutedTeal,
          ),
        ),
      ],
    );
  }
}

class _MacroCell extends StatelessWidget {
  const _MacroCell({
    required this.label,
    required this.grams,
    required this.kcalPerGram,
    required this.mutedTeal,
  });

  final String label;
  final Decimal? grams;
  final int kcalPerGram;
  final Color mutedTeal;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final g = grams;
    final gramsLabel = g == null ? '—' : formatGrams(g);
    final kcalLabel = g == null
        ? '—'
        : '${formatKcal(g * Decimal.fromInt(kcalPerGram))} kcal';

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.space.x3,
        vertical: tokens.space.x2 + tokens.space.x05,
      ),
      decoration: BoxDecoration(
        color: context.colors.surface.withAlpha(20),
        borderRadius: BorderRadius.circular(tokens.radius.r2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label.toUpperCase(),
            style: context.text.eyebrow.copyWith(
              color: mutedTeal,
              fontSize: 10,
            ),
          ),
          SizedBox(height: tokens.space.x05),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              Flexible(
                child: Text(
                  gramsLabel,
                  style: context.text.titleNumeric.copyWith(
                    color: context.colors.surface,
                    fontSize: 18,
                  ),
                ),
              ),
              SizedBox(width: tokens.space.x05),
              Text(
                'g',
                style: context.text.meta.copyWith(
                  color: mutedTeal,
                  fontSize: 11,
                ),
              ),
            ],
          ),
          SizedBox(height: tokens.space.x05),
          Text(
            kcalLabel,
            style: context.text.meta.copyWith(
              color: mutedTeal,
              fontSize: 11,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.onEditCurrent, required this.onNewGoal});
  final VoidCallback onEditCurrent;
  final VoidCallback onNewGoal;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final c = context.colors;
    // UX-112 PM UX pack §4 — Goals button hierarchy fix.
    //
    // Edit current is the canonical [PrimaryButton] (T-04 — accent
    // CTA, the 90%-case). New goal is an [OutlinedButton] (secondary
    // action) with surface-tinted ink + border to read as quieter
    // against the dark gradient.
    //
    // Visual followup: PrimaryButton's accent fill on the active card's
    // accent-gradient background is intentionally muted but readable;
    // a future design pass may want to tint the fill against the
    // gradient (architect §8 / PM doc §4 — the v1 goal is hierarchy,
    // not a separate dark-surface PrimaryButton token).
    return Row(
      children: <Widget>[
        Expanded(
          child: KeyedSubtree(
            key: const ValueKey('goals.edit_current'),
            child: PrimaryButton(
              label: 'Edit current',
              onPressed: onEditCurrent,
              dense: true,
            ),
          ),
        ),
        SizedBox(width: tokens.space.x2 + tokens.space.x05),
        Expanded(
          child: SizedBox(
            height: 44,
            child: OutlinedButton(
              key: const ValueKey('goals.new_goal'),
              onPressed: onNewGoal,
              style: OutlinedButton.styleFrom(
                foregroundColor: c.surface,
                side: BorderSide(color: c.surface.withAlpha(120)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(tokens.radius.r1 + 2),
                ),
                textStyle: context.text.body.copyWith(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: const Text('+ New goal'),
            ),
          ),
        ),
      ],
    );
  }
}

/// Immutable triple of macro percent splits. Always sums to 100.
class _MacroPercents {
  const _MacroPercents(this.protein, this.carbs, this.fat);
  final int protein;
  final int carbs;
  final int fat;
}
