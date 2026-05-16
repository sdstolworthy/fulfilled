import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../domain/units/macros.dart';
import '../theme/context_extensions.dart';
import 'motion.dart';

/// Which macro this bar belongs to. The data-only color rule (T-03) lives
/// here — the widget never accepts an arbitrary color, only one of these
/// three discriminators.
enum MacroKind { protein, carbs, fat }

/// A single horizontal macro bar (name, value/target text, fill).
///
/// **Two layouts, one widget.** The compact mock (390 px) renders the bar
/// _above_ the name/value rows; the expanded mock renders the name/value
/// _above_ the bar. The variants are otherwise identical pixels — name
/// styling, bar thickness, color rules — so the `compact` flag controls
/// only the row ordering and the bar height.
///
/// **T-05 over-budget.** When `value > target`, the fill swaps from the
/// macro color to `AppColors.dangerOver`. The value text stays `ink`; only
/// the bar fill changes. The accessibility label includes a "−Xg over"
/// suffix so color is not the sole signal (T-20).
class MacroBar extends StatelessWidget {
  const MacroBar({
    required this.kind,
    required this.value,
    required this.target,
    this.compact = true,
    super.key,
  });

  final MacroKind kind;
  final Decimal value;

  /// Nullable to support the "no active goal" state — the bar then renders
  /// at 0% fill with the value alone (no "/ target" text).
  final Decimal? target;

  /// `true` uses the 4-px-bar / bar-above-text layout from the mobile mock;
  /// `false` uses the 6-px-bar / text-above-bar layout from the web mock.
  /// The screen branches T-15-style at its root and threads this in.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final name = _label;
    final macroColor = _color(context);

    final target = this.target;
    final hasTarget = target != null && target > Decimal.zero;
    final overBudget = hasTarget && value > target;
    final fillColor = overBudget ? colors.dangerOver : macroColor;

    // Fraction is for the bar visual only — clamp to [0, 1].
    final fraction = hasTarget
        ? (value / target).toDouble().clamp(0.0, 1.0)
        : 0.0;

    final valueLabel = formatGrams(value);
    final targetLabel = hasTarget ? formatGrams(target) : null;

    final overSuffix = overBudget
        ? _overSuffix(value - target)
        : null;

    final semantics =
        '$name $valueLabel grams${targetLabel == null ? '' : ' of $targetLabel'}'
        '${overSuffix == null ? '' : ', $overSuffix'}';

    if (compact) {
      return Semantics(
        label: semantics,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _Bar(
              fraction: fraction,
              fillColor: fillColor,
              trackColor: colors.line2,
              height: 4,
            ),
            SizedBox(height: context.space.x05 + context.space.x1),
            Text(
              name.toUpperCase(),
              style: context.text.eyebrow,
            ),
            SizedBox(height: context.space.x05),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: <Widget>[
                Flexible(
                  child: Text(
                    targetLabel == null
                        ? '$valueLabel g'
                        : '$valueLabel / $targetLabel g',
                    style: context.text.metaNumeric.copyWith(
                      color: colors.ink,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (overSuffix != null) ...<Widget>[
                  SizedBox(width: context.space.x1),
                  Text(
                    overSuffix,
                    style: context.text.metaNumeric.copyWith(
                      color: colors.dangerOver,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      );
    }

    // Expanded layout: text row above a 6-px bar.
    return Semantics(
      label: semantics,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              Expanded(
                child: Text(
                  name.toUpperCase(),
                  style: context.text.eyebrow,
                ),
              ),
              Text(
                '$valueLabel g',
                style: context.text.metaNumeric.copyWith(
                  color: colors.ink,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (targetLabel != null) ...<Widget>[
                SizedBox(width: context.space.x1),
                Text(
                  '/ $targetLabel',
                  style: context.text.metaNumeric.copyWith(
                    color: colors.ink2,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
              if (overSuffix != null) ...<Widget>[
                SizedBox(width: context.space.x2),
                Text(
                  overSuffix,
                  style: context.text.metaNumeric.copyWith(
                    color: colors.dangerOver,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
          SizedBox(height: context.space.x1),
          _Bar(
            fraction: fraction,
            fillColor: fillColor,
            trackColor: colors.line2,
            height: 6,
          ),
        ],
      ),
    );
  }

  String get _label {
    switch (kind) {
      case MacroKind.protein:
        return 'Protein';
      case MacroKind.carbs:
        return 'Carbs';
      case MacroKind.fat:
        return 'Fat';
    }
  }

  Color _color(BuildContext context) {
    final c = context.colors;
    switch (kind) {
      case MacroKind.protein:
        return c.protein;
      case MacroKind.carbs:
        return c.carbs;
      case MacroKind.fat:
        return c.fat;
    }
  }

  String _overSuffix(Decimal over) {
    // `over` is already positive (value - target > 0). Use the macro
    // formatter so 8.3 stays one decimal and 30 stays integer.
    return '-${formatGrams(over)} g over';
  }
}

class _Bar extends StatelessWidget {
  const _Bar({
    required this.fraction,
    required this.fillColor,
    required this.trackColor,
    required this.height,
  });

  final double fraction;
  final Color fillColor;
  final Color trackColor;
  final double height;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(height / 2);
    // T-016: animate `fraction` over 400 ms with `easeInOut` (the user's
    // stateful-change curve) via `TweenAnimationBuilder`. The fill color
    // is interpolated implicitly: when it flips (macro → dangerOver),
    // `AnimatedContainer` cross-fades the background over the same 400 ms
    // so the over-budget transition reads as a single coordinated motion
    // rather than a snap. `motion(context, …)` collapses both durations
    // to zero when the user has reduce-motion enabled.
    final fillDuration = motion(context, const Duration(milliseconds: 400));
    return ClipRRect(
      borderRadius: radius,
      child: Container(
        height: height,
        color: trackColor,
        child: Align(
          alignment: Alignment.centerLeft,
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: fraction),
            duration: fillDuration,
            curve: Curves.easeInOut,
            builder: (context, value, _) {
              return FractionallySizedBox(
                widthFactor: value,
                child: AnimatedContainer(
                  duration: fillDuration,
                  curve: Curves.easeInOut,
                  color: fillColor,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
