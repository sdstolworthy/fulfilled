import 'package:decimal/decimal.dart';

/// Frozen nutrition snapshot living on a `LogEntry`. Mirrors the flat
/// fields on `LogEntry` in the OpenAPI schema (`calories_kcal`,
/// `protein_g`, `carbs_g`, `fat_g`, `fiber_g`, `sugar_g`, `sodium_mg`,
/// `saturated_fat_g`).
///
/// Sodium is in milligrams on this presentation model — matches the
/// wire field `sodium_mg`. Ask 10 removed the per-100g panel
/// (`NutritionPer100g`) entirely; the only nutrition struct left is
/// this one (used by `LogEntry`) and the inlined per-serving fields on
/// [Serving].
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
