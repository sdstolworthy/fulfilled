// QL-108 — Empty-day pill (compact + expanded day views).
//
// Acceptance:
// 1. The pill **renders** when `logEntriesProvider(date)` resolves to
//    an empty list (any day — local-now or backdate).
// 2. The pill is **hidden** when the day has at least one entry — the
//    pill is for "nothing logged here" only.
// 3. Tapping the pill's `PrimaryButton` pushes the search route — that
//    is the "Log a food" affordance.
//
// Mirrors `today_pill_test.dart`'s harness shape: a minimal go_router
// that mounts `TodayScreen`, a baseline Provider overrides list, and a
// per-test phone or desktop viewport. The pill key (`empty-day-pill`)
// is set on the `EmptyState` widget the day view mounts.

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
import 'package:fulfilled/providers/food_providers.dart';
import 'package:fulfilled/providers/log_providers.dart';
import 'package:fulfilled/providers/weight_providers.dart';
import 'package:fulfilled/routing/routes.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:go_router/go_router.dart';

final DateTime _today = () {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}();

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

DaySummary _populatedSummary(DateTime date) => DaySummary(
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
        for (final m in Meal.values)
          m: m == Meal.lunch
              ? MealSubtotal(
                  meal: m,
                  kcal: Decimal.fromInt(420),
                  proteinG: Decimal.fromInt(30),
                  carbsG: Decimal.fromInt(50),
                  fatG: Decimal.fromInt(15),
                  entryCount: 1,
                )
              : MealSubtotal.empty(m),
      },
    );

LogEntry _entry() => LogEntry(
      id: 'le1',
      foodId: 'f1',
      foodName: 'Greek yogurt',
      servingId: 'sv1',
      servingName: '1 cup',
      consumedOn: _today,
      meal: Meal.lunch,
      quantity: Decimal.one,
      enteredAmount: Decimal.fromInt(170),
      enteredUnit: Unit.g,
      nutritionSnapshot: NutritionSnapshot(
        caloriesKcal: Decimal.fromInt(420),
      ),
      note: null,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

Food _food(String id) => Food(
      id: id,
      name: id,
      source: FoodSource.off,
      isCustom: false,
      servings: <Serving>[
        Serving(
          id: '${id}_s',
          label: '1 serving',
          amount: Decimal.fromInt(100),
          unit: Unit.g,
          kcal: Decimal.fromInt(100),
          isDefault: true,
          source: ServingSource.off,
        ),
      ],
    );

/// A pushable search route so the pill's tap can land somewhere real.
/// We tag the target route with a key so the test can detect that the
/// route stack pushed it (find the key after `tap` + `pumpAndSettle`).
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
                builder: (_, __) => const Scaffold(
                  body: Center(
                    child: Text(
                      'search-landed',
                      key: Key('search-landed'),
                    ),
                  ),
                ),
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
  required List<LogEntry> entries,
  required DaySummary summary,
}) =>
    <Override>[
      daySummaryProvider(_today).overrideWith((_) async => summary),
      logEntriesProvider(_today).overrideWith((_) async => entries),
      recentFoodsProvider.overrideWith((_) async => <Food>[_food('r1')]),
      frequentFoodsProvider.overrideWith((_) async => <Food>[_food('f1')]),
      for (final r in WeightRange.values)
        weightSeriesProvider(r)
            .overrideWith((_) async => <WeightSeriesPoint>[]),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Empty-day pill — compact', () {
    testWidgets('renders when the day has zero entries', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final router = _router(initialLocation: Routes.todayPath);
      await tester.pumpWidget(
        _harness(
          router: router,
          overrides: _baselineOverrides(
            entries: const <LogEntry>[],
            summary: _emptySummary(_today),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('empty-day-pill')), findsOneWidget);
      expect(find.text('No food logged for this day'), findsOneWidget);
      expect(find.text('Log a food'), findsOneWidget);
    });

    testWidgets('hidden when the day has at least one entry', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final router = _router(initialLocation: Routes.todayPath);
      await tester.pumpWidget(
        _harness(
          router: router,
          overrides: _baselineOverrides(
            entries: <LogEntry>[_entry()],
            summary: _populatedSummary(_today),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('empty-day-pill')), findsNothing);
      expect(find.text('No food logged for this day'), findsNothing);
    });

    testWidgets(
      'tapping "Log a food" routes to the search screen',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final router = _router(initialLocation: Routes.todayPath);
        await tester.pumpWidget(
          _harness(
            router: router,
            overrides: _baselineOverrides(
              entries: const <LogEntry>[],
              summary: _emptySummary(_today),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Pre-condition: we're on /today and the pill rendered.
        expect(
          router.routerDelegate.currentConfiguration.uri.path,
          equals(Routes.todayPath),
        );
        expect(find.byKey(const Key('empty-day-pill')), findsOneWidget);

        await tester.tap(find.text('Log a food'));
        await tester.pumpAndSettle();

        // The router landed on /foods/search.
        expect(
          router.routerDelegate.currentConfiguration.uri.path,
          equals(Routes.foodsSearchPath),
        );
        expect(find.byKey(const Key('search-landed')), findsOneWidget);
      },
    );
  });

  group('Empty-day pill — expanded', () {
    testWidgets('renders on expanded when the day has zero entries',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final router = _router(initialLocation: Routes.todayPath);
      await tester.pumpWidget(
        _harness(
          router: router,
          overrides: _baselineOverrides(
            entries: const <LogEntry>[],
            summary: _emptySummary(_today),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('empty-day-pill')), findsOneWidget);
    });

    testWidgets('hidden on expanded when the day has entries',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final router = _router(initialLocation: Routes.todayPath);
      await tester.pumpWidget(
        _harness(
          router: router,
          overrides: _baselineOverrides(
            entries: <LogEntry>[_entry()],
            summary: _populatedSummary(_today),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('empty-day-pill')), findsNothing);
    });
  });
}
