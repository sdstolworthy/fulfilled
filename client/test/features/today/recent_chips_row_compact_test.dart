// UX-107 F2 — `_TodayRecentChipsRow` mount on the Today compact day view.
//
// Acceptance:
// 1. **Rendered on today with ≥ 4 recents** — pumping `TodayScreen` on
//    a compact viewport with `recentFoodsProvider` overridden to 5
//    foods renders the chip strip (the `QuickAddChips` instance keyed
//    `today-recent-chips-row`).
// 2. **Hidden on a backdated day** — the same provider seed on a
//    backdate (e.g. `/today/:yesterday`) hides the strip.
// 3. **Hidden when recents are below the floor (< 4)** — two recents on
//    today still hides the strip; no skeleton, no placeholder.
// 4. **Strip mounts between the ring summary card and the empty-day
//    pill** — the sliver order matters; if the strip ever drifts above
//    the ring or below the meal list, the daily ritual loses the
//    "ring → recents → meals" reading order PM doc §2 F2 specified.
// 5. **Tap routes through `showLogEntrySheet` in create mode with the
//    time-of-day meal seeded** — tapping a chip opens the sheet with
//    `existing: null` and `defaultMeal == mealForLocalTime(now)`.
//
// Mirrors the harness shape used by `today_pill_test.dart` and
// `empty_day_pill_test.dart` — a minimal `GoRouter` that mounts
// `TodayScreen` on `/today` and a `/today/:date` child, a baseline
// Provider override list, and a per-test phone-sized viewport.

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
import 'package:fulfilled/features/log_entry/log_entry_sheet.dart';
import 'package:fulfilled/features/log_entry/widgets/meal_chip_picker.dart';
import 'package:fulfilled/features/today/today_screen.dart';
import 'package:fulfilled/providers/food_providers.dart';
import 'package:fulfilled/providers/log_providers.dart';
import 'package:fulfilled/providers/weight_providers.dart';
import 'package:fulfilled/routing/routes.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/quick_add_chips.dart';
import 'package:fulfilled/widgets/ring_summary_card.dart';
import 'package:go_router/go_router.dart';

final DateTime _today = () {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}();

final DateTime _yesterday = _today.subtract(const Duration(days: 1));

DaySummary _emptySummary(DateTime date) => DaySummary(
      date: date,
      kcal: Decimal.zero,
      protein: Decimal.zero,
      carbs: Decimal.zero,
      fat: Decimal.zero,
      kcalTarget: Decimal.fromInt(2000),
      proteinTarget: Decimal.fromInt(120),
      carbsTarget: Decimal.fromInt(250),
      fatTarget: Decimal.fromInt(65),
      byMeal: <Meal, MealSubtotal>{
        for (final m in Meal.values) m: MealSubtotal.empty(m),
      },
    );

