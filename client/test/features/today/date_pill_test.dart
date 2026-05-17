// UX-104 — `DatePill` widget + chevron removal.
//
// Acceptance:
// 1. Renders `"Today"` when the date equals local-now.
// 2. Renders `"EEE, MMM d"` (e.g. `"Wed, May 14"`) on a backdated view.
// 3. Tapping the pill mounts a `DatePickerDialog` in the overlay
//    (Flutter's `showDatePicker` route).
// 4. Picking a date routes via `pathForDay(picked)` — the router's
//    current path becomes the canonical day path.
// 5. The chevron `IconButton36`s are gone from both day views — no
//    `Icons.chevron_left` / `Icons.chevron_right` in the day-view
//    header subtree.

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
import 'package:intl/intl.dart';

final DateTime _today = () {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}();
final DateTime _yesterday = _today.subtract(const Duration(days: 1));
final DateTime _twoDaysAgo = _today.subtract(const Duration(days: 2));

String _backdatedPath(DateTime date) {
  final y = date.year.toString().padLeft(4, '0');
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return '${Routes.todayPath}/$y-$m-$d';
}

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
      daySummaryProvider(_twoDaysAgo)
          .overrideWith((_) async => _emptySummary(_twoDaysAgo)),
      logEntriesProvider(_today).overrideWith((_) async => <LogEntry>[]),
      logEntriesProvider(_yesterday).overrideWith((_) async => <LogEntry>[]),
      logEntriesProvider(_twoDaysAgo).overrideWith((_) async => <LogEntry>[]),
      recentFoodsProvider.overrideWith((_) async => <Food>[_food('r1')]),
      frequentFoodsProvider.overrideWith((_) async => <Food>[_food('f1')]),
      for (final r in WeightRange.values)
        weightSeriesProvider(r)
            .overrideWith((_) async => <WeightSeriesPoint>[]),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DatePill — label', () {
    testWidgets('reads "Today" on the local-now day', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final router = _router(initialLocation: Routes.todayPath);
      await tester.pumpWidget(
        _harness(router: router, overrides: _baselineOverrides()),
      );
      await tester.pumpAndSettle();

      // The pill itself is mounted...
      expect(find.byType(DatePill), findsOneWidget);
      // ...and renders the literal label "Today".
      final pillTextFinder = find.descendant(
        of: find.byType(DatePill),
        matching: find.text('Today'),
      );
      expect(pillTextFinder, findsOneWidget);
    });

    testWidgets('reads "EEE, MMM d" on a backdated view', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final router = _router(initialLocation: _backdatedPath(_yesterday));
      await tester.pumpWidget(
        _harness(router: router, overrides: _baselineOverrides()),
      );
      await tester.pumpAndSettle();

      final expected = DateFormat('EEE, MMM d').format(_yesterday);
      final pillTextFinder = find.descendant(
        of: find.byType(DatePill),
        matching: find.text(expected),
      );
      expect(pillTextFinder, findsOneWidget);
    });
  });

  group('DatePill — tap opens picker, picker routes', () {
    testWidgets('tap mounts a DatePickerDialog in the overlay',
        (tester) async {
      // The DatePicker dialog needs vertical headroom; pump a taller
      // viewport so its layout doesn't overflow in the test surface.
      tester.view.physicalSize = const Size(390, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final router = _router(initialLocation: Routes.todayPath);
      await tester.pumpWidget(
        _harness(router: router, overrides: _baselineOverrides()),
      );
      await tester.pumpAndSettle();

      // No picker before tap.
      expect(find.byType(DatePickerDialog), findsNothing);

      await tester.tap(find.byKey(const Key('date-pill')));
      await tester.pumpAndSettle();

      expect(find.byType(DatePickerDialog), findsOneWidget);
    });

    testWidgets('picking a date routes via pathForDay(picked)',
        (tester) async {
      tester.view.physicalSize = const Size(390, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Start on /today so the post-pick route lands on the canonical
      // backdated path (`pathForDay(_yesterday)` ≠ `pathForDay(_today)`).
      final router = _router(initialLocation: Routes.todayPath);
      await tester.pumpWidget(
        _harness(router: router, overrides: _baselineOverrides()),
      );
      await tester.pumpAndSettle();

      // Open the picker.
      await tester.tap(find.byKey(const Key('date-pill')));
      await tester.pumpAndSettle();

      expect(find.byType(DatePickerDialog), findsOneWidget);

      // The dialog is a route on the navigator. We pop it with the
      // sentinel `_yesterday` value to short-circuit the Flutter-owned
      // grid cell-tapping (which is implementation-detail-coupled to
      // the calendar's month-grid widget). The widget under test cares
      // about the picker's return value flowing into `pathForDay` and
      // `context.go` — not how the user got to that value.
      final pickerContext = tester.element(find.byType(DatePickerDialog));
      Navigator.of(pickerContext).pop(_yesterday);
      await tester.pumpAndSettle();

      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        equals(_backdatedPath(_yesterday)),
      );
    });
  });

  group('UX-104 — chevrons are gone from the day-view header', () {
    testWidgets('compact: no chevron_left / chevron_right icons',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Pump a backdated view — that's the prior chevron-rich state
      // (chevrons + title block + TodayPill). Post-UX-104, neither
      // chevron icon is in the tree.
      final router = _router(initialLocation: _backdatedPath(_yesterday));
      await tester.pumpWidget(
        _harness(router: router, overrides: _baselineOverrides()),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.chevron_left), findsNothing);
      expect(find.byIcon(Icons.chevron_right), findsNothing);
    });

    testWidgets('expanded: no chevron_left / chevron_right icons',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final router = _router(initialLocation: _backdatedPath(_yesterday));
      await tester.pumpWidget(
        _harness(router: router, overrides: _baselineOverrides()),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.chevron_left), findsNothing);
      expect(find.byIcon(Icons.chevron_right), findsNothing);
    });
  });
}
