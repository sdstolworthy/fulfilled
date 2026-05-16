import 'package:decimal/decimal.dart';

import 'enums.dart';
import 'nutrition.dart';
import 'serving.dart';

/// A food in the catalogue. Composes `FoodDetail` + the screen-facing
/// "is this mine?" helpers screen agents need.
///
/// On the wire `FoodDetail` and `FoodSearchHit` are separate shapes:
/// search returns a slim hit with `default_serving` + `calories_per_serving`,
/// detail returns the full nutrition panel + all servings. This class is
/// the *detail* shape — `FoodSearchHit` is a sibling type below.
class Food {
  const Food({
    required this.id,
    required this.name,
    required this.source,
    required this.isCustom,
    required this.nutritionPer100g,
    required this.servings,
    this.brand,
    this.barcode,
    this.qualityScore,
    this.nutriscore,
    this.categoriesTags = const <String>[],
  });

  final String id;
  final String name;

  /// `brand` on the wire is `brands` (free-form, sometimes multi-comma
  /// separated). Presented as a single string in widgets.
  final String? brand;
  final String? barcode;
  final FoodSource source;

  /// True when the food row is owned by the caller (`source == user`).
  /// Derived but cached for fast widget checks — the source/visibility
  /// rule lives in one place.
  final bool isCustom;

  /// `quality_score` from the OpenAPI — an integer 0..100 (the API
  /// returns int32, the mocks display "0.86" as `quality_score / 100`).
  /// Screen 03 renders it only when `source == off` (per architect
  /// gotcha).
  final int? qualityScore;

  /// OFF Nutriscore grade. Null for `usda` and `user` foods.
  final NutriscoreGrade? nutriscore;

  final NutritionPer100g nutritionPer100g;
  final List<Serving> servings;
  final List<String> categoriesTags;

  /// The id of the default serving. Asserts there's exactly one default
  /// in the list — the contract per OpenAPI is "exactly one row with
  /// `is_default = true`". Falls back to the first serving if no flag is
  /// set (defensive — real wire data should always have one).
  String get defaultServingId {
    for (final s in servings) {
      if (s.isDefault) return s.id;
    }
    return servings.first.id;
  }

  /// Per-default-serving kcal for the search-hit / summary card. Returns
  /// null if the food has no energy figure.
  Decimal? get caloriesPerDefaultServing {
    final per100 = nutritionPer100g.energyKcal;
    if (per100 == null) return null;
    Serving? def;
    for (final s in servings) {
      if (s.isDefault) {
        def = s;
        break;
      }
    }
    def ??= servings.isEmpty ? null : servings.first;
    if (def == null) return null;
    // kcal × (grams / 100). Decimal division can yield infinite digits,
    // so use a fixed scale on the rational result.
    final ratio = (def.grams / Decimal.fromInt(100))
        .toDecimal(scaleOnInfinitePrecision: 6);
    return per100 * ratio;
  }

  Food copyWith({
    String? id,
    String? name,
    String? brand,
    String? barcode,
    FoodSource? source,
    bool? isCustom,
    int? qualityScore,
    NutriscoreGrade? nutriscore,
    NutritionPer100g? nutritionPer100g,
    List<Serving>? servings,
    List<String>? categoriesTags,
  }) =>
      Food(
        id: id ?? this.id,
        name: name ?? this.name,
        brand: brand ?? this.brand,
        barcode: barcode ?? this.barcode,
        source: source ?? this.source,
        isCustom: isCustom ?? this.isCustom,
        qualityScore: qualityScore ?? this.qualityScore,
        nutriscore: nutriscore ?? this.nutriscore,
        nutritionPer100g: nutritionPer100g ?? this.nutritionPer100g,
        servings: servings ?? this.servings,
        categoriesTags: categoriesTags ?? this.categoriesTags,
      );

