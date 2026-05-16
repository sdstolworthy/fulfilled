import 'package:flutter/material.dart';

import '../../../domain/meal.dart';
import '../../../theme/context_extensions.dart';

/// Segmented chip row — Breakfast / Lunch / Dinner / Snack. Tapping a
/// chip calls [onChanged] with the new meal; the currently selected chip
/// renders accent-filled with white ink. Layout is a 4-column grid that
/// matches the mock.
class MealChipPicker extends StatelessWidget {
  const MealChipPicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final Meal value;
  final ValueChanged<Meal> onChanged;

  @override
  Widget build(BuildContext context) {
    final space = context.space;
    return Row(
      children: <Widget>[
        for (var i = 0; i < Meal.values.length; i++) ...<Widget>[
          if (i > 0) SizedBox(width: space.x2),
          Expanded(
            child: _MealChip(
              meal: Meal.values[i],
              selected: Meal.values[i] == value,
              onTap: () => onChanged(Meal.values[i]),
            ),
          ),
        ],
      ],
    );
  }
}

class _MealChip extends StatelessWidget {
  const _MealChip({
    required this.meal,
    required this.selected,
    required this.onTap,
  });

  final Meal meal;
  final bool selected;
  final VoidCallback onTap;

  IconData get _icon {
    switch (meal) {
      case Meal.breakfast:
        return Icons.free_breakfast_outlined;
      case Meal.lunch:
        return Icons.lunch_dining_outlined;
      case Meal.dinner:
        return Icons.dinner_dining_outlined;
      case Meal.snack:
        return Icons.cookie_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = context.radius;
    final fg = selected ? colors.surface : colors.ink2;
    return Semantics(
      button: true,
      selected: selected,
      label: meal.label,
      child: InkResponse(
        onTap: onTap,
        radius: 36,
        child: Container(
          height: 62,
          decoration: BoxDecoration(
            color: selected ? colors.accent : colors.surface,
            border: Border.all(
              color: selected ? colors.accent : colors.line,
            ),
            borderRadius: BorderRadius.circular(radius.r2),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(_icon, size: 18, color: fg),
              SizedBox(height: context.space.x05 + 2),
              Text(
                meal.label,
                style: context.text.meta.copyWith(
                  fontWeight: FontWeight.w500,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
