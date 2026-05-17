import 'package:flutter/material.dart';

import '../domain/serving.dart';
import '../domain/unit.dart';
import '../domain/units/units.dart';
import '../theme/context_extensions.dart';

/// Read-only list of `Serving` rows. Used by the food-detail screen
/// (screen 03) and the log-entry sheet's serving picker.
///
/// Per Ask 10 nutrition lives on each serving — the per-row trailing
/// kcal reads `serving.kcal` directly (no per-100g math). The synthetic
/// 100 g serving concept is gone; rows simply show their `{amount,
/// unit}` (via `serving.name`).
class ServingList extends StatelessWidget {
  const ServingList({
    required this.servings,
    this.selectedId,
    this.onSelect,
    this.selectable = false,
    super.key,
  });

  final List<Serving> servings;
  final String? selectedId;
  final ValueChanged<String>? onSelect;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final sorted = <Serving>[...servings]
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

    return Container(
      decoration: BoxDecoration(
        color: context.colors.surface,
        border: Border.all(color: context.colors.line),
        borderRadius: BorderRadius.circular(context.radius.r3),
      ),
      child: Column(
        children: <Widget>[
          for (var i = 0; i < sorted.length; i++)
            _ServingRow(
              serving: sorted[i],
              showDivider: i != sorted.length - 1,
              isSelected: selectedId != null && sorted[i].id == selectedId,
              onTap:
                  onSelect == null ? null : () => onSelect!(sorted[i].id),
            ),
        ],
      ),
    );
  }
}

class _ServingRow extends StatelessWidget {
  const _ServingRow({
    required this.serving,
    required this.showDivider,
    required this.isSelected,
    required this.onTap,
  });

  final Serving serving;
  final bool showDivider;
  final bool isSelected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final amountLabel = formatAmountUnit(serving.amount, serving.unit);

    final row = Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.space.x4,
        vertical: context.space.x3,
      ),
      decoration: BoxDecoration(
        color: isSelected ? colors.accentSoft : Colors.transparent,
        border: Border(
          bottom: BorderSide(
            color: showDivider ? colors.line2 : Colors.transparent,
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _LabelRow(serving: serving),
                SizedBox(height: context.space.x05),
                Text(
                  amountLabel,
                  style: context.text.metaNumeric.copyWith(fontSize: 12),
                ),
              ],
            ),
          ),
          Text(
            '${formatKcal(serving.kcal)} kcal',
            style: context.text.bodyStrongNumeric.copyWith(fontSize: 13),
          ),
        ],
      ),
    );

    if (onTap == null) return row;
    return Semantics(
      button: true,
      selected: isSelected,
      label: serving.name,
      child: InkWell(
        onTap: onTap,
        hoverColor: colors.line2,
        child: row,
      ),
    );
  }
}

class _LabelRow extends StatelessWidget {
  const _LabelRow({required this.serving});

  final Serving serving;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: context.space.x2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        Text(
          serving.name,
          style: context.text.body.copyWith(
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        if (serving.isDefault) const _Badge(label: 'Default'),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.colors.accentSoft,
        borderRadius: BorderRadius.circular(context.radius.r1 / 2),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: context.space.x1 + 2,
        vertical: context.space.x05,
      ),
      child: Text(
        label.toUpperCase(),
        style: context.text.eyebrow.copyWith(
          color: context.colors.accent,
          fontSize: 10,
          letterSpacing: 0.06 * 10,
        ),
      ),
    );
  }
}
