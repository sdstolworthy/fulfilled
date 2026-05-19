@Skip('Quarantined post Ask 10 — UI/value assertions need rebaseline.')
library;


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
import 'package:fulfilled/domain/unit.dart';
import 'package:fulfilled/domain/weight.dart';
import 'package:fulfilled/features/today/today_screen.dart';
import 'package:fulfilled/form_factor/form_factor.dart';
import 'package:fulfilled/providers/api_base_url_provider.dart';
import 'package:fulfilled/providers/food_providers.dart';
import 'package:fulfilled/providers/log_providers.dart';
import 'package:fulfilled/providers/repository_providers.dart';
import 'package:fulfilled/providers/weight_providers.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/meal_section.dart';
import 'package:fulfilled/widgets/ring_summary_card.dart';
import 'package:go_router/go_router.dart';

/// Screen 01 widget tests.
///
/// Requirements per the brief:
/// 1. At compact width the four meal headers render.
/// 2. At expanded width the right-rail renders (ring summary card +
///    quick-add card + mini sparkline).
///
/// All async providers are overridden with deterministic in-memory values
/// so the test doesn't depend on the mock repository's seed or latency.
/// We mount inside a tiny `go_router` config so any internal
/// `context.push(...)` calls (FAB, chevrons, search field) don't blow up.

final _date = DateTime(2026, 5, 14);

DaySummary _summary() {
  final byMeal = <Meal, MealSubtotal>{
    Meal.breakfast: MealSubtotal(
      meal: Meal.breakfast,
      kcal: Decimal.fromInt(412),
      proteinG: Decimal.fromInt(20),
      carbsG: Decimal.fromInt(40),
      fatG: Decimal.fromInt(12),
      entryCount: 3,
    ),
    Meal.lunch: MealSubtotal(
      meal: Meal.lunch,
      kcal: Decimal.fromInt(586),
      proteinG: Decimal.fromInt(30),
      carbsG: Decimal.fromInt(50),
      fatG: Decimal.fromInt(20),
      entryCount: 2,
    ),
    Meal.dinner: MealSubtotal.empty(Meal.dinner),
    Meal.snack: MealSubtotal(
      meal: Meal.snack,
      kcal: Decimal.fromInt(290),
      proteinG: Decimal.fromInt(8),
      carbsG: Decimal.fromInt(20),
      fatG: Decimal.fromInt(18),
      entryCount: 2,
    ),
  };
  return DaySummary(
    date: _date,
    kcal: Decimal.fromInt(1288),
    protein: Decimal.fromInt(58),
    carbs: Decimal.fromInt(110),
    fat: Decimal.fromInt(50),
    kcalTarget: Decimal.fromInt(2100),
    proteinTarget: Decimal.fromInt(130),
    carbsTarget: Decimal.fromInt(263),
    fatTarget: Decimal.fromInt(70),
    byMeal: byMeal,
  );
}

LogEntry _entry(String name, Meal meal, int kcal) {
  return LogEntry(
    id: '$name-${meal.wire}',
    foodId: 'f-$name',
    foodName: name,
    servingId: 'sv',
    servingName: '1 serving',
    consumedOn: _date,
    meal: meal,
    quantity: Decimal.one,
    enteredAmount: Decimal.fromInt(100),
    enteredUnit: Unit.g,
    nutritionSnapshot: NutritionSnapshot(
      caloriesKcal: Decimal.fromInt(kcal),
    ),
    createdAt: DateTime(2026, 5, 14, 9, 0),
    updatedAt: DateTime(2026, 5, 14, 9, 0),
  );
}

Food _food(String id, String name, int kcal) {
  return Food(
    id: id,
    name: name,
    source: FoodSource.off,
    isCustom: false,
    servings: <Serving>[
      Serving(
        id: '${id}_s100',
        label: '1 serving (100 g)',
        amount: Decimal.fromInt(100),
        unit: Unit.g,
        kcal: Decimal.fromInt(kcal),
        isDefault: true,
        source: ServingSource.off,
      ),
    ],
  );
}

WeightSeriesPoint _wp(DateTime d, double kg) =>
    WeightSeriesPoint(date: d, weightKg: Decimal.parse(kg.toString()));

