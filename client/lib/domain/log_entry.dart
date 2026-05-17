import 'package:decimal/decimal.dart';

import 'meal.dart';
import 'nutrition.dart';
import 'unit.dart';

/// One row in the food log. Mirrors `LogEntry` from the OpenAPI schema
/// under Ask 10 — the per-100g math is gone. The wire carries:
///
/// - `quantity` — multiplier against the referenced serving's nutrition
/// - `entered_amount` + `entered_unit` — exactly what the user typed at
///   entry time (preserved across serving edits / deletes)
/// - the snapshotted nutrition fields (`calories_kcal`, macros) — lifted
///   into [NutritionSnapshot] as before.
///
/// The food name + serving name are denormalized onto the entry by the
/// server (Ask 9 / 10c) so the day-view's `FoodRow` renders without a
/// second fetch.
class LogEntry {
  const LogEntry({
    required this.id,
    required this.foodId,
    required this.foodName,
    required this.consumedOn,
    required this.meal,
    required this.quantity,
    required this.enteredAmount,
    required this.enteredUnit,
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

  /// Multiplier against the referenced serving — `0.5` means "half a
  /// cup" when the serving is `{1, cup}`. Always derivable from
  /// [enteredAmount] + the serving's `amount` after a within-family
  /// conversion, but stored so the snapshot pattern survives serving
  /// edits.
  final Decimal quantity;

  /// What the user typed at entry time. Preserved across serving
  /// edits and deletes so the "you logged X" display never lies.
  final Decimal enteredAmount;
  final Unit enteredUnit;

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
    Decimal? enteredAmount,
    Unit? enteredUnit,
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
        enteredAmount: enteredAmount ?? this.enteredAmount,
        enteredUnit: enteredUnit ?? this.enteredUnit,
        nutritionSnapshot: nutritionSnapshot ?? this.nutritionSnapshot,
        note: note ?? this.note,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  /// Convenience getter — calorie count, the only frozen number the
  /// day view actually displays per row.
  Decimal get kcal => nutritionSnapshot.caloriesKcal;

  factory LogEntry.fromJson(Map<String, dynamic> json) {
    Decimal dec(String key) =>
        Decimal.parse((json[key] as Object).toString());
    return LogEntry(
      id: json['id'] as String,
      foodId: json['food_id'] as String,
      foodName: (json['food_name'] as String?) ?? '',
      servingId: json['serving_id'] as String?,
      servingName: json['serving_name'] as String?,
      consumedOn: DateTime.parse(json['consumed_on'] as String),
      meal: Meal.fromWire(json['meal'] as String),
      quantity: dec('quantity'),
      enteredAmount: dec('entered_amount'),
      enteredUnit: Unit.fromWire(json['entered_unit'] as String),
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
      'entered_amount': enteredAmount.toString(),
      'entered_unit': enteredUnit.wire,
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
          other.enteredAmount == enteredAmount &&
          other.enteredUnit == enteredUnit &&
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
        enteredAmount,
        enteredUnit,
        nutritionSnapshot,
        note,
        createdAt,
        updatedAt,
      );
}

/// Outgoing `PATCH /log/{id}` payload. The log-entry sheet's edit mode
/// builds one and hands it to `log_repository.update`. The patch is
/// sparse on the wire — only fields the user actually changed are
/// emitted. `food_id` is **never** serialised: the OpenAPI spec
/// explicitly forbids mutating the food on PATCH.
class LogPatch {
  const LogPatch({
    this.servingId,
    this.consumedOn,
    this.meal,
    this.quantity,
    this.enteredAmount,
    this.enteredUnit,
    this.note,
    this.clearNote = false,
  });

  final String? servingId;
  final DateTime? consumedOn;
  final Meal? meal;
  final Decimal? quantity;
  final Decimal? enteredAmount;
  final Unit? enteredUnit;
  final String? note;
  final bool clearNote;

  bool get isEmpty =>
      servingId == null &&
      consumedOn == null &&
      meal == null &&
      quantity == null &&
      enteredAmount == null &&
      enteredUnit == null &&
      note == null &&
      !clearNote;

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{};
    if (servingId != null) m['serving_id'] = servingId;
    if (consumedOn != null) m['consumed_on'] = _isoDate(consumedOn!);
    if (meal != null) m['meal'] = meal!.wire;
    if (quantity != null) m['quantity'] = quantity.toString();
    if (enteredAmount != null) m['entered_amount'] = enteredAmount.toString();
    if (enteredUnit != null) m['entered_unit'] = enteredUnit!.wire;
    if (note != null) {
      m['note'] = note;
    } else if (clearNote) {
      m['note'] = null;
    }
    return m;
  }
}

class LogEntryNotFoundError implements Exception {
  LogEntryNotFoundError(this.entryId);

  final String entryId;

  @override
  String toString() => 'LogEntryNotFoundError: $entryId';
}

/// Outgoing `POST /log` payload. Mirrors the new wire shape under Ask
/// 10: drop `grams_total`, add `entered_amount` + `entered_unit`.
/// `serving_id` is required (every log entry references a serving;
/// quick-add uses the per-user sentinel food's "1 serving" entry).
class LogCreate {
  const LogCreate({
    required this.foodId,
    required this.servingId,
    required this.consumedOn,
    required this.meal,
    required this.quantity,
    required this.enteredAmount,
    required this.enteredUnit,
    this.note,
  });

  final String foodId;
  final String servingId;
  final DateTime consumedOn;
  final Meal meal;
  final Decimal quantity;
  final Decimal enteredAmount;
  final Unit enteredUnit;
  final String? note;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'food_id': foodId,
        'serving_id': servingId,
        'consumed_on': _isoDate(consumedOn),
        'meal': meal.wire,
        'quantity': quantity.toString(),
        'entered_amount': enteredAmount.toString(),
        'entered_unit': enteredUnit.wire,
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
