import 'package:decimal/decimal.dart';

import 'goal.dart';
import 'meal.dart';

/// Per-meal subtotal on a `DaySummary`. Mirrors the OpenAPI
/// `MealSubtotal`. `entryCount` lets the day-view show "Dinner — 0 kcal"
/// without re-counting from the entries list.
class MealSubtotal {
  const MealSubtotal({
    required this.meal,
    required this.kcal,
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
    required this.entryCount,
  });

  final Meal meal;
  final Decimal kcal;
  final Decimal proteinG;
  final Decimal carbsG;
  final Decimal fatG;
  final int entryCount;

  MealSubtotal copyWith({
    Meal? meal,
    Decimal? kcal,
    Decimal? proteinG,
    Decimal? carbsG,
    Decimal? fatG,
    int? entryCount,
  }) =>
      MealSubtotal(
        meal: meal ?? this.meal,
        kcal: kcal ?? this.kcal,
        proteinG: proteinG ?? this.proteinG,
        carbsG: carbsG ?? this.carbsG,
        fatG: fatG ?? this.fatG,
        entryCount: entryCount ?? this.entryCount,
      );

  /// Empty subtotal for a meal with no entries.
  factory MealSubtotal.empty(Meal meal) => MealSubtotal(
        meal: meal,
        kcal: Decimal.zero,
        proteinG: Decimal.zero,
        carbsG: Decimal.zero,
        fatG: Decimal.zero,
        entryCount: 0,
      );

