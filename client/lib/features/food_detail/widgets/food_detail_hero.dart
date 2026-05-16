import 'package:flutter/material.dart';

import '../../../domain/enums.dart';
import '../../../domain/food.dart';
import '../../../theme/context_extensions.dart';

/// Hero block for screen 03 — brand eyebrow, multi-line food title, and an
/// optional barcode pill. Mirrors the markup in
/// `specs/ui_mocks/screen_03_food_detail.html` (hero block).
///
/// **Source-aware meta** lives in `FoodSummaryCard`/`NutritionTable`; the
/// brand eyebrow here also doubles as the source attribution row when the
/// food has no `brand`. The combo line reads either `Fage · OpenFoodFacts`
/// (brand + source) or `OpenFoodFacts` (source only) or `My foods` (user
/// custom). Architect §10 Q10 — `quality_score` text never lives in the
/// hero; it lives in the panel header.
class FoodDetailHero extends StatelessWidget {
  const FoodDetailHero({required this.food, super.key});

  final Food food;

  @override
  Widget build(BuildContext context) {
    final eyebrowText = _eyebrow(food);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.space.x5,
        context.space.x1,
        context.space.x5,
        context.space.x4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (eyebrowText != null)
            Text(eyebrowText, style: context.text.eyebrow),
          SizedBox(height: context.space.x1),
          Text(food.name, style: context.text.hero),
          if (food.barcode != null) ...<Widget>[
            SizedBox(height: context.space.x2),
            _BarcodePill(barcode: food.barcode!),
          ],
        ],
      ),
    );
  }

  static String? _eyebrow(Food food) {
    final brand = food.brand?.trim();
    final sourceLabel = _sourceLabel(food.source);
    if (brand != null && brand.isNotEmpty) {
      return '$brand · $sourceLabel';
    }
    return sourceLabel;
  }

  static String _sourceLabel(FoodSource source) {
    switch (source) {
      case FoodSource.off:
        return 'OpenFoodFacts';
      case FoodSource.usda:
        return 'USDA';
      case FoodSource.user:
        return 'My foods';
    }
  }
}

class _BarcodePill extends StatelessWidget {
  const _BarcodePill({required this.barcode});

  final String barcode;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.colors.surface,
        border: Border.all(color: context.colors.line),
        borderRadius: BorderRadius.circular(context.radius.r1),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: context.space.x2,
        vertical: context.space.x1,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.qr_code_2,
            size: 14,
            color: context.colors.ink2,
          ),
          SizedBox(width: context.space.x1),
          Text(
            barcode,
            style: context.text.metaNumeric.copyWith(
              color: context.colors.ink2,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