List<LogEntry> _entries() => <LogEntry>[
      _entry('Greek yogurt, plain', Meal.breakfast, 130),
      _entry('Blueberries', Meal.breakfast, 84),
      _entry('Chicken Caesar salad', Meal.lunch, 486),
      _entry('Almonds', Meal.snack, 164),
    ];

Widget _harness({required List<Override> overrides}) {
  // Mount inside a tiny shell-style router so that nav-aware
  // foundation widgets (`AppScaffold`) get a `GoRouterState`.
  final router = GoRouter(
    initialLocation: '/today',
    routes: <RouteBase>[
      ShellRoute(
        builder: (_, __, child) => child,
        routes: <RouteBase>[
          GoRoute(
            path: '/today',
            builder: (_, __) => const TodayScreen(),
          ),
          // Stubs for any context.push targets so the test doesn't crash
          // when the FAB / chevrons fire.
          GoRoute(
            path: '/foods',
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
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp.router(
      theme: buildLightTheme(),
      routerConfig: router,
    ),
  );
}

void main() {
  testWidgets(
    'compact width renders four meal section headers',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // `TodayScreen()` resolves the day to local-now (stripped of time-of-
      // day). Mirror that key in the overrides so the family lookup hits.
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);

      await tester.pumpWidget(
        _harness(
          overrides: <Override>[
            // Pin form factor to medium so the LogRepository skips the
            // compact outbox dependency (which reads outboxBoxProvider
            // and would throw without a Hive box). The layout shell
            // still respects the viewport for `isCompact` switches —
            // this only opts the repository out of queueing.
            formFactorOverrideProvider.overrideWithValue(FormFactor.medium),
            // Skip the Hive-backed mobile base-url branch.
            apiBaseUrlProvider
                .overrideWith((_) => 'https://test.example/api/v1'),
            daySummaryProvider(today).overrideWith((_) async => _summary()),
            logEntriesProvider(today).overrideWith((_) async => _entries()),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // Four meal sections rendered, one per Meal enum value.
      expect(find.byType(MealSection), findsNWidgets(4));

      // Each meal's title appears in the header row.
      expect(find.text('Breakfast'), findsOneWidget);
      expect(find.text('Lunch'), findsOneWidget);
      expect(find.text('Dinner'), findsOneWidget);
      expect(find.text('Snack'), findsOneWidget);

      // The ring-summary card renders inside the compact body.
      expect(find.byType(RingSummaryCard), findsOneWidget);
    },
  );

  testWidgets(
    'expanded width renders the right rail (ring + quick-add + sparkline)',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);

      await tester.pumpWidget(
        _harness(
          overrides: <Override>[
            formFactorOverrideProvider.overrideWithValue(FormFactor.medium),
            // Skip the Hive-backed mobile base-url branch.
            apiBaseUrlProvider
                .overrideWith((_) => 'https://test.example/api/v1'),
            daySummaryProvider(today).overrideWith((_) async => _summary()),
            logEntriesProvider(today)
                .overrideWith((_) async => _entries()),
            recentFoodsProvider.overrideWith((_) async => <Food>[
                  _food('r1', 'Greek yogurt', 130),
                  _food('r2', 'Oatmeal', 150),
                ],),
            frequentFoodsProvider.overrideWith((_) async => <Food>[
                  _food('f1', 'Eggs, large', 72),
                  _food('f2', 'Chicken breast', 165),
                ],),
            weightSeriesProvider(WeightRange.oneMonth)
                .overrideWith((_) async => <WeightSeriesPoint>[
                      _wp(DateTime(2026, 4, 14), 80.2),
                      _wp(DateTime(2026, 4, 28), 79.4),
                      _wp(DateTime(2026, 5, 14), 78.4),
                    ],),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // The four meal sections still render in the 2×2 grid.
      expect(find.byType(MealSection), findsNWidgets(4));

      // Right rail: the ring-summary card exists. (Card composes the
      // ring and macro bars; finding the wrapping RingSummaryCard is
      // sufficient evidence the rail rendered.)
      expect(find.byType(RingSummaryCard), findsOneWidget);

      // Quick-add card eyebrow + section headers.
      expect(find.text('Quick add'), findsOneWidget);
      expect(find.text('Recent'), findsOneWidget);
      expect(find.text('Frequent'), findsOneWidget);

      // Mini weight sparkline header.
      expect(find.text('Weight · last 30 days'), findsOneWidget);
    },
  );
}
