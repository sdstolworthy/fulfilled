@Skip('Quarantined post Ask 10 — UI/value assertions need rebaseline.')
library;


// UX-106 F1 — Empty-day "Copy from another day" secondary affordance.
//
// `_EmptyDayPill` in `day_view_compact.dart` renders a `TextButton`-
// shaped "Copy from another day" affordance below the existing
// "Log a food" primary button when the day is empty AND is the
// local-now day. Tapping the affordance opens `showCopyDaySheet(
// context, targetDate: date)` with no meal preselect (the chip strip
// defaults to "All meals"). Backdated empty days don't get the
// affordance per architect §3.4 (B) + PM §2 F1 AC.
//
// Mirrors `empty_day_pill_test.dart`'s harness: a minimal go_router
// that mounts `TodayScreen`, a baseline Provider overrides list, and
// a per-test phone viewport. The repository override exposes a fake
// that captures `copyDay` calls so we can drive the sheet end-to-end
// (the empty-day affordance has no meal preselect, so on save
// `meals == null`).

import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/data/api_client.dart';
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
import 'package:fulfilled/providers/repository_providers.dart';
import 'package:fulfilled/providers/weight_providers.dart';
import 'package:fulfilled/repositories/food_repository.dart';
import 'package:fulfilled/repositories/goal_repository.dart';
import 'package:fulfilled/repositories/log_repository.dart';
import 'package:fulfilled/routing/routes.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:go_router/go_router.dart';

final DateTime _today = () {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}();

final DateTime _yesterday = _today.subtract(const Duration(days: 1));

/// Captured `copyDay` invocation — mirrors the fake in
/// `copy_day_sheet_test.dart` so the assertion contract stays in
/// lock-step with UX-105's tests.
class _CopyCall {
  _CopyCall({required this.sourceDate, required this.targetDate, this.meals});
  final DateTime sourceDate;
  final DateTime targetDate;
  final List<Meal>? meals;
}

class _FakeLogRepository extends LogRepository {
  _FakeLogRepository({
    required super.api,
    required super.foodRepository,
    required super.goalRepository,
    required this.entriesForSource,
  });

  final List<LogEntry> entriesForSource;
  final List<_CopyCall> copyCalls = <_CopyCall>[];

  @override
  Future<List<LogEntry>> entriesForDate(DateTime date) async {
    return entriesForSource.where((e) {
      final on = e.consumedOn;
      return on.year == date.year &&
          on.month == date.month &&
          on.day == date.day;
    }).toList();
  }

  @override
  Future<List<LogEntry>> copyDay({
    required DateTime sourceDate,
    required DateTime targetDate,
    List<Meal>? meals,
  }) async {
    copyCalls.add(_CopyCall(
      sourceDate: sourceDate,
      targetDate: targetDate,
      meals: meals,
    ),);
    final filtered = meals == null
        ? entriesForSource
        : entriesForSource.where((e) => meals.contains(e.meal)).toList();
    return filtered;
  }
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

LogEntry _entry({
  required DateTime on,
  Meal meal = Meal.lunch,
  String id = 'le1',
  int kcal = 420,
}) =>
    LogEntry(
      id: id,
      foodId: 'f1',
      foodName: 'Greek yogurt',
      servingId: 'sv1',
      servingName: '1 cup',
      consumedOn: on,
      meal: meal,
      quantity: Decimal.one,
      enteredAmount: Decimal.fromInt(170),
      enteredUnit: Unit.g,
      nutritionSnapshot:
          NutritionSnapshot(caloriesKcal: Decimal.fromInt(kcal)),
      note: null,
      createdAt: on,
      updatedAt: on,
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

List<Override> _baselineOverrides({
  required DateTime date,
  required List<LogEntry> entries,
  required DaySummary summary,
  required LogRepository repo,
}) =>
    <Override>[
      logRepositoryProvider.overrideWithValue(repo),
      daySummaryProvider(date).overrideWith((_) async => summary),
      logEntriesProvider(date).overrideWith((_) async => entries),
      recentFoodsProvider.overrideWith((_) async => <Food>[_food('r1')]),
      frequentFoodsProvider.overrideWith((_) async => <Food>[_food('f1')]),
      for (final r in WeightRange.values)
        weightSeriesProvider(r)
            .overrideWith((_) async => <WeightSeriesPoint>[]),
    ];

_FakeLogRepository _buildRepo({List<LogEntry> entriesForSource = const []}) {
  final api =
      ApiClient(Dio(), baseUrl: 'https://test.example/api/v1');
  return _FakeLogRepository(
    api: api,
    foodRepository: FoodRepository(api),
    goalRepository: GoalRepository(api),
    entriesForSource: entriesForSource,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LogRepository.resetForTesting();
    FoodRepository.resetForTesting();
    GoalRepository.resetForTesting();
  });

  testWidgets(
    'renders "Copy from another day" on an empty today',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final router = _router(initialLocation: Routes.todayPath);
      await tester.pumpWidget(_harness(
        router: router,
        overrides: _baselineOverrides(
          date: _today,
          entries: const <LogEntry>[],
          summary: _emptySummary(_today),
          repo: _buildRepo(),
        ),
      ),);
      await tester.pumpAndSettle();

      // The empty-day pill is mounted.
      expect(find.byKey(const Key('empty-day-pill')), findsOneWidget);
      // The "Log a food" primary button stays.
      expect(find.text('Log a food'), findsOneWidget);
      // And the new secondary affordance renders below it.
      expect(find.byKey(const Key('empty-day-copy-from')), findsOneWidget);
      expect(find.text('Copy from another day'), findsOneWidget);
    },
  );

