import 'drafts.dart';
import 'nutrition.dart';

/// Outgoing `PATCH /foods/{id}` payload — screen 05's edit mode builds
/// one in `_buildFoodPatch()` and `FoodRepository.updateCustom` posts
/// it. Modelled on [LogPatch] (see `domain/log_entry.dart`) — plain Dart
/// value class, hand-written sparse `toJson()`, **no codegen**.
///
/// **Sparse-by-null semantics.** A `null` field means "leave unchanged"
/// on the wire — the key is omitted from the encoded JSON entirely. To
/// blank a previously-set optional like `brand` or `barcode`, set the
/// matching `clear*` flag. This mirrors `LogPatch.clearNote` and the
/// architect's reasoning in §2.4 — "absence on the wire means leave
/// unchanged; an explicit `null` means clear."
///
/// `food_id` is **never** on this class. `Food.id` is immutable; the
/// repository asserts that no caller smuggles one in via a subclass
/// override of [toJson] (defence-in-depth — the screen gate is the
/// first line of defence).
///
/// `servings`: full list replace, not a per-row diff. The repository
/// recomputes the persisted serving rows from this list each time
/// (preserving the auto-seeded synthetic 100 g per T-10). The
/// architect's reading: per-row diffing of grams + label + sort-order
/// across two unordered lists is fragile; a wholesale replace is the
/// simpler contract and matches what the form already builds for
/// create.
class FoodPatch {
  const FoodPatch({
    this.name,
    this.brand,
    this.barcode,
    this.nutritionPer100g,
    this.servings,
    this.clearBrand = false,
    this.clearBarcode = false,
  });

  final String? name;
  final String? brand;
  final String? barcode;
  final NutritionPer100g? nutritionPer100g;

  /// When non-null, replaces the food's user-defined servings wholesale.
  /// The synthetic 100 g system row is **not** carried here — the
  /// repository preserves it across patches (T-10).
  final List<DraftServing>? servings;

  /// When `true` and [brand] is null, emit `'brands': null` to clear an
  /// existing brand. When `false` (default), an unset [brand] is omitted
  /// from the wire entirely. Ignored when [brand] is non-null — the
  /// explicit value always wins. Mirrors [LogPatch.clearNote].
  final bool clearBrand;

  /// Same as [clearBrand], but for [barcode].
  final bool clearBarcode;

  /// `true` iff every patchable field is unset and we're not clearing
  /// anything. The submit handler short-circuits on this to skip
  /// no-op PATCHes.
  bool get isEmpty =>
      name == null &&
      brand == null &&
      barcode == null &&
      nutritionPer100g == null &&
      servings == null &&
      !clearBrand &&
      !clearBarcode;

  /// Sparse JSON encoder. Only emits keys for set fields. Never emits
  /// `food_id` — see class docs.
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
    if (nutritionPer100g != null) {
      m['nutrition'] = nutritionPer100g!.toJson();
    }
    if (servings != null) {
      m['servings'] = servings!
          .map<Map<String, dynamic>>(
            (s) => <String, dynamic>{
              'label': s.label,
              'grams': s.grams.toString(),
            },
          )
          .toList();
    }
    return m;
  }
}
