// MOCK ONLY — deletable with the rest of the seed fixtures.

import 'package:decimal/decimal.dart';

import '../domain/day_summary.dart';
import '../domain/food.dart';
import '../domain/goal.dart';
import '../domain/log_entry.dart';
import '../domain/meal.dart';
import '../domain/serving.dart';
import '_clock.dart';

class _LogSeed {
  const _LogSeed({
    required this.foodId,
    required this.servingId,
    required this.meal,
    required this.quantity,
    this.note,
  });
  final String foodId;
  final String servingId;
  final Meal meal;
  final Decimal quantity;
  final String? note;
}

List<LogEntry> buildSeedLogEntries(List<Food> foods) {
  Food food(String id) => foods.firstWhere((f) => f.id == id);

  final byDay = <int, List<_LogSeed>>{
    0: <_LogSeed>[
      _LogSeed(
        foodId: 'f_oatmeal_rolled',
        servingId: 'sv_oats_half_cup',
        meal: Meal.breakfast,
        quantity: dec('1'),
        note: 'with almond milk',
      ),
      _LogSeed(
        foodId: 'f_greek_yogurt_plain',
        servingId: 'sv_greek_yogurt_container',
        meal: Meal.breakfast,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_chicken_breast',
        servingId: 'sv_chicken_breast_piece',
        meal: Meal.lunch,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_brown_rice',
        servingId: 'sv_rice_cup',
        meal: Meal.lunch,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_broccoli',
        servingId: 'sv_broccoli_cup',
        meal: Meal.lunch,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_apple_raw',
        servingId: 'sv_apple_medium',
        meal: Meal.snack,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_almonds',
        servingId: 'sv_almonds_ounce',
        meal: Meal.snack,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_salmon_atlantic',
        servingId: 'sv_salmon_fillet',
        meal: Meal.dinner,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_pasta_penne',
        servingId: 'sv_penne_serving',
        meal: Meal.dinner,
        quantity: dec('1.5'),
      ),
      _LogSeed(
        foodId: 'f_olive_oil',
        servingId: 'sv_oo_tbsp',
        meal: Meal.dinner,
        quantity: dec('1'),
      ),
    ],
    1: <_LogSeed>[
      _LogSeed(
        foodId: 'f_oatmeal_rolled',
        servingId: 'sv_oats_half_cup',
        meal: Meal.breakfast,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_banana_raw',
        servingId: 'sv_banana_medium',
        meal: Meal.breakfast,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_moms_lasagna',
        servingId: 'sv_lasagna_slice',
        meal: Meal.dinner,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_dark_chocolate',
        servingId: 'sv_choco_square',
        meal: Meal.snack,
        quantity: dec('1'),
      ),
    ],
    2: <_LogSeed>[
      _LogSeed(
        foodId: 'f_protein_bar',
        servingId: 'sv_quest_bar',
        meal: Meal.breakfast,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_dad_chili',
        servingId: 'sv_chili_bowl',
        meal: Meal.lunch,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_home_smoothie',
        servingId: 'sv_smoothie_glass',
        meal: Meal.snack,
        quantity: dec('1'),
      ),
    ],
    3: <_LogSeed>[
      _LogSeed(
        foodId: 'f_egg_large',
        servingId: 'sv_egg_large',
        meal: Meal.breakfast,
        quantity: dec('2'),
      ),
      _LogSeed(
        foodId: 'f_whole_wheat_bread',
        servingId: 'sv_bread_slice',
        meal: Meal.breakfast,
        quantity: dec('2'),
      ),
      _LogSeed(
        foodId: 'f_chicken_breast',
        servingId: 'sv_chicken_breast_piece',
        meal: Meal.lunch,
        quantity: dec('1'),
      ),
    ],
    4: <_LogSeed>[
      _LogSeed(
        foodId: 'f_cottage_cheese',
        servingId: 'sv_cottage_half_cup',
        meal: Meal.breakfast,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_apple_raw',
        servingId: 'sv_apple_medium',
        meal: Meal.snack,
        quantity: dec('1'),
      ),
    ],
    5: <_LogSeed>[
      _LogSeed(
        foodId: 'f_oatmeal_rolled',
        servingId: 'sv_oats_half_cup',
        meal: Meal.breakfast,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_chicken_breast',
        servingId: 'sv_chicken_breast_piece',
        meal: Meal.lunch,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_avocado',
        servingId: 'sv_avocado_half',
        meal: Meal.lunch,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_dad_chili',
        servingId: 'sv_chili_bowl',
        meal: Meal.dinner,
        quantity: dec('1'),
      ),
    ],
    6: <_LogSeed>[
      _LogSeed(
        foodId: 'f_cliff_bar',
        servingId: 'sv_clif_bar',
        meal: Meal.snack,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_salmon_atlantic',
        servingId: 'sv_salmon_fillet',
        meal: Meal.dinner,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_brown_rice',
        servingId: 'sv_rice_cup',
        meal: Meal.dinner,
        quantity: dec('0.75'),
      ),
    ],
  };

  final out = <LogEntry>[];
  var seq = 0;
  for (final entry in byDay.entries) {
    final dayOffset = entry.key;
    final seeds = entry.value;
    for (final seed in seeds) {
      final f = food(seed.foodId);
      final serv = f.servings.firstWhere((s) => s.id == seed.servingId);
      final hour = _hourForMeal(seed.meal);
      final at = dayAt(dayOffset, hour, 0 + (seq % 30));
      out.add(
        computeLogEntry(
          id: 'le_${dayOffset}_${seq++}',
          food: f,
          serving: serv,
          consumedOn: DateTime(at.year, at.month, at.day),
          meal: seed.meal,
          quantity: seed.quantity,
          createdAt: at,
          note: seed.note,
        ),
      );
    }
  }
  return out;
}

