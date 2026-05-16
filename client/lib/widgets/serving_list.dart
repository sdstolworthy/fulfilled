import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../domain/nutrition.dart';
import '../domain/serving.dart';
import '../domain/units/units.dart';
import '../theme/context_extensions.dart';

// v1: the editor variant lives in `features/custom_food/widgets/
// servings_section.dart`; v1.1 collapses the two via a `ServingRow` that
// flips between display + edit. See dev_tickets.md T-002 notes.

/// Read-only list of `Serving` rows. Used by the food-detail screen
/// (screen 03) and the log-entry sheet's serving picker.
///
/// **T-10** — the synthetic 100 g serving is always rendered and tagged
/// with a `Synthetic` badge. The list never hides it, even when an OFF
/// default exists.
///
/// **T-21** — the per-row trailing kcal flows through [formatKcal] (energy
/// in kcal); the per-row meta gram weight flows through [formatGrams].
class ServingList extends StatelessWidget {
  const ServingList({
    required this.servings,
    required this.nutritionPer100g,
    this.selectedId,
    this.onSelect,
    this.selectable = false,
    super.key,
  });

  final List<Serving> servings;
  final NutritionPer100g nutritionPer100g;

  /// Id of the currently selected serving, if any. When non-null the
  /// matching row renders with the selected visual (accent border + soft
  /// fill).
  final String? selectedId;

  /// Tap callback. When provided rows are tappable and emit the tapped
  /// serving's id. When null the list is purely display.
  final ValueChanged<String>? onSelect;

  /// Reserved prop slot for the v1.1 unification with the custom-food
  /// editor. No behavior yet — the editor lift collapses the two widgets
  /// behind a single prop. See dev_tickets.md T-002 notes.
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
              nutritionPer100g: nutritionPer100g,
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
    required this.nutritionPer100g,
    required this.showDivider,
    required this.isSelected,
    required this.onTap,
  });

  final Serving serving;
  final NutritionPer100g nutritionPer100g;
  final bool showDivider;
  final bool isSelected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final kcalForServing = _kcalForServing(serving, nutritionPer100g);
    final gramsLabel = '${formatGrams(serving.grams)} g';

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
                  // The synthetic row in the mock substitutes its grams
                  // meta with the "Synthetic" word; we keep grams since
                  // the badge above already communicates synthetic — the
                  // numeric is more useful to the customer (T-10 says
                  // "always visible with badge", not "hide grams").
                  gramsLabel,
                  style: context.text.metaNumeric.copyWith(fontSize: 12),
                ),
              ],
            ),
          ),
          Text(
            kcalForServing == null ? '—' : '${formatKcal(kcalForServing)} kcal',
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
        // T-018 / §7 — selectable serving rows tint to `line2` on hover.
        // The accent stays reserved for the *selected* row's soft fill.
        hoverColor: colors.line2,
        child: row,
      ),
    );
  }

  static Decimal? _kcalForServing(
    Serving serving,
    NutritionPer100g per100,
  ) {
    final kcal = per100.energyKcal;
    if (kcal == null) return null;
    final ratio = (serving.grams / Decimal.fromInt(100))
        .toDecimal(scaleOnInfinitePrecision: 6);
    return kcal * ratio;
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
        if (serving.isSynthetic) const _Badge(label: 'Synthetic'),
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
