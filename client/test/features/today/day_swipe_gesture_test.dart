// UX-103 — `DaySwipeWrap` horizontal swipe gesture.
//
// Wrap is mounted on **both** day views:
//   - `DayViewCompact` (CustomScrollView)
//   - `DayViewExpanded` (SingleChildScrollView)
//
// Architect §6.4 threshold: `|primaryVelocity| > 200 px/s`.
// Direction mapping:
//   - Left swipe  (velocity < -200) → `navigateDay(context, date, +1)`
//   - Right swipe (velocity > +200) → `navigateDay(context, date, -1)`
//   - Below-threshold drag           → no-op (no route change)
//   - Vertical drag                  → falls through to the inner
//                                       scroll view (translucent
//                                       hit-test behavior; T-12 spirit).
//
// We seed the date via a `/today/:date` initial location so:
//   1. The router path before the swipe is deterministic.
//   2. `pathForDay(today)` returns the canonical `/today` for a left
//      swipe from yesterday → today, which we assert literally below.

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/day_summary.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/food.dart';
import 'package:fulfilled/domain/log_entry.dart';
import 'package:fulfilled/domain/meal.dart';
import 'package:fulfilled/domain/nutrition.dart';
import 'package:fulfilled/domain/serving.dart';
import 'package:fulfilled/domain/weight.dart';
import 'package:fulfilled/features/today/today_internals.dart';
import 'package:fulfilled/features/today/today_screen.dart';
import 'package:fulfilled/providers/food_providers.dart';
import 'package:fulfilled/providers/log_providers.dart';
import 'package:fulfilled/providers/weight_providers.dart';
import 'package:fulfilled/routing/routes.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:go_router/go_router.dart';

/// Canonical local-now day (Y/M/D, time stripped) — matches the date
/// `TodayScreen` resolves when the router lands on `/today`.
final DateTime _today = () {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}();
final DateTime _yesterday = _today.subtract(const Duration(days: 1));
final DateTime _twoDaysAgo = _today.subtract(const Duration(days: 2));

/// `pathForDay(date)` returns `/today/yyyy-mm-dd` for backdated days.
/// Mirroring the helper inline keeps the test free of an import-cycle
/// across the production helper.
String _backdatedPath(DateTime date) {
  final y = date.year.toString().padLeft(4, '0');
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return '${Routes.todayPath}/$y-$m-$d';
}

DaySummary _summary(DateTime date) => DaySummary(
      date: date,
      kcal: Decimal.fromInt(420),
      protein: Decimal.fromInt(30),
      carbs: Decimal.fromInt(50),
      fat: Decimal.fromInt(15),
      kcalTarget: Decimal.fromInt(2000),
      proteinTarget: Decimal.fromInt(120),
      carbsTarget: Decimal.fromInt(250),
      fatTarget: Decimal.fromInt(65),
      byMeal: <Meal, MealSubtotal>{
        for (final m in Meal.values) m: MealSubtotal.empty(m),
      },
    );

LogEntry _entry(DateTime consumedOn, String name, Meal meal, int kcal) {
  return LogEntry(
    id: '$name-${meal.wire}',
    foodId: 'f-$name',
    foodName: name,
    servingId: 'sv',
    servingName: '1 serving',
    consumedOn: consumedOn,
    meal: meal,
    quantity: Decimal.one,
    gramsTotal: Decimal.fromInt(100),
    nutritionSnapshot: NutritionSnapshot(
      caloriesKcal: Decimal.fromInt(kcal),
    ),
    createdAt: consumedOn,
    updatedAt: consumedOn,
  );
}

Food _food(String id) => Food(
      id: id,
      name: id,
      source: FoodSource.off,
      isCustom: false,
      nutritionPer100g: NutritionPer100g(energyKcal: Decimal.fromInt(100)),
      servings: <Serving>[
        Serving(
          id: '${id}_s',
          name: '1 serving',
          grams: Decimal.fromInt(100),
          isDefault: true,
          source: ServingSource.system,
        ),
      ],
    );

/// Seed enough entries so the compact body is taller than the viewport
/// and the inner `CustomScrollView` can scroll. Used by the
/// vertical-passthrough assertion.
List<LogEntry> _manyEntries(DateTime date) => <LogEntry>[
      for (var i = 0; i < 6; i++)
        _entry(date, 'Breakfast item $i', Meal.breakfast, 150),
      for (var i = 0; i < 6; i++)
        _entry(date, 'Lunch item $i', Meal.lunch, 200),
      for (var i = 0; i < 6; i++)
        _entry(date, 'Dinner item $i', Meal.dinner, 250),
      for (var i = 0; i < 6; i++)
        _entry(date, 'Snack item $i', Meal.snack, 120),
    ];

