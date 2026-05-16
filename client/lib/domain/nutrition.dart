import 'package:decimal/decimal.dart';

import 'units/sodium.dart';

/// Per-100 g nutrition panel. Mirrors `NutritionPer100g` from the OpenAPI
/// schema — every field is nullable on the wire and stays nullable here.
///
/// **Sodium**: the wire field is `sodium_g` (grams per 100 g, OFF
/// convention). The PM Display Units Principle (and T-21) requires the
/// client to display milligrams. The conversion lives at the repository
/// boundary — `fromJson` accepts `sodium_g` and exposes `sodiumMg` on
/// this presentation model. Widgets never see `sodium_g`. Re-reading the
/// rule in this file's docstring is deliberate: this is the seam.
class NutritionPer100g {
  const NutritionPer100g({
    this.energyKcal,
    this.proteinG,
    this.carbsG,
    this.fatG,
    this.fiberG,
    this.sugarG,
    this.sodiumMg,
    this.saturatedFatG,
  });

  final Decimal? energyKcal;
  final Decimal? proteinG;
  final Decimal? carbsG;
  final Decimal? fatG;
  final Decimal? fiberG;
  final Decimal? sugarG;

  /// Already converted from `sodium_g` at the repository boundary. Always
  /// milligrams on this model; never re-convert in widget code (T-21).
  final Decimal? sodiumMg;
  final Decimal? saturatedFatG;

  NutritionPer100g copyWith({
    Decimal? energyKcal,
    Decimal? proteinG,
    Decimal? carbsG,
    Decimal? fatG,
    Decimal? fiberG,
    Decimal? sugarG,
    Decimal? sodiumMg,
    Decimal? saturatedFatG,
  }) =>
      NutritionPer100g(
        energyKcal: energyKcal ?? this.energyKcal,
        proteinG: proteinG ?? this.proteinG,
        carbsG: carbsG ?? this.carbsG,
        fatG: fatG ?? this.fatG,
        fiberG: fiberG ?? this.fiberG,
        sugarG: sugarG ?? this.sugarG,
        sodiumMg: sodiumMg ?? this.sodiumMg,
        saturatedFatG: saturatedFatG ?? this.saturatedFatG,
      );

  /// Wire shape — `sodium_g` in grams. The factory converts via
  /// [gramsToMilligrams] and stores [sodiumMg] in the presentation model.
  factory NutritionPer100g.fromJson(Map<String, dynamic> json) {
    Decimal? dec(String key) {
      final v = json[key];
      if (v == null) return null;
      if (v is num) return Decimal.parse(v.toString());
      if (v is String) return Decimal.parse(v);
      throw ArgumentError.value(v, key, 'Not a number');
    }

    final sodiumG = dec('sodium_g');
    return NutritionPer100g(
      energyKcal: dec('energy_kcal'),
      proteinG: dec('protein_g'),
      carbsG: dec('carbs_g'),
      fatG: dec('fat_g'),
      fiberG: dec('fiber_g'),
      sugarG: dec('sugar_g'),
      sodiumMg: sodiumG == null ? null : gramsToMilligrams(sodiumG),
      saturatedFatG: dec('saturated_fat_g'),
    );
  }

