/// Synthetic food + serving ids used by the Quick add affordance.
///
/// The Today header's "Quick add calories" entry — and the matching
/// meal-section row — log against a single per-user synthetic food
/// (`food_quick_add`) whose only serving (`sv_kcal`) is shaped so a
/// user-typed kcal value rides on the log entry's `quantity` field 1:1.
///
/// These ids are **stable across mock + live**: the seed in
/// `repositories/_fixtures.dart` declares them, the live server reuses
/// the same id strings, and widgets that need to branch on "is this
/// entry a quick-add row?" compare against the constants here.
///
/// Audit finding #8: previously the string `'food_quick_add'` was
/// declared in five places (the seed, the quick-add sheet, the
/// today_internals helper, the meal-section row, and several test
/// files) and the canonical declaration lived inside a file marked
/// "deletable once the real API ships". Promoting the constants to a
/// domain home means deleting the mock seed file does not orphan the
/// widget-layer copies.
library;

/// Stable id of the synthetic Quick-add food.
const String quickAddFoodId = 'food_quick_add';

/// Stable id of the synthetic `serving` row on the Quick-add food.
/// `{amount: 1, unit: serving, kcal: 1}` — so a user-typed kcal value
/// rides on the log entry's `quantity` field 1:1.
const String quickAddServingId = 'sv_kcal';
