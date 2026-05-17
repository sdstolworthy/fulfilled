// Shared test builders — pure Dart, no annotations, no codegen.
//
// Audit finding #10 (P0): every test hand-rolls multi-line domain
// literals (`Food(...)`, `Serving(...)`, `LogEntry(...)`), pinning the
// test to specific kcal substrings and forcing a sweep of every test
// file every time a domain schema lands. The builders below collapse
// that mechanical work onto one file.
//
// Conventions:
//
// - Named parameters with sensible defaults. The default values are
//   chosen so the math is easy ("100 kcal per 100 g", quantity 1) and
//   so the *deviation from default* is what carries the test's intent.
// - Return the constructed type directly — no fluent builder chains.
// - Defaults intentionally satisfy domain invariants (a `Food` has at
//   least one serving; the only serving is `isDefault: true`; the
//   `LogEntry`'s snapshot kcal = `serving.kcal × quantity`). Tests that
//   want to assert *the rule* (preview = serving.kcal × quantity)
//   should pass the inputs and read the result from the builder, not
//   pin to a literal kcal value.

import 'package:decimal/decimal.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/food.dart';
import 'package:fulfilled/domain/log_entry.dart';
import 'package:fulfilled/domain/meal.dart';
import 'package:fulfilled/domain/nutrition.dart';
import 'package:fulfilled/domain/serving.dart';
import 'package:fulfilled/domain/unit.dart';

Decimal _d(String v) => Decimal.parse(v);

/// Default test serving: one 100 g serving at 100 kcal / 10 g protein /
/// 20 g carbs / 0 g fat. Marked `isDefault: true` so a [buildFood] with
/// just this serving has a well-formed defaulting story.
Serving buildServing({
  String id = 'sv_default',
  String? label = '100 g',
  Decimal? amount,
  Unit unit = Unit.g,
  Decimal? kcal,
  Decimal? proteinG,
  Decimal? carbsG,
  Decimal? fatG,
  Decimal? fiberG,
  Decimal? sugarG,
  Decimal? sodiumMg,
  Decimal? saturatedFatG,
  bool isDefault = true,
  ServingSource source = ServingSource.user,
  int sortOrder = 0,
}) {
  return Serving(
    id: id,
    label: label,
    amount: amount ?? _d('100'),
    unit: unit,
    kcal: kcal ?? _d('100'),
    proteinG: proteinG ?? _d('10'),
    carbsG: carbsG ?? _d('20'),
    fatG: fatG ?? Decimal.zero,
    fiberG: fiberG,
    sugarG: sugarG,
    sodiumMg: sodiumMg,
    saturatedFatG: saturatedFatG,
    isDefault: isDefault,
    source: source,
    sortOrder: sortOrder,
  );
}

/// Default test food: a single 100 g serving from [buildServing].
///
/// Tests that need a multi-serving food should pass an explicit
/// `servings` list (and remember to mark exactly one entry
/// `isDefault: true` — the audit's snapshot-rule test wants the
/// invariant, not the policy).
Food buildFood({
  String id = 'f_test',
  String name = 'Test food',
  String? brand = 'TestBrand',
  String? barcode,
  FoodSource source = FoodSource.off,
  bool? isCustom,
  int? qualityScore,
  NutriscoreGrade? nutriscore,
  List<Serving>? servings,
  List<String> categoriesTags = const <String>[],
  DateTime? createdAt,
}) {
  return Food(
    id: id,
    name: name,
    brand: brand,
    barcode: barcode,
    source: source,
    isCustom: isCustom ?? (source == FoodSource.user),
    qualityScore: qualityScore,
    nutriscore: nutriscore,
    servings: servings ?? <Serving>[buildServing()],
    categoriesTags: categoriesTags,
    createdAt: createdAt,
  );
}

/// Default nutrition snapshot — 100 kcal, matches [buildServing]'s
/// `kcal` so an entry built with quantity 1 lands on the snapshot rule.
NutritionSnapshot buildSnapshot({
  Decimal? caloriesKcal,
  Decimal? proteinG,
  Decimal? carbsG,
  Decimal? fatG,
  Decimal? fiberG,
  Decimal? sugarG,
  Decimal? sodiumMg,
  Decimal? saturatedFatG,
}) {
  return NutritionSnapshot(
    caloriesKcal: caloriesKcal ?? _d('100'),
    proteinG: proteinG,
    carbsG: carbsG,
    fatG: fatG,
    fiberG: fiberG,
    sugarG: sugarG,
    sodiumMg: sodiumMg,
    saturatedFatG: saturatedFatG,
  );
}

/// Default test log entry. Defaults reference the same food/serving
/// ids as [buildFood] / [buildServing] so a chained call —
/// `buildLogEntry(food: buildFood())` — round-trips consistently.
LogEntry buildLogEntry({
  String id = 'le_test',
  String foodId = 'f_test',
  String foodName = 'Test food',
  String? servingId = 'sv_default',
  String? servingName = '100 g',
  DateTime? consumedOn,
  Meal meal = Meal.lunch,
  Decimal? quantity,
  Decimal? enteredAmount,
  Unit enteredUnit = Unit.g,
  NutritionSnapshot? nutritionSnapshot,
  String? note,
  DateTime? createdAt,
  DateTime? updatedAt,
}) {
  final q = quantity ?? Decimal.one;
  final on = consumedOn ?? DateTime(2026, 5, 1);
  final ts = createdAt ?? DateTime(2026, 5, 1, 12, 30);
  return LogEntry(
    id: id,
    foodId: foodId,
    foodName: foodName,
    servingId: servingId,
    servingName: servingName,
    consumedOn: DateTime(on.year, on.month, on.day),
    meal: meal,
    quantity: q,
    enteredAmount: enteredAmount ?? (_d('100') * q),
    enteredUnit: enteredUnit,
    nutritionSnapshot: nutritionSnapshot ?? buildSnapshot(),
    note: note,
    createdAt: ts,
    updatedAt: updatedAt ?? ts,
  );
}
