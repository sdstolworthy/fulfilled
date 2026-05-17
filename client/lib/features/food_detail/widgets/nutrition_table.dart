import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../../../domain/enums.dart';
import '../../../domain/serving.dart';
import '../../../domain/unit.dart';
import '../../../domain/units/units.dart';
import '../../../theme/context_extensions.dart';

/// Per-serving nutrition panel. Per Ask 10 nutrition lives on each
/// [Serving] — the panel header reads the serving's label (or its
/// rendered amount+unit) instead of the old "Per 100 g."
///
/// **T-21 (Display Units Principle).** Sodium renders via [formatSodiumMg]
/// suffixed with ` mg`. Macros render via [formatGrams] suffixed with ` g`.
/// Energy renders via [formatKcal] suffixed with ` kcal`.
///
/// **Source-aware meta (PM §10 #10 — quality score hidden in v1).**
class NutritionTable extends StatelessWidget {
  const NutritionTable({
    required this.serving,
    required this.source,
    this.qualityScore,
    super.key,
  });

  final Serving serving;
  final FoodSource source;
  final int? qualityScore;

  @override
  Widget build(BuildContext context) {
    final headerLabel = serving.label ??
        'Per ${formatAmountUnit(serving.amount, serving.unit)}';
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
          _Header(headerLabel: headerLabel, source: source),
          _DividerLine(color: context.colors.line2),
          _Row(
            label: 'Calories',
            value: serving.kcal,
            unit: 'kcal',
            formatter: formatKcal,
          ),
          _Row(
            label: 'Protein',
            value: serving.proteinG,
            unit: 'g',
            formatter: formatGrams,
          ),
          _Row(
            label: 'Carbohydrate',
            value: serving.carbsG,
            unit: 'g',
            formatter: formatGrams,
          ),
          if (serving.sugarG != null)
            _Row(
              label: 'of which sugars',
              value: serving.sugarG,
              unit: 'g',
              formatter: formatGrams,
              sub: true,
            ),
          _Row(
            label: 'Fat',
            value: serving.fatG,
            unit: 'g',
            formatter: formatGrams,
          ),
          if (serving.saturatedFatG != null)
            _Row(
              label: 'saturated',
              value: serving.saturatedFatG,
              unit: 'g',
              formatter: formatGrams,
              sub: true,
            ),
          if (serving.fiberG != null)
            _Row(
              label: 'Fiber',
              value: serving.fiberG,
              unit: 'g',
              formatter: formatGrams,
            ),
          if (serving.sodiumMg != null)
            _Row(
              label: 'Sodium',
              value: serving.sodiumMg,
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
  const _Header({required this.headerLabel, required this.source});

  final String headerLabel;
  final FoodSource source;

  @override
  Widget build(BuildContext context) {
    final meta = _metaText(source);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.space.x2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: <Widget>[
          Expanded(
            child: Text(
              headerLabel,
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

  static String? _metaText(FoodSource source) {
    switch (source) {
      case FoodSource.off:
        return 'OFF data';
      case FoodSource.usda:
        return 'USDA data';
      case FoodSource.user:
        return 'Your food';
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
