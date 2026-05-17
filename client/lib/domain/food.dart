import 'package:decimal/decimal.dart';

import '_eq.dart';
import 'enums.dart';
import 'serving.dart';
import 'unit.dart';

/// A food in the catalogue. Nutrition is no longer anchored to the food
/// itself — per Ask 10 the food row carries identity + metadata only,
/// and every nutritional fact lives on a [Serving]. The "what does
/// `kcalPerDefaultServing` show?" computation just reads
/// `defaultServing.kcal`; no per-100g × grams math.
///
/// On the wire `FoodDetail` and `FoodSearchHit` are separate shapes:
/// search returns a slim hit with `default_serving` + `calories_per_serving`,
/// detail returns the full servings list. This class is the *detail*
/// shape — `FoodSearchHit` is a sibling type below.
class Food {
  Food({
    required this.id,
    required this.name,
    required this.source,
    required this.isCustom,
    required this.servings,
    this.brand,
    this.barcode,
    this.qualityScore,
    this.nutriscore,
    this.categoriesTags = const <String>[],
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

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

  final List<Serving> servings;
  final List<String> categoriesTags;

  /// Wall-clock timestamp when the food row was created. `My foods`
  /// sorts by this descending so a freshly-saved custom food surfaces
  /// at the top.
  final DateTime createdAt;

  /// The default serving (the one with `is_default == true`). Falls
  /// back to the first row if no flag is set (defensive — real wire
  /// data should always have one).
  Serving get defaultServing {
    for (final s in servings) {
      if (s.isDefault) return s;
    }
    return servings.first;
  }

  /// The id of the default serving — preserved for callers that only
  /// need the id (e.g. `LogEntryCreate.servingId`).
  String get defaultServingId => defaultServing.id;

  /// Per-default-serving kcal for the search-hit / summary card. Per
  /// Ask 10 this is just the default serving's `kcal` — no per-100g
  /// math required.
  Decimal? get caloriesPerDefaultServing {
    if (servings.isEmpty) return null;
    return defaultServing.kcal;
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
    List<Serving>? servings,
    List<String>? categoriesTags,
    DateTime? createdAt,
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
        servings: servings ?? this.servings,
        categoriesTags: categoriesTags ?? this.categoriesTags,
        createdAt: createdAt ?? this.createdAt,
      );

  factory Food.fromJson(Map<String, dynamic> json) {
    final source = FoodSource.fromWire(json['source'] as String);
    final createdAtRaw = json['created_at'];
    return Food(
      id: json['id'] as String,
      name: json['name'] as String,
      brand: json['brands'] as String?,
      barcode: json['barcode'] as String?,
      source: source,
      isCustom: source == FoodSource.user,
      qualityScore: (json['quality_score'] as num?)?.toInt(),
      nutriscore: NutriscoreGrade.fromWire(json['nutriscore'] as String?),
      servings: ((json['servings'] as List<dynamic>?) ?? const <dynamic>[])
          .map((e) => Serving.fromJson(e as Map<String, dynamic>))
          .toList(),
      categoriesTags:
          ((json['categories_tags'] as List<dynamic>?) ?? const <dynamic>[])
              .map((e) => e as String)
              .toList(),
      createdAt: createdAtRaw == null
          ? null
          : DateTime.parse(createdAtRaw as String),
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
        'servings': servings.map((s) => s.toJson()).toList(),
        'categories_tags': categoriesTags,
        'created_at': createdAt.toIso8601String(),
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
          listEquals(other.servings, servings) &&
          listEquals(other.categoriesTags, categoriesTags) &&
          other.createdAt == createdAt;

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
        Object.hashAll(servings),
        Object.hashAll(categoriesTags),
        createdAt,
      );
}

/// Slim catalog row returned by `/foods/search`, `/foods/recent`,
/// `/foods/frequent`. Mirrors `FoodSearchHit` from the OpenAPI; the
/// `default_serving` block carries `{id, label?, amount, unit}` per
/// the Ask-10 reshape (no `grams` field anymore).
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
    this.defaultServingAmount,
    this.defaultServingUnit,
    this.caloriesPerServing,
  });

  final String id;
  final String name;
  final FoodSource source;
  final String? brand;
  final String? barcode;
  final String? defaultServingId;

  /// Either the explicit `label` from the wire or the rendered
  /// "amount + unit" string when the wire didn't carry a label.
  final String? defaultServingLabel;

  final Decimal? defaultServingAmount;
  final Unit? defaultServingUnit;
  final Decimal? caloriesPerServing;

