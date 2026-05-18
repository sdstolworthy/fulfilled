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
    this.lastLoggedAt,
    this.logCount,
    this.lastServingId,
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

  /// Per-user log-history signals — only populated when this [Food] was
  /// projected from a search/recent/frequent hit ([FoodRepository._hitToFood]).
  /// Never present on `GET /foods/{id}` (single-food detail). On a hit
  /// where the caller has never logged the food, [logCount] is `0` (BE
  /// emits the field as non-nullable) and the other two are `null`.
  final DateTime? lastLoggedAt;

  /// Lifetime count of `food_log_entries` rows for `(caller, food)`. Not
  /// distinct-days, not a sliding window. See note on [lastLoggedAt].
  final int? logCount;

  /// Serving id used on the caller's most-recent log entry for this food.
  /// `null` when the serving was deleted (FK `ON DELETE SET NULL`) or the
  /// caller has never logged this food. See note on [lastLoggedAt].
  final String? lastServingId;

  /// True iff the caller has previously logged this food at least once.
  /// Mirrors [FoodSearchHit.isPreviouslyLogged]; drives the "YOUR FOODS"
  /// section split + sub-line in `SearchResultRow` (F5-T4).
  bool get wasLoggedByCaller =>
      (logCount ?? 0) > 0 && lastLoggedAt != null;

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
    DateTime? lastLoggedAt,
    int? logCount,
    String? lastServingId,
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
        lastLoggedAt: lastLoggedAt ?? this.lastLoggedAt,
        logCount: logCount ?? this.logCount,
        lastServingId: lastServingId ?? this.lastServingId,
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
      lastLoggedAt: json['last_logged_at'] == null
          ? null
          : DateTime.parse(json['last_logged_at'] as String),
      logCount: (json['log_count'] as num?)?.toInt(),
      lastServingId: json['last_serving_id'] as String?,
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
        if (lastLoggedAt != null)
          'last_logged_at':
              '${lastLoggedAt!.year.toString().padLeft(4, '0')}-'
              '${lastLoggedAt!.month.toString().padLeft(2, '0')}-'
              '${lastLoggedAt!.day.toString().padLeft(2, '0')}',
        if (logCount != null) 'log_count': logCount,
        if (lastServingId != null) 'last_serving_id': lastServingId,
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
          other.createdAt == createdAt &&
          other.lastLoggedAt == lastLoggedAt &&
          other.logCount == logCount &&
          other.lastServingId == lastServingId;

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
        lastLoggedAt,
        logCount,
        lastServingId,
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
    this.lastLoggedAt,
    this.logCount,
    this.lastServingId,
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

  /// Per-user log-history signals from the BE enrichment composer
  /// (F5-T2). Populated on hits from `/foods/search|recent|frequent|mine`
  /// when the caller is authenticated. `lastLoggedAt` is decoded from
  /// the wire's bare `"YYYY-MM-DD"` date string (parsed as local
  /// midnight) — *not* an ISO-8601 instant.
  final DateTime? lastLoggedAt;

  /// Lifetime `COUNT(*)` of `(caller, food)` rows in `food_log_entries`.
  /// BE always emits this as a non-nullable integer; we decode `int?`
  /// defensively and treat `null` and `0` identically.
  final int? logCount;

  /// Serving id used on the caller's most-recent log entry for this food.
  /// `null` when the serving was deleted (FK `ON DELETE SET NULL`) or
  /// the caller has never logged this food.
  final String? lastServingId;

  /// True iff the caller has previously logged this food at least once.
  /// Drives the "YOUR FOODS" section split + sub-line in `SearchResultRow`
  /// (F5-T4). Requires *both* a non-null [lastLoggedAt] *and* a positive
  /// [logCount] — guards against an enriched row with a stale `last_logged_at`
  /// but a zeroed count (shouldn't happen with the current BE shape, but
  /// cheap to defend).
  bool get isPreviouslyLogged =>
      (logCount ?? 0) > 0 && lastLoggedAt != null;

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
    DateTime? lastLoggedAt,
    int? logCount,
    String? lastServingId,
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
        lastLoggedAt: lastLoggedAt ?? this.lastLoggedAt,
        logCount: logCount ?? this.logCount,
        lastServingId: lastServingId ?? this.lastServingId,
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
      caloriesPerServing: dec(json['calories_per_serving'] ?? defServing?['kcal']),
      // Wire shape is a bare `"YYYY-MM-DD"` date string (BE plan §2 —
      // `Option<NaiveDate>`, not an ISO-8601 instant). `DateTime.parse`
      // accepts the date-only form and returns local midnight, which is
      // exactly what the "Today"/"Yesterday"/"Tue" math in
      // `_formatLoggedWhen` expects.
      lastLoggedAt: json['last_logged_at'] == null
          ? null
          : DateTime.parse(json['last_logged_at'] as String),
      logCount: (json['log_count'] as num?)?.toInt(),
      lastServingId: json['last_serving_id'] as String?,
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
        if (lastLoggedAt != null)
          'last_logged_at':
              '${lastLoggedAt!.year.toString().padLeft(4, '0')}-'
              '${lastLoggedAt!.month.toString().padLeft(2, '0')}-'
              '${lastLoggedAt!.day.toString().padLeft(2, '0')}',
        if (logCount != null) 'log_count': logCount,
        if (lastServingId != null) 'last_serving_id': lastServingId,
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
          other.caloriesPerServing == caloriesPerServing &&
          other.lastLoggedAt == lastLoggedAt &&
          other.logCount == logCount &&
          other.lastServingId == lastServingId;

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
        lastLoggedAt,
        logCount,
        lastServingId,
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

