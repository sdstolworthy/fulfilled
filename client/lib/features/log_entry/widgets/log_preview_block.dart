import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../../../domain/food.dart';
import '../../../domain/serving.dart';
import '../../../domain/units/energy.dart';
import '../../../domain/units/macros.dart';
import '../../../theme/context_extensions.dart';

/// Accent-tinted "Will log" block showing the live nutrition preview.
///
/// Math: `nutrition_per_100g × (serving.grams / 100) × quantity`. The
/// hero kcal number is rendered with [formatKcal] (integer); macro
/// grams are rendered with [formatGrams] (integer >=10 g, 1 dp <10 g).
///
/// **T-04 gotcha (per architecture §9 Screen 04).** The accent block is
/// the only place a screen uses accent decoratively, and even here the
/// rule is precise:
///
/// - Container background = `accentSoft`, border = `accentLine`.
/// - "Will log" label + kcal hero = `accent`.
/// - Macro **names** ("P", "C", "F") = `accent`.
/// - Macro **values** = `ink` (NOT the macro tokens — T-03 is reserved
///   for bars/dots, and the inline preview isn't one).
class LogPreviewBlock extends StatelessWidget {
  const LogPreviewBlock({
    super.key,
    required this.food,
    required this.serving,
    required this.quantity,
  });

  final Food food;
  final Serving serving;
  final Decimal quantity;

  Decimal _scaledOrZero(Decimal? perServing) {
    if (perServing == null) return Decimal.zero;
    return perServing * quantity;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = context.radius;
    final space = context.space;

    // Per Ask 10 nutrition lives on the serving; entry math is just
    // `serving.<field> × quantity`. `food` stays on the signature for
    // source-compat with call-sites.
    final kcal = serving.kcal * quantity;
    final protein = _scaledOrZero(serving.proteinG);
    final carbs = _scaledOrZero(serving.carbsG);
    final fat = _scaledOrZero(serving.fatG);

    return Container(
      decoration: BoxDecoration(
        color: colors.accentSoft,
        border: Border.all(color: colors.accentLine),
        borderRadius: BorderRadius.circular(radius.r2),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: space.x3 + 2,
        vertical: space.x3,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'WILL LOG',
                  style: context.text.eyebrow.copyWith(
                    color: colors.accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: space.x05 + 2),
                RichText(
                  text: TextSpan(
                    style: context.text.heroNumeric.copyWith(
                      fontSize: 24,
                      color: colors.accent,
                    ),
                    children: <InlineSpan>[
                      TextSpan(text: formatKcal(kcal)),
                      TextSpan(
                        text: ' kcal',
                        style: context.text.meta.copyWith(
                          color: colors.accent,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: space.x1),
                Row(
                  children: <Widget>[
                    _MacroChip(letter: 'P', grams: protein),
                    SizedBox(width: space.x2 + 2),
                    _MacroChip(letter: 'C', grams: carbs),
                    SizedBox(width: space.x2 + 2),
                    _MacroChip(letter: 'F', grams: fat),
                  ],
                ),
              ],
            ),
          ),
          Icon(
            Icons.check_circle_outline,
            size: 26,
            color: colors.accent,
          ),
        ],
      ),
    );
  }
}

class _MacroChip extends StatelessWidget {
  const _MacroChip({required this.letter, required this.grams});

  final String letter;
  final Decimal grams;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return RichText(
      text: TextSpan(
        style: context.text.meta.copyWith(fontSize: 11),
        children: <InlineSpan>[
          TextSpan(
            text: '$letter ',
            style: TextStyle(
              color: colors.accent,
              fontWeight: FontWeight.w600,
            ),
          ),
          TextSpan(
            text: '${formatGrams(grams)} g',
            style: TextStyle(
              color: colors.ink,
              fontWeight: FontWeight.w600,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