  FoodSearchHit copyWith({
    String? id,
    String? name,
    FoodSource? source,
    String? brand,
    String? barcode,
    String? defaultServingId,
    String? defaultServingLabel,
    Decimal? defaultServingAmount,
    Unit? defaultServingUnit,
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
        defaultServingAmount: defaultServingAmount ?? this.defaultServingAmount,
        defaultServingUnit: defaultServingUnit ?? this.defaultServingUnit,
        caloriesPerServing: caloriesPerServing ?? this.caloriesPerServing,
      );

  /// Project a hit from a full [Food]. The mock repository uses this so
  /// the same seed list backs detail, search, recent and frequent calls.
  factory FoodSearchHit.fromFood(Food food) {
    final def = food.servings.isEmpty ? null : food.defaultServing;
    return FoodSearchHit(
      id: food.id,
      name: food.name,
      source: food.source,
      brand: food.brand,
      barcode: food.barcode,
      defaultServingId: def?.id,
      defaultServingLabel: def?.name,
      defaultServingAmount: def?.amount,
      defaultServingUnit: def?.unit,
      caloriesPerServing: food.caloriesPerDefaultServing,
    );
  }

  factory FoodSearchHit.fromJson(Map<String, dynamic> json) {
    Decimal? dec(Object? v) =>
        v == null ? null : Decimal.parse(v.toString());
    final defServing = json['default_serving'] as Map<String, dynamic>?;
    final unitWire = defServing?['unit'] as String?;
    return FoodSearchHit(
      id: json['id'] as String,
      name: json['name'] as String,
      source: FoodSource.fromWire(json['source'] as String),
      brand: json['brand'] as String?,
      barcode: json['barcode'] as String?,
      defaultServingId: defServing?['id'] as String?,
      defaultServingLabel: defServing?['label'] as String?,
      defaultServingAmount: dec(defServing?['amount']),
      defaultServingUnit: unitWire == null ? null : Unit.fromWire(unitWire),
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
            if (defaultServingLabel != null) 'label': defaultServingLabel,
            if (defaultServingAmount != null)
              'amount': defaultServingAmount.toString(),
            if (defaultServingUnit != null) 'unit': defaultServingUnit!.wire,
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
          other.defaultServingAmount == defaultServingAmount &&
          other.defaultServingUnit == defaultServingUnit &&
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
        defaultServingAmount,
        defaultServingUnit,
        caloriesPerServing,
      );
}

/// Outgoing `POST /servings` payload-shape used by both the
/// `FoodCreate` body and the standalone `POST /foods/{id}/servings`
/// endpoint. Per Ask 10 every serving carries its own nutrition; the
/// food-level nutrition struct is gone.
class ServingCreate {
  const ServingCreate({
    required this.amount,
    required this.unit,
    required this.kcal,
    this.label,
    this.proteinG,
    this.carbsG,
    this.fatG,
    this.fiberG,
    this.sugarG,
    this.sodiumMg,
    this.saturatedFatG,
    this.isDefault = false,
  });

  final String? label;
  final Decimal amount;
  final Unit unit;
  final Decimal kcal;
  final Decimal? proteinG;
  final Decimal? carbsG;
  final Decimal? fatG;
  final Decimal? fiberG;
  final Decimal? sugarG;
  final Decimal? sodiumMg;
  final Decimal? saturatedFatG;
  final bool isDefault;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (label != null) 'label': label,
        'amount': amount.toString(),
        'unit': unit.wire,
        'kcal': kcal.toString(),
        if (proteinG != null) 'protein_g': proteinG.toString(),
        if (carbsG != null) 'carbs_g': carbsG.toString(),
        if (fatG != null) 'fat_g': fatG.toString(),
        if (fiberG != null) 'fiber_g': fiberG.toString(),
        if (sugarG != null) 'sugar_g': sugarG.toString(),
        if (sodiumMg != null) 'sodium_mg': sodiumMg.toString(),
        if (saturatedFatG != null)
          'saturated_fat_g': saturatedFatG.toString(),
        'is_default': isDefault,
      };
}

/// Outgoing `POST /foods` payload. Per Ask 10 the body is `{name,
/// brand?, barcode?, servings: [ServingCreate]}` — no top-level
/// nutrition. **At least one serving is required.**
class FoodCreate {
  const FoodCreate({
    required this.name,
    required this.servings,
    this.brand,
    this.barcode,
    this.categoriesTags = const <String>[],
  }) : assert(servings.length > 0, 'FoodCreate requires ≥ 1 serving');

  final String name;
  final String? brand;
  final String? barcode;
  final List<ServingCreate> servings;
  final List<String> categoriesTags;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        if (brand != null) 'brands': brand,
        if (barcode != null) 'barcode': barcode,
        'servings': servings.map((s) => s.toJson()).toList(),
        'categories_tags': categoriesTags,
      };
}