int _hourForMeal(Meal m) {
  switch (m) {
    case Meal.breakfast:
      return 8;
    case Meal.lunch:
      return 12;
    case Meal.dinner:
      return 19;
    case Meal.snack:
      return 15;
  }
}

/// Build a [LogEntry] with the frozen nutrition snapshot computed from
/// `serving.<nutrient> × quantity`. The math lives on
/// [LogEntry.snapshotFor] (audit finding #7); this thin wrapper is
/// kept so the in-file seed data and `_fixture_log_entries` builders
/// stay readable.
LogEntry computeLogEntry({
  required String id,
  required Food food,
  required Serving serving,
  required DateTime consumedOn,
  required Meal meal,
  required Decimal quantity,
  required DateTime createdAt,
  String? note,
}) =>
    LogEntry.snapshotFor(
      id: id,
      food: food,
      serving: serving,
      consumedOn: consumedOn,
      meal: meal,
      quantity: quantity,
      createdAt: createdAt,
      note: note,
    );

// ─── Day summary builder ─────────────────────────────────────────────────

DaySummary buildDaySummary({
  required DateTime date,
  required List<LogEntry> entriesOnDate,
  required Goal? activeGoal,
}) {
  Decimal kcal = Decimal.zero;
  Decimal protein = Decimal.zero;
  Decimal carbs = Decimal.zero;
  Decimal fat = Decimal.zero;

  final byMeal = <Meal, MealSubtotal>{
    for (final m in Meal.values) m: MealSubtotal.empty(m),
  };

  for (final e in entriesOnDate) {
    kcal = kcal + e.nutritionSnapshot.caloriesKcal;
    protein = protein + (e.nutritionSnapshot.proteinG ?? Decimal.zero);
    carbs = carbs + (e.nutritionSnapshot.carbsG ?? Decimal.zero);
    fat = fat + (e.nutritionSnapshot.fatG ?? Decimal.zero);
    final prev = byMeal[e.meal] ?? MealSubtotal.empty(e.meal);
    byMeal[e.meal] = MealSubtotal(
      meal: e.meal,
      kcal: prev.kcal + e.nutritionSnapshot.caloriesKcal,
      proteinG: prev.proteinG + (e.nutritionSnapshot.proteinG ?? Decimal.zero),
      carbsG: prev.carbsG + (e.nutritionSnapshot.carbsG ?? Decimal.zero),
      fatG: prev.fatG + (e.nutritionSnapshot.fatG ?? Decimal.zero),
      entryCount: prev.entryCount + 1,
    );
  }

  return DaySummary(
    date: date,
    kcal: kcal,
    protein: protein,
    carbs: carbs,
    fat: fat,
    kcalTarget: activeGoal?.dailyCalorieTarget == null
        ? null
        : Decimal.fromInt(activeGoal!.dailyCalorieTarget!),
    proteinTarget: activeGoal?.proteinTargetG,
    carbsTarget: activeGoal?.carbsTargetG,
    fatTarget: activeGoal?.fatTargetG,
    byMeal: byMeal,
    activeGoal: activeGoal,
  );
}