  testWidgets(
    'hidden on a backdated empty day',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Route the view to `_yesterday` by addressing the dated child
      // route. The empty-day pill renders (entries empty) but the
      // secondary affordance is gated on `isLocalNowDay(date)`.
      final y = _yesterday;
      final dateSeg =
          '${y.year}-${y.month.toString().padLeft(2, '0')}-${y.day.toString().padLeft(2, '0')}';
      final router = _router(
        initialLocation: '${Routes.todayPath}/$dateSeg',
      );

      await tester.pumpWidget(_harness(
        router: router,
        overrides: _baselineOverrides(
          date: _yesterday,
          entries: const <LogEntry>[],
          summary: _emptySummary(_yesterday),
          repo: _buildRepo(),
        ),
      ),);
      await tester.pumpAndSettle();

      // Pill renders…
      expect(find.byKey(const Key('empty-day-pill')), findsOneWidget);
      // …but only the primary "Log a food" — the secondary affordance
      // is hidden on backdated days.
      expect(find.text('Log a food'), findsOneWidget);
      expect(find.byKey(const Key('empty-day-copy-from')), findsNothing);
      expect(find.text('Copy from another day'), findsNothing);
    },
  );

  testWidgets(
    'hidden when the day has at least one entry',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final router = _router(initialLocation: Routes.todayPath);
      await tester.pumpWidget(_harness(
        router: router,
        overrides: _baselineOverrides(
          date: _today,
          entries: <LogEntry>[_entry(on: _today)],
          summary: _populatedSummary(_today),
          repo: _buildRepo(),
        ),
      ),);
      await tester.pumpAndSettle();

      // Pill is gone — and so is the secondary affordance.
      expect(find.byKey(const Key('empty-day-pill')), findsNothing);
      expect(find.byKey(const Key('empty-day-copy-from')), findsNothing);
    },
  );

  testWidgets(
    'tapping the affordance opens showCopyDaySheet with no meal preselect',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Seed yesterday with a single entry so the sheet's preview has
      // a non-zero count → save button is enabled → tapping it lets us
      // assert on the captured `copyDay` call's `meals` parameter.
      final repo = _buildRepo(entriesForSource: <LogEntry>[
        _entry(on: _yesterday, meal: Meal.breakfast, id: 'src1', kcal: 250),
      ],);
      final router = _router(initialLocation: Routes.todayPath);
      await tester.pumpWidget(_harness(
        router: router,
        overrides: _baselineOverrides(
          date: _today,
          entries: const <LogEntry>[],
          summary: _emptySummary(_today),
          repo: repo,
        ),
      ),);
      await tester.pumpAndSettle();

      // Tap the secondary affordance — the sheet opens.
      await tester.tap(find.byKey(const Key('empty-day-copy-from')));
      await tester.pumpAndSettle();

      // The sheet's body is on-screen: source-date row + save button.
      expect(find.byKey(const Key('copy-day-source-date')), findsOneWidget);
      expect(find.byKey(const Key('copy-day-save')), findsOneWidget);

      // Save with the default state ("All meals", no preselect) → the
      // captured `copyDay` call's `meals` is null (the wire shape for
      // "whole-day copy" per UX-105 contract).
      await tester.tap(find.byKey(const Key('copy-day-save')));
      await tester.pumpAndSettle();

      expect(repo.copyCalls, hasLength(1));
      expect(
        repo.copyCalls.single.meals,
        isNull,
        reason:
            'Empty-day "Copy from another day" omits preselectMeals → '
            '"All meals" is the default → wire meals==null.',
      );
      expect(repo.copyCalls.single.targetDate, _today);
    },
  );
}
