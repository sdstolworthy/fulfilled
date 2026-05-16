/// Meal slots, mirroring `Meal` in `specs/openapi.yaml` (`breakfast |
/// lunch | dinner | snack`). Canonical sort order is the enum declaration
/// order; that's what the day-view's 4-section list, the macro picker
/// (screen 04), and `DaySummary.by_meal` all use.
///
/// Wire-side serialization is the lowercase enum name. `Meal.fromWire` is
/// strict (unknown strings throw) — the API contract is closed.
enum Meal {
  breakfast,
  lunch,
  dinner,
  snack;

  /// Canonical wire string ("breakfast", "lunch", "dinner", "snack").
  String get wire => name;

  /// Title-cased label for UI ("Breakfast", "Lunch", "Dinner", "Snack").
  ///
  /// Widgets that need a localized label should resolve it via i18n; this
  /// helper exists so seed data and tests don't reinvent the string.
  String get label {
    switch (this) {
      case Meal.breakfast:
        return 'Breakfast';
      case Meal.lunch:
        return 'Lunch';
      case Meal.dinner:
        return 'Dinner';
      case Meal.snack:
        return 'Snack';
    }
  }

  static Meal fromWire(String wire) {
    for (final m in Meal.values) {
      if (m.name == wire) return m;
    }
    throw ArgumentError.value(wire, 'wire', 'Unknown Meal');
  }
}

/// Resolve the default meal for "log right now" affordances (the FAB, the
/// right-rail Quick add card, the log-entry sheet's default meal).
///
/// Boundaries are the architect's call — no spec exists. Snack is the
/// safe default outside meal windows; the breakfast/lunch/dinner windows
/// match common eating patterns and what the mock implies on the right
/// rail copy.
///
/// - Breakfast: 04:00 ≤ hour < 11:00
/// - Lunch:     11:00 ≤ hour < 15:00
/// - Dinner:    17:00 ≤ hour < 21:00
/// - Snack:     everything else (early morning, mid-afternoon, late night)
Meal mealForLocalTime(DateTime now) {
  final h = now.hour;
  if (h >= 4 && h < 11) return Meal.breakfast;
  if (h >= 11 && h < 15) return Meal.lunch;
  if (h >= 17 && h < 21) return Meal.dinner;
  return Meal.snack;
}