  factory Food.fromJson(Map<String, dynamic> json) {
    final source = FoodSource.fromWire(json['source'] as String);
    return Food(
      id: json['id'] as String,
      name: json['name'] as String,
      brand: json['brands'] as String?,
      barcode: json['barcode'] as String?,
      source: source,
      isCustom: source == FoodSource.user,
      qualityScore: (json['quality_score'] as num?)?.toInt(),
      nutriscore: NutriscoreGrade.fromWire(json['nutriscore'] as String?),
      nutritionPer100g:
          NutritionPer100g.fromJson(json['nutrition'] as Map<String, dynamic>),
      servings: ((json['servings'] as List<dynamic>?) ?? const <dynamic>[])
          .map((e) => Serving.fromJson(e as Map<String, dynamic>))
          .toList(),
      categoriesTags:
          ((json['categories_tags'] as List<dynamic>?) ?? const <dynamic>[])
              .map((e) => e as String)
              .toList(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'source': source.wire,
        'name': name,
        if (brand != null) 'brands': brand,
        if (barcode != null) 'barcode': barcode,
        if (qualityScore != null) 'quality_score': qualityScore,
        if (nutriscore != null) 'nutriscore': nutriscore!.wire,
        'nutrition': nutritionPer100g.toJson(),
        'servings': servings.map((s) => s.toJson()).toList(),
        'categories_tags': categoriesTags,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Food &&
          other.id == id &&
          other.name == name &&
          other.brand == brand &&
          other.barcode == barcode &&
          other.source == source &&
          other.isCustom == isCustom &&
          other.qualityScore == qualityScore &&
          other.nutriscore == nutriscore &&
          other.nutritionPer100g == nutritionPer100g &&
          _listEq(other.servings, servings) &&
          _listEq(other.categoriesTags, categoriesTags);

  @override
  int get hashCode => Object.hash(
        id,
        name,
        brand,
        barcode,
        source,
        isCustom,
        qualityScore,
        nutriscore,
        nutritionPer100g,
        Object.hashAll(servings),
        Object.hashAll(categoriesTags),
      );
}

/// Slim catalog row returned by `/foods/search`, `/foods/recent`,
/// `/foods/frequent`. Mirrors `FoodSearchHit` + a `default_serving`
/// preview.
///
/// Screen agents use this for `SearchResultRow` and `QuickChipRow`. To
/// open the log-entry sheet they re-fetch the full `Food` via
/// `foodDetailProvider(hit.id)`.
class FoodSearchHit {
  const FoodSearchHit({
    required this.id,
    required this.name,
    required this.source,
    this.brand,
    this.barcode,
    this.defaultServingId,
    this.defaultServingLabel,
    this.defaultServingGrams,
    this.caloriesPerServing,
  });

  final String id;
  final String name;
  final FoodSource source;
  final String? brand;
  final String? barcode;
  final String? defaultServingId;
  final String? defaultServingLabel;
  final Decimal? defaultServingGrams;
  final Decimal? caloriesPerServing;

  FoodSearchHit copyWith({
    String? id,
    String? name,
    FoodSource? source,
    String? brand,
    String? barcode,
    String? defaultServingId,
    String? defaultServingLabel,
    Decimal? defaultServingGrams,
    Decimal? caloriesPerServing,
  }) =>
      FoodSearchHit(
        id: id ?? this.id,
        name: name ?? this.name,
        source: source ?? this.source,
        brand: brand ?? this.brand,
        barcode: barcode ?? this.barcode,
        defaultServingId: defaultServingId ?? this.defaultServingId,
        defaultServingLabel: defaultServingLabel ?? this.defaultServingLabel,
        defaultServingGrams: defaultServingGrams ?? this.defaultServingGrams,
        caloriesPerServing: caloriesPerServing ?? this.caloriesPerServing,
      );

  /// Project a hit from a full [Food]. The mock repository uses this so
  /// the same seed list backs detail, search, recent and frequent calls.
  factory FoodSearchHit.fromFood(Food food) {
    Serving? def;
    for (final s in food.servings) {
      if (s.isDefault) {
        def = s;
        break;
      }
    }
    def ??= food.servings.isEmpty ? null : food.servings.first;
    return FoodSearchHit(
      id: food.id,
      name: food.name,
      source: food.source,
      brand: food.brand,
      barcode: food.barcode,
      defaultServingId: def?.id,
      defaultServingLabel: def?.name,
      defaultServingGrams: def?.grams,
      caloriesPerServing: food.caloriesPerDefaultServing,
    );
  }

  factory FoodSearchHit.fromJson(Map<String, dynamic> json) {
    Decimal? dec(Object? v) =>
        v == null ? null : Decimal.parse(v.toString());
    final defServing = json['default_serving'] as Map<String, dynamic>?;
    return FoodSearchHit(
      id: json['id'] as String,
      name: json['name'] as String,
      source: FoodSource.fromWire(json['source'] as String),
      brand: json['brand'] as String?,
      barcode: json['barcode'] as String?,
      defaultServingId: defServing?['id'] as String?,
      defaultServingLabel: defServing?['label'] as String?,
      defaultServingGrams: dec(defServing?['grams']),
      caloriesPerServing: dec(json['calories_per_serving']),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'source': source.wire,
        if (brand != null) 'brand': brand,
        if (barcode != null) 'barcode': barcode,
        if (defaultServingId != null)
          'default_serving': <String, dynamic>{
            'id': defaultServingId,
            'label': defaultServingLabel,
            'grams': defaultServingGrams?.toString(),
          },
        if (caloriesPerServing != null)
          'calories_per_serving': caloriesPerServing.toString(),
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FoodSearchHit &&
          other.id == id &&
          other.name == name &&
          other.source == source &&
          other.brand == brand &&
          other.barcode == barcode &&
          other.defaultServingId == defaultServingId &&
          other.defaultServingLabel == defaultServingLabel &&
          other.defaultServingGrams == defaultServingGrams &&
          other.caloriesPerServing == caloriesPerServing;

  @override
  int get hashCode => Object.hash(
        id,
        name,
        source,
        brand,
        barcode,
        defaultServingId,
        defaultServingLabel,
        defaultServingGrams,
        caloriesPerServing,
      );
}

/// Outgoing `POST /foods` payload — screens build one in the custom-food
/// form and the repository POSTs it. Decimals are stored as `Decimal`
/// here and serialized via `NutritionPer100g.toJson`.
class FoodCreate {
  const FoodCreate({
    required this.name,
    required this.nutrition,
    this.brand,
    this.barcode,
    this.nutriscore,
    this.categoriesTags = const <String>[],
  });

  final String name;
  final String? brand;
  final String? barcode;
  final NutritionPer100g nutrition;
  final NutriscoreGrade? nutriscore;
  final List<String> categoriesTags;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        if (brand != null) 'brands': brand,
        if (barcode != null) 'barcode': barcode,
        'nutrition': nutrition.toJson(),
        if (nutriscore != null) 'nutriscore_grade': nutriscore!.wire,
        'categories_tags': categoriesTags,
      };
}

bool _listEq<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
