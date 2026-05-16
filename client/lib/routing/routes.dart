/// Route name + path constants. Source of truth for `app_router.dart` and
/// for any `context.go(...)` / `context.goNamed(...)` call elsewhere.
///
/// Match architecture §4 verbatim, **minus the Trends route** (PM Risk 3 —
/// hidden entirely from both nav surfaces in v1). Adding Trends in v2 means
/// re-introducing the constant here and updating `app_router.dart` + the
/// nav widgets; nothing else.
///
/// Paths are lowercase, hyphenated, meaningful. Names are dotted so
/// `goNamed('foods.detail', pathParameters: {'foodId': id})` reads top-down.
class Routes {
  const Routes._();

  // Shell tabs (compact bottom bar / expanded sidebar).
  static const String todayName = 'today';
  static const String todayPath = '/today';

  static const String todayDateName = 'today.date';
  static const String todayDatePath = '/today/:date';

  static const String foodsName = 'foods';
  static const String foodsPath = '/foods';

  static const String foodsSearchName = 'foods.search';
  static const String foodsSearchPath = '/foods/search';

  static const String weightName = 'weight';
  static const String weightPath = '/weight';

  static const String meName = 'me';
  static const String mePath = '/me';

  // Sidebar-only on expanded; reachable from Me on compact.
  static const String goalsName = 'goals';
  static const String goalsPath = '/goals';

  static const String goalsNewName = 'goals.new';
  static const String goalsNewPath = '/goals/new';

  static const String myFoodsName = 'foods.mine';
  static const String myFoodsPath = '/foods/mine';

  // Outside the shell (no nav chrome).
  static const String foodDetailName = 'foods.detail';
  static const String foodDetailPath = '/foods/:foodId';

  static const String foodNewName = 'foods.new';
  static const String foodNewPath = '/foods/new';

  /// Edit screen for a `source == user` food. The resolver looks the
  /// food up via `foodDetailProvider`; for non-user foods (OFF / USDA)
  /// it renders a "Only your custom foods can be edited" affordance.
  /// Lives outside the shell — full-page form, no nav chrome.
  static const String foodEditName = 'foods.edit';
  static const String foodEditPath = '/foods/:foodId/edit';

  static const String foodBarcodeName = 'foods.barcode';
  static const String foodBarcodePath = '/foods/barcode/:barcode';

  static const String onboardingName = 'onboarding';
  static const String onboardingPath = '/onboarding/:step';
}
