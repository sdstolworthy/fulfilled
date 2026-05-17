import 'drafts.dart';

/// Outgoing `PATCH /foods/{id}` payload — screen 05's edit mode builds
/// one in `_buildFoodPatch()` and `FoodRepository.updateCustom` posts
/// it.
///
/// **Sparse-by-null semantics.** A `null` field means "leave unchanged"
/// on the wire — the key is omitted from the encoded JSON entirely. To
/// blank a previously-set optional like `brand` or `barcode`, set the
/// matching `clear*` flag.
///
/// **No top-level nutrition.** Per Ask 10 the food row carries no
/// nutrition; every nutritional fact rides on a serving. To update
/// nutrition, replace the [servings] list.
///
/// `servings`: full list replace, not a per-row diff. The repository
/// recomputes the persisted serving rows from this list each time. A
/// wholesale replace is the simpler contract and matches what the form
/// already builds for create.
class FoodPatch {
  const FoodPatch({
    this.name,
    this.brand,
    this.barcode,
    this.servings,
    this.clearBrand = false,
    this.clearBarcode = false,
  });

  final String? name;
  final String? brand;
  final String? barcode;

  /// When non-null, replaces the food's servings wholesale.
  final List<DraftServing>? servings;

  final bool clearBrand;
  final bool clearBarcode;

  bool get isEmpty =>
      name == null &&
      brand == null &&
      barcode == null &&
      servings == null &&
      !clearBrand &&
      !clearBarcode;

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{};
    if (name != null) m['name'] = name;
    if (brand != null) {
      m['brands'] = brand;
    } else if (clearBrand) {
      m['brands'] = null;
    }
    if (barcode != null) {
      m['barcode'] = barcode;
    } else if (clearBarcode) {
      m['barcode'] = null;
    }
    if (servings != null) {
      m['servings'] = servings!
          .map<Map<String, dynamic>>(
            (s) => <String, dynamic>{
              if (s.label != null) 'label': s.label,
              'amount': s.amount!.toString(),
              'unit': s.unit.wire,
              'kcal': s.kcal!.toString(),
              if (s.proteinG != null) 'protein_g': s.proteinG!.toString(),
              if (s.carbsG != null) 'carbs_g': s.carbsG!.toString(),
              if (s.fatG != null) 'fat_g': s.fatG!.toString(),
              if (s.fiberG != null) 'fiber_g': s.fiberG!.toString(),
              if (s.sugarG != null) 'sugar_g': s.sugarG!.toString(),
              if (s.sodiumMg != null) 'sodium_mg': s.sodiumMg!.toString(),
              if (s.saturatedFatG != null)
                'saturated_fat_g': s.saturatedFatG!.toString(),
              'is_default': s.isDefault,
            },
          )
          .toList();
    }
    return m;
  }
}
