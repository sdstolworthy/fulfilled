import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../../../domain/food.dart';
import '../../../domain/serving.dart';
import '../../../domain/unit.dart';
import '../../../domain/units/units.dart';
import '../../../theme/context_extensions.dart';

/// Per-default-serving summary card. Big kcal figure on the left, three
/// macro mini-stats on the right. Mirrors the `summarycard` block in
/// `screen_03_food_detail.html`.
///
/// **Unit discipline (T-21).** kcal via [formatKcal]; macros via
/// [formatGrams]. No raw `Decimal.toString()` reaches a widget.
class FoodSummaryCard extends StatelessWidget {
  const FoodSummaryCard({required this.food, super.key});

  final Food food;

  @override
  Widget build(BuildContext context) {
    final defaultServing = _defaultServing(food);
    final perServingKcal = food.caloriesPerDefaultServing;
    final macros = _macrosForServing(food, defaultServing);

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.space.x5),
      child: Container(
        decoration: BoxDecoration(
          color: context.colors.surface,
          border: Border.all(color: context.colors.line),
          borderRadius: BorderRadius.circular(context.radius.r3),
        ),
        padding: EdgeInsets.all(context.space.x4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Expanded(
              child: _KcalBlock(
                kcal: perServingKcal,
                servingLabel: defaultServing?.name,
                amountLabel: defaultServing == null
                    ? null
                    : formatAmountUnit(
                        defaultServing.amount, defaultServing.unit),
              ),
            ),
            if (macros != null)
              _MacroMiniRow(
                proteinG: macros.proteinG,
                carbsG: macros.carbsG,
                fatG: macros.fatG,
              ),
          ],
        ),
      ),
    );
  }

  static Serving? _defaultServing(Food food) {
    if (food.servings.isEmpty) return null;
    for (final s in food.servings) {
      if (s.isDefault) return s;
    }
    return food.servings.first;
  }

  /// Per Ask 10 nutrition lives on the serving — no per-100g math.
  /// `food` retained on the signature for source-compat.
  static _Macros? _macrosForServing(Food food, Serving? serving) {
    if (serving == null) return null;
    return _Macros(
      proteinG: serving.proteinG,
      carbsG: serving.carbsG,
      fatG: serving.fatG,
    );
  }
}

class _Macros {
  const _Macros({this.proteinG, this.carbsG, this.fatG});
  final Decimal? proteinG;
  final Decimal? carbsG;
  final Decimal? fatG;
}

class _KcalBlock extends StatelessWidget {
  const _KcalBlock({
    required this.kcal,
    required this.servingLabel,
    required this.amountLabel,
  });

  final Decimal? kcal;
  final String? servingLabel;
  final String? amountLabel;

  @override
  Widget build(BuildContext context) {
    final kcalText = kcal == null ? '—' : formatKcal(kcal!);
    final sub = <String?>[
      if (servingLabel != null) 'per $servingLabel',
      if (amountLabel != null && amountLabel != servingLabel) amountLabel,
    ].whereType<String>().join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        RichText(
          text: TextSpan(
            style: context.text.heroNumeric.copyWith(fontSize: 32),
            children: <InlineSpan>[
              TextSpan(text: kcalText),
              TextSpan(
                text: ' kcal',
                style: context.text.meta.copyWith(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        if (sub.isNotEmpty) ...<Widget>[
          SizedBox(height: context.space.x1),
          Text(sub, style: context.text.meta.copyWith(fontSize: 12)),
        ],
      ],
    );
  }
}

class _MacroMiniRow extends StatelessWidget {
  const _MacroMiniRow({
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
  });

  final Decimal? proteinG;
  final Decimal? carbsG;
  final Decimal? fatG;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _MiniMacro(
          label: 'Protein',
          value: proteinG,
          color: context.colors.protein,
        ),
        SizedBox(width: context.space.x3),
        _MiniMacro(
          label: 'Carbs',
          value: carbsG,
          color: context.colors.carbs,
        ),
        SizedBox(width: context.space.x3),
        _MiniMacro(
          label: 'Fat',
          value: fatG,
          color: context.colors.fat,
        ),
      ],
    );
  }
}

class _MiniMacro extends StatelessWidget {
  const _MiniMacro({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final Decimal? value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final text = value == null ? '—' : '${formatGrams(value!)} g';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          text,
          style: context.text.bodyStrongNumeric.copyWith(
            color: color,
            fontSize: 14,
          ),
        ),
        SizedBox(height: context.space.x05),
        Text(
          label.toUpperCase(),
          style: context.text.eyebrow.copyWith(
            fontSize: 10,
            letterSpacing: 0.08 * 10,
          ),
        ),
      ],
    );
  }
}