  /// Wire shape — emit `sodium_g` in grams (divide by 1000) so this can
  /// round-trip an outgoing custom-food create. Real screens never need
  /// this on a read path; it exists for symmetry and `createCustom`.
  Map<String, dynamic> toJson() {
    Map<String, dynamic> m = <String, dynamic>{};
    if (energyKcal != null) m['energy_kcal'] = energyKcal.toString();
    if (proteinG != null) m['protein_g'] = proteinG.toString();
    if (carbsG != null) m['carbs_g'] = carbsG.toString();
    if (fatG != null) m['fat_g'] = fatG.toString();
    if (fiberG != null) m['fiber_g'] = fiberG.toString();
    if (sugarG != null) m['sugar_g'] = sugarG.toString();
    if (sodiumMg != null) {
      // mg → g for the wire. `Decimal / Decimal` returns a `Rational` in
      // decimal 3.x; round to 6 decimal places (sodium-on-wire is grams,
      // and 6 fractional digits covers any realistic value without
      // surfacing a recurring fraction).
      final g = (sodiumMg! / Decimal.fromInt(1000))
          .toDecimal(scaleOnInfinitePrecision: 6);
      m['sodium_g'] = g.toString();
    }
    if (saturatedFatG != null) m['saturated_fat_g'] = saturatedFatG.toString();
    return m;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NutritionPer100g &&
          other.energyKcal == energyKcal &&
          other.proteinG == proteinG &&
          other.carbsG == carbsG &&
          other.fatG == fatG &&
          other.fiberG == fiberG &&
          other.sugarG == sugarG &&
          other.sodiumMg == sodiumMg &&
          other.saturatedFatG == saturatedFatG;

  @override
  int get hashCode => Object.hash(
        energyKcal,
        proteinG,
        carbsG,
        fatG,
        fiberG,
        sugarG,
        sodiumMg,
        saturatedFatG,
      );
}

/// Frozen nutrition snapshot living on a `LogEntry`. Mirrors the flat
/// fields on `LogEntry` in the OpenAPI schema (caloriesKcal, proteinG,
/// carbsG, fatG, fiberG, sugarG, sodiumMg, saturatedFatG).
///
/// Sodium here is already milligrams (the wire field is `sodium_mg`).
class NutritionSnapshot {
  const NutritionSnapshot({
    required this.caloriesKcal,
    this.proteinG,
    this.carbsG,
    this.fatG,
    this.fiberG,
    this.sugarG,
    this.sodiumMg,
    this.saturatedFatG,
  });

  final Decimal caloriesKcal;
  final Decimal? proteinG;
  final Decimal? carbsG;
  final Decimal? fatG;
  final Decimal? fiberG;
  final Decimal? sugarG;
  final Decimal? sodiumMg;
  final Decimal? saturatedFatG;

  NutritionSnapshot copyWith({
    Decimal? caloriesKcal,
    Decimal? proteinG,
    Decimal? carbsG,
    Decimal? fatG,
    Decimal? fiberG,
    Decimal? sugarG,
    Decimal? sodiumMg,
    Decimal? saturatedFatG,
  }) =>
      NutritionSnapshot(
        caloriesKcal: caloriesKcal ?? this.caloriesKcal,
        proteinG: proteinG ?? this.proteinG,
        carbsG: carbsG ?? this.carbsG,
        fatG: fatG ?? this.fatG,
        fiberG: fiberG ?? this.fiberG,
        sugarG: sugarG ?? this.sugarG,
        sodiumMg: sodiumMg ?? this.sodiumMg,
        saturatedFatG: saturatedFatG ?? this.saturatedFatG,
      );

  factory NutritionSnapshot.fromJson(Map<String, dynamic> json) {
    Decimal? dec(String key) {
      final v = json[key];
      if (v == null) return null;
      if (v is num) return Decimal.parse(v.toString());
      if (v is String) return Decimal.parse(v);
      throw ArgumentError.value(v, key, 'Not a number');
    }

    final cal = dec('calories_kcal');
    if (cal == null) {
      throw ArgumentError('calories_kcal is required on a NutritionSnapshot');
    }
    return NutritionSnapshot(
      caloriesKcal: cal,
      proteinG: dec('protein_g'),
      carbsG: dec('carbs_g'),
      fatG: dec('fat_g'),
      fiberG: dec('fiber_g'),
      sugarG: dec('sugar_g'),
      sodiumMg: dec('sodium_mg'),
      saturatedFatG: dec('saturated_fat_g'),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'calories_kcal': caloriesKcal.toString(),
        if (proteinG != null) 'protein_g': proteinG.toString(),
        if (carbsG != null) 'carbs_g': carbsG.toString(),
        if (fatG != null) 'fat_g': fatG.toString(),
        if (fiberG != null) 'fiber_g': fiberG.toString(),
        if (sugarG != null) 'sugar_g': sugarG.toString(),
        if (sodiumMg != null) 'sodium_mg': sodiumMg.toString(),
        if (saturatedFatG != null) 'saturated_fat_g': saturatedFatG.toString(),
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NutritionSnapshot &&
          other.caloriesKcal == caloriesKcal &&
          other.proteinG == proteinG &&
          other.carbsG == carbsG &&
          other.fatG == fatG &&
          other.fiberG == fiberG &&
          other.sugarG == sugarG &&
          other.sodiumMg == sodiumMg &&
          other.saturatedFatG == saturatedFatG;

  @override
  int get hashCode => Object.hash(
        caloriesKcal,
        proteinG,
        carbsG,
        fatG,
        fiberG,
        sugarG,
        sodiumMg,
        saturatedFatG,
      );
}
