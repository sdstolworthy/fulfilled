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

/// Outgoing `PATCH /log/{id}` payload. The log-entry sheet's edit mode
/// builds one and hands it to `log_repository.update`. The patch is
/// sparse on the wire — only fields the user actually changed are
/// emitted. `food_id` is **never** serialised: the OpenAPI spec
/// explicitly forbids mutating the food on PATCH (PM ruling), so it is
/// not even modeled here. Callers that try to patch the food must
/// instead delete + recreate the entry.
///
/// `clearNote` is the one piece of out-of-band signalling we need:
/// "absence" of a key on the wire means "leave unchanged", while
/// `"note": null` means "clear the existing note". The sheet sets
/// `clearNote: true` when the user blanked a previously-non-null note.
/// If both `note` and `clearNote` are set, the explicit `note` wins —
/// `clearNote` only fires when `note == null`.
class LogPatch {
  const LogPatch({
    this.servingId,
    this.consumedOn,
    this.meal,
    this.quantity,
    this.note,
    this.clearNote = false,
  });

  final String? servingId;
  final DateTime? consumedOn;
  final Meal? meal;
  final Decimal? quantity;
  final String? note;

  /// When `true` and [note] is null, emit `'note': null` to clear an
  /// existing note. When `false` (default), an unset [note] is omitted
  /// from the wire entirely. Ignored when [note] is non-null — the
  /// explicit value always wins.
  final bool clearNote;

  /// `true` iff every patchable field is unset and we're not clearing
  /// the note. The submit handler short-circuits on this to skip
  /// no-op PATCHes.
  bool get isEmpty =>
      servingId == null &&
      consumedOn == null &&
      meal == null &&
      quantity == null &&
      note == null &&
      !clearNote;

  /// Sparse JSON encoder. Only emits keys for set fields. Never emits
  /// `food_id` — see class docs.
  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{};
    if (servingId != null) m['serving_id'] = servingId;
    if (consumedOn != null) m['consumed_on'] = _isoDate(consumedOn!);
    if (meal != null) m['meal'] = meal!.wire;
    if (quantity != null) m['quantity'] = quantity.toString();
    if (note != null) {
      m['note'] = note;
    } else if (clearNote) {
      m['note'] = null;
    }
    return m;
  }
}

/// Thrown by `LogRepository.update` (and any future single-entry
/// lookup) when the entry id is not in the store. Mirrors
/// `FoodNotFoundError` from `food_repository.dart` — same shape so
/// screen-level `try/catch` blocks read uniformly.
class LogEntryNotFoundError implements Exception {
  LogEntryNotFoundError(this.entryId);

  final String entryId;

  @override
  String toString() => 'LogEntryNotFoundError: $entryId';
}

/// Outgoing `POST /log` payload. Screen 04's log-entry sheet builds one
/// and hands it to `log_repository.create`. The mock repository computes
/// the frozen snapshot from the food's per-100 g + the serving's grams +
/// the quantity — matching the server's behavior.
///
/// **Quick-add macros override.** The Quick-add affordance on the Today
/// header logs raw kcal against the synthetic `food_quick_add` food (per
/// 100 g = 100 kcal, 1 g serving), so `quantity` maps 1:1 to kcal. When
/// the user toggles "Add macros" the sheet supplies a sparse
/// [nutritionOverride] (energy + P/C/F only) on the create payload; the
/// mock `LogRepository.create` substitutes this for the computed
/// `nutritionPer100g` before running the existing `computeLogEntry` math.
/// On the wire this is a non-standard addition — the field is **not**
/// serialised by [toJson] (it's a client-only seam until the spec adds a
/// "free-form calories" endpoint). Normal log-entry flows leave it null
/// and the existing snapshot computation is preserved byte-for-byte.
class LogCreate {
  const LogCreate({
    required this.foodId,
    required this.servingId,
    required this.consumedOn,
    required this.meal,
    required this.quantity,
    this.note,
    this.nutritionOverride,
  });

  final String foodId;
  final String servingId;
  final DateTime consumedOn;
  final Meal meal;
  final Decimal quantity;
  final String? note;

  /// Optional per-100 g panel override. When non-null, the mock
  /// repository substitutes this for the food's `nutritionPer100g`
  /// before computing the frozen snapshot — enabling the Quick-add
  /// sheet's "Add macros" toggle to carry user-supplied P/C/F values
  /// without needing a new "free-form calories" wire endpoint. Not
  /// emitted by [toJson]; this is a client-only seam.
  final NutritionPer100g? nutritionOverride;

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
