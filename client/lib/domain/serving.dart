import 'package:decimal/decimal.dart';

import 'enums.dart';
import 'unit.dart';

/// One serving on a food. Mirrors the `Serving` schema from the
/// OpenAPI spec under Ask 10 (per-serving nutrition; no per-100g
/// anchor). The user types `{amount, unit, kcal-for-that-serving,
/// macros-for-that-serving}` and we store it verbatim — the system
/// trusts the user's number.
///
/// `kcal` is the only required nutrient; protein/carbs/fat/etc are
/// nullable because the source data is often incomplete. Widgets
/// render missing macros as "—", never as "0 g."
///
/// `amount` + `unit` together describe what one of "this serving" is.
/// `unit` is the structured [Unit] enum — its family decides which
/// conversion offers the log-entry sheet surfaces (mass → g/oz/lb,
/// volume → ml/cup/fl_oz/tbsp/tsp, count → no auto-conversion).
class Serving {
  const Serving({
    required this.id,
    required this.amount,
    required this.unit,
    required this.kcal,
    required this.isDefault,
    required this.source,
    this.label,
    this.proteinG,
    this.carbsG,
    this.fatG,
    this.fiberG,
    this.sugarG,
    this.sodiumMg,
    this.saturatedFatG,
    this.sortOrder = 0,
  });

  /// Stable id (UUID on the wire).
  final String id;

  /// Optional user-supplied descriptor — "1 pouch (90 g)", "small",
  /// "cooked". Nullable on the new wire shape; widgets fall back to
  /// `formatAmountUnit(amount, unit)` when absent (see [name]).
  final String? label;

  final Decimal amount;
  final Unit unit;

  /// Calories for one of this serving. Always non-null per Ask 10
  /// schema (`kcal NOT NULL`).
  final Decimal kcal;

  /// Macros for one of this serving. All nullable on the wire; widgets
  /// must guard. Sodium is in milligrams on this presentation model
  /// (the wire field is `sodium_mg`, no unit conversion at the
  /// boundary — unlike the old `NutritionPer100g.sodium_g`).
  final Decimal? proteinG;
  final Decimal? carbsG;
  final Decimal? fatG;
  final Decimal? fiberG;
  final Decimal? sugarG;
  final Decimal? sodiumMg;
  final Decimal? saturatedFatG;

  final bool isDefault;
  final ServingSource source;
  final int sortOrder;

  /// Display name. Returns the explicit [label] when present;
  /// otherwise renders `formatAmountUnit(amount, unit)` so a serving
  /// without a label still has something legible to show.
  String get name => label ?? formatAmountUnit(amount, unit);

  /// Family of [unit]. Drives "which units does the log-entry sheet
  /// offer for this serving."
  UnitFamily get family => unit.family;

  /// kcal for [quantity] of this serving (quantity is the multiplier
  /// the log entry stores — 0.5 means half of one serving).
  Decimal kcalFor(Decimal quantity) {
    return (kcal * quantity).toDecimal(scaleOnInfinitePrecision: 6);
  }

  /// One macro field scaled by [quantity]. Returns null when the macro
  /// is null on the serving.
  Decimal? macroFor(Decimal quantity, Decimal? value) {
    if (value == null) return null;
    return (value * quantity).toDecimal(scaleOnInfinitePrecision: 6);
  }

  Serving copyWith({
    String? id,
    String? label,
    Decimal? amount,
    Unit? unit,
    Decimal? kcal,
    Decimal? proteinG,
    Decimal? carbsG,
    Decimal? fatG,
    Decimal? fiberG,
    Decimal? sugarG,
    Decimal? sodiumMg,
    Decimal? saturatedFatG,
    bool? isDefault,
    ServingSource? source,
    int? sortOrder,
  }) =>
      Serving(
        id: id ?? this.id,
        label: label ?? this.label,
        amount: amount ?? this.amount,
        unit: unit ?? this.unit,
        kcal: kcal ?? this.kcal,
        proteinG: proteinG ?? this.proteinG,
        carbsG: carbsG ?? this.carbsG,
        fatG: fatG ?? this.fatG,
        fiberG: fiberG ?? this.fiberG,
        sugarG: sugarG ?? this.sugarG,
        sodiumMg: sodiumMg ?? this.sodiumMg,
        saturatedFatG: saturatedFatG ?? this.saturatedFatG,
        isDefault: isDefault ?? this.isDefault,
        source: source ?? this.source,
        sortOrder: sortOrder ?? this.sortOrder,
      );

  factory Serving.fromJson(Map<String, dynamic> json) {
    Decimal? dec(String key) {
      final v = json[key];
      if (v == null) return null;
      if (v is num) return Decimal.parse(v.toString());
      if (v is String) return Decimal.parse(v);
      throw ArgumentError.value(v, key, 'Not a number');
    }

    final kcal = dec('kcal');
    if (kcal == null) {
      throw ArgumentError('kcal is required on a Serving');
    }
    final amount = dec('amount');
    if (amount == null) {
      throw ArgumentError('amount is required on a Serving');
    }
    return Serving(
      id: json['id'] as String,
      label: json['label'] as String?,
      amount: amount,
      unit: Unit.fromWire(json['unit'] as String),
      kcal: kcal,
      proteinG: dec('protein_g'),
      carbsG: dec('carbs_g'),
      fatG: dec('fat_g'),
      fiberG: dec('fiber_g'),
      sugarG: dec('sugar_g'),
      sodiumMg: dec('sodium_mg'),
      saturatedFatG: dec('saturated_fat_g'),
      isDefault: json['is_default'] as bool,
      source: ServingSource.fromWire(json['source'] as String),
      sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
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
        if (saturatedFatG != null) 'saturated_fat_g': saturatedFatG.toString(),
        'is_default': isDefault,
        'source': source.wire,
        'sort_order': sortOrder,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Serving &&
          other.id == id &&
          other.label == label &&
          other.amount == amount &&
          other.unit == unit &&
          other.kcal == kcal &&
          other.proteinG == proteinG &&
          other.carbsG == carbsG &&
          other.fatG == fatG &&
          other.fiberG == fiberG &&
          other.sugarG == sugarG &&
          other.sodiumMg == sodiumMg &&
          other.saturatedFatG == saturatedFatG &&
          other.isDefault == isDefault &&
          other.source == source &&
          other.sortOrder == sortOrder;

  @override
  int get hashCode => Object.hash(
        id,
        label,
        amount,
        unit,
        kcal,
        proteinG,
        carbsG,
        fatG,
        fiberG,
        sugarG,
        sodiumMg,
        saturatedFatG,
        isDefault,
        source,
        sortOrder,
      );
}
