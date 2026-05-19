// MOCK ONLY — deletable once the real API is wired.
//
// Audit-fix F2: this file used to be a 1300-line god module spanning
// five domains. It's now a barrel — the seed data lives in
// `_user_fixtures.dart`, `_food_fixtures.dart`, `_goal_fixtures.dart`,
// `_weight_fixtures.dart`, and `_log_fixtures.dart`. Existing callers
// can keep importing `_fixtures.dart` for the full surface, or
// migrate to a narrower import as their needs warrant.

export '_clock.dart';
export '_user_fixtures.dart';
export '_food_fixtures.dart';
export '_goal_fixtures.dart';
export '_weight_fixtures.dart';
export '_log_fixtures.dart';
