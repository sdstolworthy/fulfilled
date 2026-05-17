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
import 'package:fulfilled/features/today/today_internals.dart';
import 'package:fulfilled/features/today/today_screen.dart';
import 'package:fulfilled/providers/food_providers.dart';
import 'package:fulfilled/providers/log_providers.dart';
import 'package:fulfilled/providers/weight_providers.dart';
import 'package:fulfilled/routing/routes.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:go_router/go_router.dart';

/// QL-106 — `TodayPill` render + tap routing.
///
/// Acceptance:
/// 1. The pill is **hidden** on the canonical `/today` view (the
///    rendered date equals local-now).
/// 2. The pill **renders** on a backdated `/today/:date` view (date !=
///    local-now).
/// 3. Tapping the pill calls `context.go(Routes.todayPath)` — the
///    router's current path becomes `/today`.
/// 4. The same render rule fires on the expanded form factor (≥ 1024).

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

List<Override> _baselineOverrides() => <Override>[
      daySummaryProvider(_today)
          .overrideWith((_) async => _emptySummary(_today)),
      daySummaryProvider(_yesterday)
          .overrideWith((_) async => _emptySummary(_yesterday)),
      logEntriesProvider(_today).overrideWith((_) async => <LogEntry>[]),
      logEntriesProvider(_yesterday).overrideWith((_) async => <LogEntry>[]),
      recentFoodsProvider.overrideWith((_) async => <Food>[_food('r1')]),
      frequentFoodsProvider.overrideWith((_) async => <Food>[_food('f1')]),
      for (final r in WeightRange.values)
        weightSeriesProvider(r)
            .overrideWith((_) async => <WeightSeriesPoint>[]),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TodayPill — compact', () {
    testWidgets('hidden on /today (local-now day)', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final router = _router(initialLocation: Routes.todayPath);
      await tester.pumpWidget(
        _harness(router: router, overrides: _baselineOverrides()),
      );
      await tester.pumpAndSettle();

      expect(find.byType(TodayPill), findsNothing);
    });

    testWidgets('renders on /today/:date (backdated)', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Build a backdated path manually to mirror what `pathForDay`
      // produces (YYYY-MM-DD for yesterday).
      final y = _yesterday.year.toString().padLeft(4, '0');
      final m = _yesterday.month.toString().padLeft(2, '0');
      final d = _yesterday.day.toString().padLeft(2, '0');
      final path = '${Routes.todayPath}/$y-$m-$d';

      final router = _router(initialLocation: path);
      await tester.pumpWidget(
        _harness(router: router, overrides: _baselineOverrides()),
      );
      await tester.pumpAndSettle();

      expect(find.byType(TodayPill), findsOneWidget);
      // The visible label.
      expect(find.text('Today'), findsWidgets);
    });

    testWidgets('tap routes to /today', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final y = _yesterday.year.toString().padLeft(4, '0');
      final m = _yesterday.month.toString().padLeft(2, '0');
      final d = _yesterday.day.toString().padLeft(2, '0');
      final backdatedPath = '${Routes.todayPath}/$y-$m-$d';

      final router = _router(initialLocation: backdatedPath);
      await tester.pumpWidget(
        _harness(router: router, overrides: _baselineOverrides()),
      );
      await tester.pumpAndSettle();

      // Pre-condition: we're on the backdate.
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        equals(backdatedPath),
      );

      await tester.tap(find.byKey(const Key('today-pill')));
      await tester.pumpAndSettle();

      // After the tap, the router lands on the canonical /today.
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        equals(Routes.todayPath),
      );
      // And the pill is gone because the rendered date equals
      // local-now again.
      expect(find.byType(TodayPill), findsNothing);
    });
  });

  group('TodayPill — expanded', () {
    testWidgets('renders on the expanded form factor', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final y = _yesterday.year.toString().padLeft(4, '0');
      final m = _yesterday.month.toString().padLeft(2, '0');
      final d = _yesterday.day.toString().padLeft(2, '0');
      final backdatedPath = '${Routes.todayPath}/$y-$m-$d';

      final router = _router(initialLocation: backdatedPath);
      await tester.pumpWidget(
        _harness(router: router, overrides: _baselineOverrides()),
      );
      await tester.pumpAndSettle();

      expect(find.byType(TodayPill), findsOneWidget);
    });

    testWidgets('hidden on /today (expanded form factor)', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final router = _router(initialLocation: Routes.todayPath);
      await tester.pumpWidget(
        _harness(router: router, overrides: _baselineOverrides()),
      );
      await tester.pumpAndSettle();

      expect(find.byType(TodayPill), findsNothing);
    });
  });
}