Food _food(String id, {String? name}) => Food(
      id: id,
      name: name ?? id,
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

List<Food> _foods(int n) => List<Food>.generate(
      n,
      (i) => _food('r$i', name: 'Recent $i'),
    );

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

List<Override> _baselineOverrides({
  required List<Food> recents,
}) =>
    <Override>[
      daySummaryProvider(_today)
          .overrideWith((_) async => _emptySummary(_today)),
      daySummaryProvider(_yesterday)
          .overrideWith((_) async => _emptySummary(_yesterday)),
      logEntriesProvider(_today).overrideWith((_) async => <LogEntry>[]),
      logEntriesProvider(_yesterday).overrideWith((_) async => <LogEntry>[]),
      recentFoodsProvider.overrideWith((_) async => recents),
      frequentFoodsProvider.overrideWith((_) async => <Food>[_food('f1')]),
      for (final r in WeightRange.values)
        weightSeriesProvider(r)
            .overrideWith((_) async => <WeightSeriesPoint>[]),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'renders on today with ≥ 4 recents',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final router = _router(initialLocation: Routes.todayPath);
      await tester.pumpWidget(
        _harness(
          router: router,
          overrides: _baselineOverrides(recents: _foods(5)),
        ),
      );
      await tester.pumpAndSettle();

      // The wrapper widget mounts `QuickAddChips` with this stable key.
      expect(find.byKey(const Key('today-recent-chips-row')), findsOneWidget);
      // The strip renders the recent food names.
      expect(find.text('Recent 0'), findsOneWidget);
      expect(find.text('Recent 4'), findsOneWidget);
    },
  );

  testWidgets(
    'hidden on a backdated day (date != local-now)',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Build a backdated path manually — mirrors `pathForDay`.
      final y = _yesterday.year.toString().padLeft(4, '0');
      final m = _yesterday.month.toString().padLeft(2, '0');
      final d = _yesterday.day.toString().padLeft(2, '0');
      final path = '${Routes.todayPath}/$y-$m-$d';

      final router = _router(initialLocation: path);
      await tester.pumpWidget(
        _harness(
          router: router,
          overrides: _baselineOverrides(recents: _foods(5)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('today-recent-chips-row')), findsNothing);
    },
  );

  testWidgets(
    'hidden when recents are below the floor (< 4)',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final router = _router(initialLocation: Routes.todayPath);
      await tester.pumpWidget(
        _harness(
          router: router,
          // Two recents — below the 4 floor.
          overrides: _baselineOverrides(recents: _foods(2)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('today-recent-chips-row')), findsNothing);
      // And no chip-name text leaked into the tree.
      expect(find.text('Recent 0'), findsNothing);
    },
  );

  testWidgets(
    'strip mounts between the ring summary card and the empty-day pill',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final router = _router(initialLocation: Routes.todayPath);
      await tester.pumpWidget(
        _harness(
          router: router,
          overrides: _baselineOverrides(recents: _foods(5)),
        ),
      );
      await tester.pumpAndSettle();

      final ringTopY = tester.getTopLeft(find.byType(RingSummaryCard)).dy;
      final stripTopY =
          tester.getTopLeft(find.byKey(const Key('today-recent-chips-row'))).dy;
      final pillTopY = tester.getTopLeft(find.byKey(const Key('empty-day-pill'))).dy;

      // Ring above strip; strip above empty-day pill. The empty-day
      // pill itself sits directly above the meal grid, so this also
      // pins "strip above the meals".
      expect(ringTopY < stripTopY, isTrue,
          reason: 'ring summary card should be above the recent-chips strip');
      expect(stripTopY < pillTopY, isTrue,
          reason: 'recent-chips strip should be above the empty-day pill');
    },
  );

  testWidgets(
    'tap routes through LogEntrySheet create mode with the time-of-day meal seeded',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final router = _router(initialLocation: Routes.todayPath);
      await tester.pumpWidget(
        _harness(
          router: router,
          overrides: _baselineOverrides(recents: _foods(5)),
        ),
      );
      await tester.pumpAndSettle();

      // Pre-condition: the sheet is closed.
      expect(find.byType(LogEntrySheetBody), findsNothing);

      // Tap the first chip — capture the expected meal at this instant
      // so the assertion stays stable across the modal's bounded enter
      // animation (the sheet's `initState` reads `DateTime.now()` for
      // the fallback, but the chip handler passes the explicit default
      // computed at tap time).
      final expectedMeal = mealForLocalTime(DateTime.now());
      await tester.tap(find.text('Recent 0'));
      await tester.pumpAndSettle();

      // The sheet opened in create mode (existing == null).
      final body = tester.widget<LogEntrySheetBody>(find.byType(LogEntrySheetBody));
      expect(body.existing, isNull,
          reason: 'chip tap should open create mode, not edit mode');
      expect(body.defaultMeal, expectedMeal,
          reason: 'chip tap should seed defaultMeal == mealForLocalTime(now)');

      // And the meal chip picker reflects the seeded meal.
      final picker = tester.widget<MealChipPicker>(find.byType(MealChipPicker));
      expect(picker.value, expectedMeal);
    },
  );

  testWidgets(
    'right-rail (expanded) caller still renders the card branch — regression',
    (tester) async {
      // Expanded viewport: the day view mounts the right-rail
      // `QuickAddChips` in its default `compact: false` mode. The
      // signature surface — eyebrow "Quick add" + section headers — must
      // still be present. UX-107 added the compact flag; if the default
      // ever flips to true, this guard fires.
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final router = _router(initialLocation: Routes.todayPath);
      await tester.pumpWidget(
        _harness(
          router: router,
          overrides: _baselineOverrides(recents: _foods(5)),
        ),
      );
      await tester.pumpAndSettle();

      // Right-rail card chrome: "Quick add" eyebrow + "Recent" section.
      expect(find.text('Quick add'), findsOneWidget);
      expect(find.text('Recent'), findsOneWidget);
      // And the compact strip's wrapper key is *not* present on
      // expanded — it lives in `DayViewCompact` only.
      expect(find.byKey(const Key('today-recent-chips-row')), findsNothing);
      // The right-rail caller of QuickAddChips is the default mode —
      // and that's the only QuickAddChips on screen.
      final widgets = tester.widgetList<QuickAddChips>(find.byType(QuickAddChips));
      expect(widgets.length, 1);
      expect(widgets.first.compact, isFalse);
    },
  );
}