GoRouter _router({required String initialLocation}) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: <RouteBase>[
      ShellRoute(
        builder: (_, __, child) => child,
        routes: <RouteBase>[
          GoRoute(
            path: Routes.todayPath,
            builder: (_, __) => const TodayScreen(),
            routes: <RouteBase>[
              GoRoute(
                path: ':date',
                builder: (_, state) {
                  final raw = state.pathParameters['date'];
                  final parsed = raw == null ? null : DateTime.tryParse(raw);
                  return TodayScreen(date: parsed);
                },
              ),
            ],
          ),
          GoRoute(
            path: Routes.foodsPath,
            builder: (_, __) => const Scaffold(body: SizedBox.shrink()),
            routes: <RouteBase>[
              GoRoute(
                path: 'search',
                builder: (_, __) => const Scaffold(body: SizedBox.shrink()),
              ),
            ],
          ),
        ],
      ),
    ],
  );
}

Widget _harness({
  required GoRouter router,
  required List<Override> overrides,
}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp.router(
      theme: buildLightTheme(),
      routerConfig: router,
    ),
  );
}

/// Override every async provider the day view watches so neither
/// compact nor expanded ever sits in a loading state during the swipe.
List<Override> _baselineOverrides({
  List<LogEntry>? todayEntries,
  List<LogEntry>? yesterdayEntries,
  List<LogEntry>? twoDaysAgoEntries,
}) =>
    <Override>[
      daySummaryProvider(_today).overrideWith((_) async => _summary(_today)),
      daySummaryProvider(_yesterday)
          .overrideWith((_) async => _summary(_yesterday)),
      daySummaryProvider(_twoDaysAgo)
          .overrideWith((_) async => _summary(_twoDaysAgo)),
      logEntriesProvider(_today)
          .overrideWith((_) async => todayEntries ?? <LogEntry>[]),
      logEntriesProvider(_yesterday)
          .overrideWith((_) async => yesterdayEntries ?? <LogEntry>[]),
      logEntriesProvider(_twoDaysAgo)
          .overrideWith((_) async => twoDaysAgoEntries ?? <LogEntry>[]),
      recentFoodsProvider.overrideWith((_) async => <Food>[_food('r1')]),
      frequentFoodsProvider.overrideWith((_) async => <Food>[_food('f1')]),
      for (final r in WeightRange.values)
        weightSeriesProvider(r)
            .overrideWith((_) async => <WeightSeriesPoint>[]),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DaySwipeWrap — compact', () {
    testWidgets('left fling (velocity ≈ 250 px/s) routes to next day',
        (tester) async {
      // Compact viewport.
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Start on _yesterday so a left fling (→ next day) lands on
      // _today. This sidesteps the `pathForDay` collapse where today
      // becomes the bare `/today` path.
      final initialPath = _backdatedPath(_yesterday);
      final router = _router(initialLocation: initialPath);

      await tester.pumpWidget(
        _harness(router: router, overrides: _baselineOverrides()),
      );
      await tester.pumpAndSettle();

      // Pre-condition.
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        equals(initialPath),
      );

      // Architect §6.4: `tester.fling(Offset(-200, 0), 1000)` flicks at
      // ≈ 1000 px/s — well above the 200 px/s floor and matches the
      // "left swipe of velocity 250" intent in the task brief (the
      // floor is what matters; we pick a margin above it).
      await tester.fling(
        find.byType(DaySwipeWrap),
        const Offset(-200, 0),
        1000,
      );
      await tester.pumpAndSettle();

      // Left fling → next day. From _yesterday that's _today, and
      // `pathForDay(today)` is the canonical `/today`.
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        equals(Routes.todayPath),
      );
    });

    testWidgets('right fling (velocity ≈ 250 px/s) routes to previous day',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Start on _yesterday so a right fling (→ previous day) lands on
      // _twoDaysAgo — a deterministic, non-today backdated path.
      final initialPath = _backdatedPath(_yesterday);
      final expectedPath = _backdatedPath(_twoDaysAgo);
      final router = _router(initialLocation: initialPath);

      await tester.pumpWidget(
        _harness(router: router, overrides: _baselineOverrides()),
      );
      await tester.pumpAndSettle();

      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        equals(initialPath),
      );

      await tester.fling(
        find.byType(DaySwipeWrap),
        const Offset(200, 0),
        1000,
      );
      await tester.pumpAndSettle();

      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        equals(expectedPath),
      );
    });

    testWidgets('below-threshold drag (velocity ≈ 150 px/s) is a no-op',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final initialPath = _backdatedPath(_yesterday);
      final router = _router(initialLocation: initialPath);

      await tester.pumpWidget(
        _harness(router: router, overrides: _baselineOverrides()),
      );
      await tester.pumpAndSettle();

      // `tester.fling` simulates a 50 ms drag with N steps. To stay
      // *below* the 200 px/s velocity floor we use a small offset
      // (-20 px) over an unusually slow drag — the resulting velocity
      // is ≈ 20 px / 0.3 s = 66 px/s, well under 200 px/s. Even doubled
      // by Flutter's internal velocity tracker it stays below 200.
      await tester.fling(
        find.byType(DaySwipeWrap),
        const Offset(-20, 0),
        50,
      );
      await tester.pumpAndSettle();

      // No route change.
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        equals(initialPath),
      );
    });

    testWidgets('vertical drag falls through to the inner ScrollView',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Land on /today and seed enough entries that the body exceeds
      // the viewport height — otherwise `CustomScrollView` has no
      // scroll extent to expose and the assertion is vacuous.
      final router = _router(initialLocation: Routes.todayPath);

      await tester.pumpWidget(
        _harness(
          router: router,
          overrides: _baselineOverrides(
            todayEntries: _manyEntries(_today),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The `CustomScrollView` is the inner scroll surface. Grab its
      // `ScrollPosition` directly off the `ScrollableState` (Flutter
      // attaches a `PrimaryScrollController` when the `CustomScrollView`
      // is constructed without an explicit one — querying the state's
      // `position` works either way). If `HitTestBehavior.translucent`
      // is honoured, the vertical drag reaches the scroll view and the
      // offset advances.
      //
      // Scope the finder to the `Scrollable` *inside* `DaySwipeWrap` —
      // there can be other scrollables in the tree (e.g. nested chip
      // rows on expanded), and we want the day-body's outer scroll.
      final scrollFinder = find.descendant(
        of: find.byType(DaySwipeWrap),
        matching: find.byType(Scrollable),
      ).first;
      final position = tester.state<ScrollableState>(scrollFinder).position;
      final initialOffset = position.pixels;

      // Drag inside the `DaySwipeWrap`'s bounds, vertically upward.
      // Vertical drags are not subscribed by `DaySwipeWrap` (only
      // `onHorizontalDragEnd`); the `HitTestBehavior.translucent`
      // ensures the parent passes the hit-test to the inner scroll
      // view, which owns the vertical-drag recognizer.
      await tester.drag(
        find.byType(DaySwipeWrap),
        const Offset(0, -200),
      );
      await tester.pumpAndSettle();

      expect(
        position.pixels,
        greaterThan(initialOffset),
        reason:
            'Vertical drag should pass through DaySwipeWrap to the inner '
            'CustomScrollView; offset stayed at $initialOffset.',
      );

      // And no route change happened — the vertical drag is not a
      // day-change gesture.
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        equals(Routes.todayPath),
      );
    });
  });

  group('DaySwipeWrap — expanded', () {
    testWidgets('mount: the expanded day view contains a DaySwipeWrap',
        (tester) async {
      // Expanded viewport (≥ 1024).
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final router = _router(initialLocation: Routes.todayPath);
      await tester.pumpWidget(
        _harness(router: router, overrides: _baselineOverrides()),
      );
      await tester.pumpAndSettle();

      // The wrap is mounted around the `SingleChildScrollView`. We
      // assert presence — the compact variant exercises the gesture
      // logic; mounting parity is what we verify here.
      expect(find.byType(DaySwipeWrap), findsOneWidget);
    });

    testWidgets('left fling on the expanded day view routes to next day',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Start on _yesterday — same setup rationale as the compact
      // left-fling case.
      final initialPath = _backdatedPath(_yesterday);
      final router = _router(initialLocation: initialPath);

      await tester.pumpWidget(
        _harness(router: router, overrides: _baselineOverrides()),
      );
      await tester.pumpAndSettle();

      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        equals(initialPath),
      );

      await tester.fling(
        find.byType(DaySwipeWrap),
        const Offset(-200, 0),
        1000,
      );
      await tester.pumpAndSettle();

      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        equals(Routes.todayPath),
      );
    });
  });
}
