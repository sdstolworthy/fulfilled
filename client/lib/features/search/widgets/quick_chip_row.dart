import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../domain/enums.dart';
import '../../../domain/food.dart';
import '../../../domain/units/energy.dart';
import '../../../theme/context_extensions.dart';

/// Horizontal scrolling chip row for Recent / Frequent. Mirrors the
/// `.chip` rule in `screen_02_search.html`: pill, white surface, 1 px
/// line border, leading dot, name, kcal subtitle.
///
/// The Recent variant uses the accent dot; Frequent uses the protein
/// macro color in the mock — but per **T-03** protein color is data-only
/// and can never label a non-macro chip. We map the variant to a
/// `dotColor` argument that screen 02 supplies:
///   - Recent  → accent (matches mock)
///   - Frequent → `AppColors.ink3` (architectural override — T-03)
///
/// Tap behavior: `context.push('/foods/${food.id}')` per architect brief.
class QuickChipRow extends StatelessWidget {
  const QuickChipRow({
    required this.title,
    required this.foods,
    required this.dotColor,
    super.key,
  });

  final String title;
  final List<Food> foods;
  final Color dotColor;

  @override
  Widget build(BuildContext context) {
    if (foods.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(
            context.space.x5,
            context.space.x3,
            context.space.x5,
            context.space.x1,
          ),
          child: Text(
            title.toUpperCase(),
            style: context.text.eyebrow.copyWith(color: context.colors.ink3),
          ),
        ),
        SizedBox(height: context.space.x2),
        SizedBox(
          height: 36,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: context.space.x5),
            itemCount: foods.length,
            separatorBuilder: (_, __) => SizedBox(width: context.space.x2),
            itemBuilder: (context, i) {
              final food = foods[i];
              return _Chip(food: food, dotColor: dotColor);
            },
          ),
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.food, required this.dotColor});

  final Food food;
  final Color dotColor;

  @override
  Widget build(BuildContext context) {
    final kcal = food.caloriesPerDefaultServing;
    final semanticLabel = StringBuffer(food.name);
    if (kcal != null) {
      semanticLabel
        ..write(', ')
        ..write(formatKcal(kcal))
        ..write(' kilocalories');
    }
    return Semantics(
      button: true,
      label: semanticLabel.toString(),
      child: InkResponse(
        onTap: () => context.push('/foods/${food.id}'),
        containedInkWell: true,
        radius: 24,
        child: Container(
          // T-06 — visible 36, hit slop ≥ 44 via InkResponse radius (24
          // around the 36 px row gives a 48 px effective target).
          padding: EdgeInsets.symmetric(
            horizontal: context.space.x3,
            vertical: context.space.x2,
          ),
          decoration: BoxDecoration(
            color: context.colors.surface,
            border: Border.all(color: context.colors.line),
            borderRadius: BorderRadius.circular(context.radius.rPill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: _resolvedDot(context, food.source),
                  shape: BoxShape.circle,
                ),
              ),
              SizedBox(width: context.space.x1 + context.space.x05),
              Text(
                food.name,
                style: context.text.body.copyWith(fontSize: 13),
              ),
              if (kcal != null) ...<Widget>[
                SizedBox(width: context.space.x1),
                Text(
                  '· ${formatKcal(kcal)}',
                  style: context.text.metaNumeric.copyWith(
                    color: context.colors.ink2,
                    fontSize: 13,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Color _resolvedDot(BuildContext context, FoodSource source) {
    // YOU rows in either chip strip get the warm `goalLine` swatch (which
    // doubles as the user-thumb color in the mock); OFF/USDA rows take
    // the variant-supplied dotColor. T-03 keeps protein out of this
    // because nothing here labels a macro.
    if (source == FoodSource.user) return context.colors.goalLine;
    return dotColor;
  }
}