  factory MealSubtotal.fromJson(Map<String, dynamic> json) => MealSubtotal(
        meal: Meal.fromWire(json['meal'] as String),
        kcal: Decimal.parse((json['calories_kcal'] as Object).toString()),
        proteinG: Decimal.parse((json['protein_g'] as Object).toString()),
        carbsG: Decimal.parse((json['carbs_g'] as Object).toString()),
        fatG: Decimal.parse((json['fat_g'] as Object).toString()),
        entryCount: (json['entry_count'] as num).toInt(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'meal': meal.wire,
        'calories_kcal': kcal.toString(),
        'protein_g': proteinG.toString(),
        'carbs_g': carbsG.toString(),
        'fat_g': fatG.toString(),
        'entry_count': entryCount,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MealSubtotal &&
          other.meal == meal &&
          other.kcal == kcal &&
          other.proteinG == proteinG &&
          other.carbsG == carbsG &&
          other.fatG == fatG &&
          other.entryCount == entryCount;

  @override
  int get hashCode => Object.hash(meal, kcal, proteinG, carbsG, fatG, entryCount);
}

/// Per-day rollup the day-view's ring + meal cards consume.
///
/// **T-09 anchor**: every "today total" surface in the UI (the ring, the
/// ring-summary card, the right-rail summary, the log-preview block on
/// screen 04) reads from this same model. Don't compute totals
/// out-of-band in a widget.
///
/// The `*Target` fields are pulled from the day's active goal so the
/// macro bars don't need a second provider read. If there's no active
/// goal on the day, the targets are nulls and the widgets render a
/// "Set a goal" affordance instead of bars.
class DaySummary {
  const DaySummary({
    required this.date,
    required this.kcal,
    required this.protein,
    required this.carbs,
    required this.fat,
    required this.byMeal,
    this.kcalTarget,
    this.proteinTarget,
    this.carbsTarget,
    this.fatTarget,
    this.activeGoal,
  });

  final DateTime date;
  final Decimal kcal;
  final Decimal protein;
  final Decimal carbs;
  final Decimal fat;

  /// Daily kcal target lifted from the day's active goal. Integer on the
  /// wire (`int32`); kept as `Decimal` here for consistent arithmetic
  /// against the consumed total (the ring's "kcal left" math).
  final Decimal? kcalTarget;
  final Decimal? proteinTarget;
  final Decimal? carbsTarget;
  final Decimal? fatTarget;

  /// Subtotals keyed by meal, in canonical `Meal.values` order. Use the
  /// map for direct lookups; iterate `Meal.values` to render in order.
  final Map<Meal, MealSubtotal> byMeal;

  final Goal? activeGoal;

  /// "Kcal left" — `target - consumed`. Returns null when the day has no
  /// goal. Negative values are "over by N" — widgets display via T-05
  /// danger rules.
  Decimal? get kcalRemaining {
    final t = kcalTarget;
    if (t == null) return null;
    return t - kcal;
  }

  /// True when [kcal] strictly exceeds [kcalTarget]. Aligns with the PM
  /// Risk 1 ruling — `value > target` flips the over-budget UI.
  bool get isOverKcal {
    final t = kcalTarget;
    if (t == null) return false;
    return kcal > t;
  }

  DaySummary copyWith({
    DateTime? date,
    Decimal? kcal,
    Decimal? protein,
    Decimal? carbs,
    Decimal? fat,
    Decimal? kcalTarget,
    Decimal? proteinTarget,
    Decimal? carbsTarget,
    Decimal? fatTarget,
    Map<Meal, MealSubtotal>? byMeal,
    Goal? activeGoal,
  }) =>
      DaySummary(
        date: date ?? this.date,
        kcal: kcal ?? this.kcal,
        protein: protein ?? this.protein,
        carbs: carbs ?? this.carbs,
        fat: fat ?? this.fat,
        kcalTarget: kcalTarget ?? this.kcalTarget,
        proteinTarget: proteinTarget ?? this.proteinTarget,
        carbsTarget: carbsTarget ?? this.carbsTarget,
        fatTarget: fatTarget ?? this.fatTarget,
        byMeal: byMeal ?? this.byMeal,
        activeGoal: activeGoal ?? this.activeGoal,
      );

  factory DaySummary.fromJson(Map<String, dynamic> json) {
    final total = json['total'] as Map<String, dynamic>;
    Decimal dec(String key) =>
        Decimal.parse((total[key] as Object).toString());
    Decimal? decN(String key) {
      final v = total[key];
      return v == null ? null : Decimal.parse(v.toString());
    }

    final goalJson = json['active_goal'] as Map<String, dynamic>?;
    final goal = goalJson == null ? null : Goal.fromJson(goalJson);

    final by = <Meal, MealSubtotal>{};
    for (final raw in (json['by_meal'] as List<dynamic>)) {
      final sub = MealSubtotal.fromJson(raw as Map<String, dynamic>);
      by[sub.meal] = sub;
    }
    for (final m in Meal.values) {
      by.putIfAbsent(m, () => MealSubtotal.empty(m));
    }

    return DaySummary(
      date: DateTime.parse(json['date'] as String),
      kcal: dec('calories_kcal'),
      protein: decN('protein_g') ?? Decimal.zero,
      carbs: decN('carbs_g') ?? Decimal.zero,
      fat: decN('fat_g') ?? Decimal.zero,
      kcalTarget: goal?.dailyCalorieTarget == null
          ? null
          : Decimal.fromInt(goal!.dailyCalorieTarget!),
      proteinTarget: goal?.proteinTargetG,
      carbsTarget: goal?.carbsTargetG,
      fatTarget: goal?.fatTargetG,
      byMeal: by,
      activeGoal: goal,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'date':
            '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
        'total': <String, dynamic>{
          'calories_kcal': kcal.toString(),
          'protein_g': protein.toString(),
          'carbs_g': carbs.toString(),
          'fat_g': fat.toString(),
        },
        'by_meal':
            Meal.values.map((m) => (byMeal[m] ?? MealSubtotal.empty(m)).toJson()).toList(),
        if (activeGoal != null) 'active_goal': activeGoal!.toJson(),
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DaySummary &&
          other.date == date &&
          other.kcal == kcal &&
          other.protein == protein &&
          other.carbs == carbs &&
          other.fat == fat &&
          other.kcalTarget == kcalTarget &&
          other.proteinTarget == proteinTarget &&
          other.carbsTarget == carbsTarget &&
          other.fatTarget == fatTarget &&
          _mapEq(other.byMeal, byMeal) &&
          other.activeGoal == activeGoal;

  @override
  int get hashCode => Object.hash(
        date,
        kcal,
        protein,
        carbs,
        fat,
        kcalTarget,
        proteinTarget,
        carbsTarget,
        fatTarget,
        Object.hashAll(byMeal.entries.map((e) => Object.hash(e.key, e.value))),
        activeGoal,
      );
}

bool _mapEq<K, V>(Map<K, V> a, Map<K, V> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    if (b[e.key] != e.value) return false;
  }
  return true;
}
