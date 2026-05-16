import 'package:decimal/decimal.dart';

import 'meal.dart';
import 'nutrition.dart';

/// One row in the food log. Mirrors `LogEntry` from the OpenAPI schema —
/// the nutrition snapshot is **flat** on the wire (`calories_kcal`,
/// `protein_g`, …) and we lift it into a [NutritionSnapshot] in the
/// presentation model so screens have a tidy `entry.nutritionSnapshot`
/// instead of nine sibling fields.
///
/// The food name + serving name are denormalized onto this entry so the
/// day-view's `FoodRow` can render without a second fetch. The wire
/// does *not* return them — the mock repository fills them from its
/// catalog; the eventual real client will either join server-side or
/// resolve via a foods cache.
class LogEntry {
  const LogEntry({
    required this.id,
    required this.foodId,
    required this.foodName,
    required this.consumedOn,
    required this.meal,
    required this.quantity,
    required this.gramsTotal,
    required this.nutritionSnapshot,
    required this.createdAt,
    required this.updatedAt,
    this.servingId,
    this.servingName,
    this.note,
  });

  final String id;
  final String foodId;
  final String foodName;
  final String? servingId;
  final String? servingName;

  /// User-local calendar date. `YYYY-MM-DD` on the wire (T-16).
  final DateTime consumedOn;
  final Meal meal;
  final Decimal quantity;
  final Decimal gramsTotal;
  final NutritionSnapshot nutritionSnapshot;
  final String? note;
  final DateTime createdAt;
  final DateTime updatedAt;

  LogEntry copyWith({
    String? id,
    String? foodId,
    String? foodName,
    String? servingId,
    String? servingName,
    DateTime? consumedOn,
    Meal? meal,
    Decimal? quantity,
    Decimal? gramsTotal,
    NutritionSnapshot? nutritionSnapshot,
    String? note,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      LogEntry(
        id: id ?? this.id,
        foodId: foodId ?? this.foodId,
        foodName: foodName ?? this.foodName,
        servingId: servingId ?? this.servingId,
        servingName: servingName ?? this.servingName,
        consumedOn: consumedOn ?? this.consumedOn,
        meal: meal ?? this.meal,
        quantity: quantity ?? this.quantity,
        gramsTotal: gramsTotal ?? this.gramsTotal,
        nutritionSnapshot: nutritionSnapshot ?? this.nutritionSnapshot,
        note: note ?? this.note,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  /// Convenience getter — calorie count, the only frozen number the day
  /// view actually displays per row.
  Decimal get kcal => nutritionSnapshot.caloriesKcal;

  factory LogEntry.fromJson(Map<String, dynamic> json) {
    Decimal dec(String key) =>
        Decimal.parse((json[key] as Object).toString());
    return LogEntry(
      id: json['id'] as String,
      foodId: json['food_id'] as String,
      // `food_name` / `serving_name` are not in the OpenAPI shape but the
      // mock repository denormalizes them. Fall back to "" on a real
      // response so this `fromJson` is safe for both seed JSON and
      // hypothetical wire JSON.
      foodName: (json['food_name'] as String?) ?? '',
      servingId: json['serving_id'] as String?,
      servingName: json['serving_name'] as String?,
      consumedOn: DateTime.parse(json['consumed_on'] as String),
      meal: Meal.fromWire(json['meal'] as String),
      quantity: dec('quantity'),
      gramsTotal: dec('grams_total'),
      nutritionSnapshot: NutritionSnapshot.fromJson(json),
      note: json['note'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'id': id,
      'food_id': foodId,
      'food_name': foodName,
      if (servingId != null) 'serving_id': servingId,
      if (servingName != null) 'serving_name': servingName,
      'consumed_on': _isoDate(consumedOn),
      'meal': meal.wire,
      'quantity': quantity.toString(),
      'grams_total': gramsTotal.toString(),
      if (note != null) 'note': note,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
    m.addAll(nutritionSnapshot.toJson());
    return m;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LogEntry &&
          other.id == id &&
          other.foodId == foodId &&
          other.foodName == foodName &&
          other.servingId == servingId &&
          other.servingName == servingName &&
          other.consumedOn == consumedOn &&
          other.meal == meal &&
          other.quantity == quantity &&
          other.gramsTotal == gramsTotal &&
          other.nutritionSnapshot == nutritionSnapshot &&
          other.note == note &&
          other.createdAt == createdAt &&
          other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(
        id,
        foodId,
        foodName,
        servingId,
        servingName,
        consumedOn,
        meal,
        quantity,
        gramsTotal,
        nutritionSnapshot,
        note,
        createdAt,
        updatedAt,
      );
}

/// Outgoing `POST /log` payload. Screen 04's log-entry sheet builds one
/// and hands it to `log_repository.create`. The mock repository computes
/// the frozen snapshot from the food's per-100 g + the serving's grams +
/// the quantity — matching the server's behavior.
class LogCreate {
  const LogCreate({
    required this.foodId,
    required this.servingId,
    required this.consumedOn,
    required this.meal,
    required this.quantity,
    this.note,
  });

  final String foodId;
  final String servingId;
  final DateTime consumedOn;
  final Meal meal;
  final Decimal quantity;
  final String? note;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'food_id': foodId,
        'serving_id': servingId,
        'consumed_on': _isoDate(consumedOn),
        'meal': meal.wire,
        'quantity': quantity.toString(),
        if (note != null) 'note': note,
      };
}

/// `YYYY-MM-DD` formatter that doesn't pull in `intl` for one call.
/// Matches the OpenAPI `date` format.
String _isoDate(DateTime d) {
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}
