import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../../../domain/enums.dart';
import '../../../domain/nutrition.dart';
import '../../../domain/units/units.dart';
import '../../../theme/context_extensions.dart';

/// Per-100 g nutrition panel.
///
/// **T-21 (Display Units Principle).** Sodium renders via [formatSodiumMg]
/// suffixed with ` mg`. Macros render via [formatGrams] suffixed with ` g`.
/// Energy renders via [formatKcal] suffixed with ` kcal`. The presentation
/// model (`NutritionPer100g`) already exposes `sodiumMg` — no inline
/// conversions in this widget.
///
/// **Per-100 g basis is non-negotiable** (PM Display Units Principle).
/// The panel header literally reads "Per 100 g" — never "per serving".
///
/// **Source-aware meta (architect §10 Q10).** Top-right meta shows
/// `OFF data · quality X.XX` only when `source == off` AND a quality
/// score is present. For USDA we show `USDA data`. For user customs we
/// show no meta (the eyebrow on the hero already communicates "My
/// foods").
class NutritionTable extends StatelessWidget {
  const NutritionTable({
    required this.nutrition,
    required this.source,
    this.qualityScore,
    super.key,
  });

  final NutritionPer100g nutrition;
  final FoodSource source;

  /// API integer 0..100. Rendered as `X.XX` per the mock.
  final int? qualityScore;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.colors.surface,
        border: Border.all(color: context.colors.line),
        borderRadius: BorderRadius.circular(context.radius.r3),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: context.space.x4,
        vertical: context.space.x05,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _Header(source: source, qualityScore: qualityScore),
          _DividerLine(color: context.colors.line2),
          _Row(
            label: 'Calories',
            value: nutrition.energyKcal,
            unit: 'kcal',
            formatter: formatKcal,
          ),
          _Row(
            label: 'Protein',
            value: nutrition.proteinG,
            unit: 'g',
            formatter: formatGrams,
          ),
          _Row(
            label: 'Carbohydrate',
            value: nutrition.carbsG,
            unit: 'g',
            formatter: formatGrams,
          ),
          if (nutrition.sugarG != null)
            _Row(
              label: 'of which sugars',
              value: nutrition.sugarG,
              unit: 'g',
              formatter: formatGrams,
              sub: true,
            ),
          _Row(
            label: 'Fat',
            value: nutrition.fatG,
            unit: 'g',
            formatter: formatGrams,
          ),
          if (nutrition.saturatedFatG != null)
            _Row(
              label: 'saturated',
              value: nutrition.saturatedFatG,
              unit: 'g',
              formatter: formatGrams,
              sub: true,
            ),
          if (nutrition.fiberG != null)
            _Row(
              label: 'Fiber',
              value: nutrition.fiberG,
              unit: 'g',
              formatter: formatGrams,
            ),
          if (nutrition.sodiumMg != null)
            _Row(
              label: 'Sodium',
              value: nutrition.sodiumMg,
              unit: 'mg',
              formatter: formatSodiumMg,
              isLast: true,
            ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.source, required this.qualityScore});

  final FoodSource source;
  final int? qualityScore;

  @override
  Widget build(BuildContext context) {
    final meta = _metaText(source, qualityScore);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.space.x2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: <Widget>[
          Expanded(
            child: Text(
              'Per 100 g',
              style: context.text.bodyStrong.copyWith(fontSize: 13),
            ),
          ),
          if (meta != null)
            Text(
              meta,
              style: context.text.metaNumeric.copyWith(fontSize: 11),
            ),
        ],
      ),
    );
  }

  static String? _metaText(FoodSource source, int? qualityScore) {
    switch (source) {
      case FoodSource.off:
        if (qualityScore == null) return 'OFF data';
        final pretty = (qualityScore / 100)
            .toStringAsFixed(2); // 86 → "0.86"
        return 'OFF data · quality $pretty';
      case FoodSource.usda:
        return 'USDA data';
      case FoodSource.user:
        // T-10 sibling: custom foods carry no source-meta in the panel;
        // the hero eyebrow already says "My foods".
        return null;
    }
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.value,
    required this.unit,
    required this.formatter,
    this.sub = false,
    this.isLast = false,
  });

  final String label;
  final Decimal? value;
  final String unit;
  final String Function(Decimal, {String? locale}) formatter;
  final bool sub;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final displayValue =
        value == null ? '—' : '${formatter(value!)} $unit';
    final labelStyle = sub
        ? context.text.meta.copyWith(fontSize: 12)
        : context.text.body.copyWith(fontSize: 13);
    final valueStyle = sub
        ? context.text.metaNumeric.copyWith(fontSize: 12)
        : context.text.bodyStrongNumeric.copyWith(fontSize: 13);

    return Container(
      padding: EdgeInsets.fromLTRB(
        sub ? context.space.x3 : 0,
        context.space.x2 + 1,
        0,
        context.space.x2 + 1,
      ),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: isLast ? Colors.transparent : context.colors.line2,
          ),
        ),
      ),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label, style: labelStyle)),
          Text(displayValue, style: valueStyle),
        ],
      ),
    );
  }
}

class _DividerLine extends StatelessWidget {
  const _DividerLine({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) =>
      Container(height: 1, color: color);
}
