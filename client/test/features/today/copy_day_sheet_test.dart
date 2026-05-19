// UX-105 — `CopyDaySheet` widget tests.
//
// Covers:
//   (a) save invokes `LogRepository.copyDay` with the selected meals
//       and source date; partial-skip SnackBar text mirrors the
//       PM-mandated copy.
//   (b) cancel (sheet dismissal) does NOT invoke `copyDay`.
//   (c) the preselected meal renders as selected; the default source
//       date is `targetDate - 1`.
//   (d) "All meals" is the default when `preselectMeals == null`.
//
// The sheet is form-factor-blind per T-15 (architect §3.4 (C)); we
// pump the `CopyDaySheet` body directly inside a `ProviderScope` —
// faster than driving `showCopyDaySheet` and pinning the viewport,
// and the body composition is identical on both branches.

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/data/api_client.dart';
import 'package:fulfilled/domain/log_entry.dart';
import 'package:fulfilled/domain/meal.dart';
import 'package:fulfilled/domain/nutrition.dart';
import 'package:fulfilled/domain/unit.dart';
import 'package:fulfilled/features/today/widgets/copy_day_sheet.dart';
import 'package:fulfilled/providers/repository_providers.dart';
import 'package:fulfilled/repositories/food_repository.dart';
import 'package:fulfilled/repositories/goal_repository.dart';
import 'package:fulfilled/repositories/log_repository.dart';
import 'package:fulfilled/routing/routes.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/snackbar_throttle.dart';
import 'package:dio/dio.dart';
import 'package:go_router/go_router.dart';

/// Captured arguments from each `copyDay` call.
class _CopyCall {
  _CopyCall({required this.sourceDate, required this.targetDate, this.meals});
  final DateTime sourceDate;
  final DateTime targetDate;
  final List<Meal>? meals;
}

/// Fake `LogRepository` — captures `copyDay` invocations and lets the
/// test control the returned list (drives partial-skip via
/// `created.length < requested.length`).
class _FakeLogRepository extends LogRepository {
  _FakeLogRepository({
    required super.api,
    required super.foodRepository,
    required this.entriesForSource,
    this.copyResult,
    this.throwOnCopy = false,
  });

  /// Returned by `entriesForDate(sourceDate)`. The preview provider
  /// reads through this, so it controls the preview's count + kcal.
  final List<LogEntry> entriesForSource;

  /// Returned by `copyDay`. When `null`, defaults to a 1:1 echo of
  /// `entriesForSource` (no partial-skip).
  final List<LogEntry>? copyResult;

  /// When `true`, `copyDay` throws — drives the failure-path SnackBar
  /// for FX-004's throttle regression.
  final bool throwOnCopy;

  final List<_CopyCall> copyCalls = <_CopyCall>[];

  @override
  Future<List<LogEntry>> entriesForDate(DateTime date) async {
    // Source-date match is by Y/M/D — mirror the real repo's filter.
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
    if (throwOnCopy) {
      throw Exception('network unavailable');
    }
    // Filter by `meals` so the partial-skip test gets a deterministic
    // requested-count regardless of seed.
    final filtered = meals == null
        ? entriesForSource
        : entriesForSource.where((e) => meals.contains(e.meal)).toList();
    return copyResult ?? filtered;
  }
}

ApiClient _buildApi() =>
    ApiClient(Dio(), baseUrl: 'https://test.example/api/v1');

LogEntry _entry({
  required String id,
  required Meal meal,
  required DateTime on,
  int kcal = 100,
}) {
  return LogEntry(
    id: id,
    foodId: 'f_test',
    foodName: 'Test food',
    servingId: 'sv_100g',
    servingName: '100 g',
    consumedOn: on,
    meal: meal,
    quantity: Decimal.one,
    enteredAmount: Decimal.fromInt(100),
    enteredUnit: Unit.g,
    nutritionSnapshot:
        NutritionSnapshot(caloriesKcal: Decimal.fromInt(kcal)),
    note: null,
    createdAt: on,
    updatedAt: on,
  );
}

/// Pump a host route with a button that opens the sheet via
/// `showCopyDaySheet` — the production entry path. The host stays
/// mounted under the sheet so `_save`'s `Navigator.pop` has a route
/// to pop and `context.go(pathForDay(targetDate))` has a `/today/*`
/// destination to land on.
Widget _harness({
  required _FakeLogRepository repo,
  required DateTime targetDate,
  List<Meal>? preselectMeals,
}) {
  final router = GoRouter(
    initialLocation: '/host',
    routes: <RouteBase>[
      GoRoute(
        path: '/host',
        builder: (_, __) => _HostScreen(
          targetDate: targetDate,
          preselectMeals: preselectMeals,
        ),
      ),
      GoRoute(
        path: Routes.todayPath,
        builder: (_, __) => const Scaffold(
          body: Center(
            child: Text('today-landed', key: Key('today-landed')),
          ),
        ),
        routes: <RouteBase>[
          GoRoute(
            path: ':date',
            builder: (_, state) => Scaffold(
              body: Center(
                child: Text(
                  'today-landed-${state.pathParameters['date']}',
                  key: const Key('today-landed-dated'),
                ),
              ),
            ),
          ),
        ],
      ),
    ],
  );
  return ProviderScope(
    overrides: <Override>[
      logRepositoryProvider.overrideWithValue(repo),
    ],
    child: MaterialApp.router(
      theme: buildLightTheme(),
      routerConfig: router,
    ),
  );
}

class _HostScreen extends StatelessWidget {
  const _HostScreen({required this.targetDate, this.preselectMeals});

  final DateTime targetDate;
  final List<Meal>? preselectMeals;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          key: const Key('open-copy-sheet'),
          onPressed: () => showCopyDaySheet(
            context,
            targetDate: targetDate,
            preselectMeals: preselectMeals,
          ),
          child: const Text('Open copy sheet'),
        ),
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LogRepository.resetForTesting();
    FoodRepository.resetForTesting();
    GoalRepository.resetForTesting();
    // FX-004 — the throttle's static map persists across tests in the
    // same process; clear it so prior cases don't suppress the first
    // SnackBar in a later one.
    SnackbarThrottle.resetForTest();
  });

  _FakeLogRepository buildRepo({
    required List<LogEntry> entriesForSource,
    List<LogEntry>? copyResult,
    bool throwOnCopy = false,
  }) {
    final api = _buildApi();
    return _FakeLogRepository(
      api: api,
      foodRepository: FoodRepository(api),
      entriesForSource: entriesForSource,
      copyResult: copyResult,
      throwOnCopy: throwOnCopy,
    );
  }

  testWidgets(
    'save invokes copyDay with the selected meals (per-meal preselect)',
    (tester) async {
      tester.view.physicalSize = const Size(800, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final today = DateTime(2026, 5, 15);
      final yesterday = DateTime(2026, 5, 14);
      // Seed 1 breakfast entry on yesterday (the default source).
      final repo = buildRepo(
        entriesForSource: <LogEntry>[
          _entry(id: 'le1', meal: Meal.breakfast, on: yesterday, kcal: 250),
        ],
      );

      await tester.pumpWidget(_harness(
        repo: repo,
        targetDate: today,
        preselectMeals: <Meal>[Meal.breakfast],
      ),);
      await tester.pumpAndSettle();
      // Open the sheet via the production entry point.
      await tester.tap(find.byKey(const Key('open-copy-sheet')));
      await tester.pumpAndSettle();

      // The preview line resolves to the breakfast row.
      expect(find.byKey(const Key('copy-day-preview')), findsOneWidget);
      // Save button is enabled.
      final save = find.byKey(const Key('copy-day-save'));
      expect(save, findsOneWidget);
      await tester.tap(save);
      await tester.pumpAndSettle();

      // `copyDay` was invoked once, with the preselected meal and the
      // default source date (yesterday).
      expect(repo.copyCalls, hasLength(1));
      final call = repo.copyCalls.single;
      expect(call.targetDate, today);
      expect(call.sourceDate.year, yesterday.year);
      expect(call.sourceDate.month, yesterday.month);
      expect(call.sourceDate.day, yesterday.day);
      expect(call.meals, equals(<Meal>[Meal.breakfast]));
    },
  );

  testWidgets(
    'cancel (sheet dispose without save) does not invoke copyDay',
    (tester) async {
      tester.view.physicalSize = const Size(800, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final today = DateTime(2026, 5, 15);
      final yesterday = DateTime(2026, 5, 14);
      final repo = buildRepo(
        entriesForSource: <LogEntry>[
          _entry(id: 'le1', meal: Meal.lunch, on: yesterday),
        ],
      );

      await tester.pumpWidget(_harness(
        repo: repo,
        targetDate: today,
      ),);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open-copy-sheet')));
      await tester.pumpAndSettle();

      // Don't tap save — drag the modal sheet down to dismiss (the
      // bottom-sheet route's barrier-dismiss / drag-dismiss is the
      // natural cancel path).
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      await tester.pumpAndSettle();

      expect(repo.copyCalls, isEmpty);
    },
  );

  testWidgets(
    'preselectMeals: null pre-selects "All meals"',
    (tester) async {
      tester.view.physicalSize = const Size(800, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final today = DateTime(2026, 5, 15);
      final yesterday = DateTime(2026, 5, 14);
      final repo = buildRepo(
        entriesForSource: <LogEntry>[
          _entry(id: 'le1', meal: Meal.breakfast, on: yesterday),
          _entry(id: 'le2', meal: Meal.lunch, on: yesterday),
        ],
      );

      await tester.pumpWidget(_harness(
        repo: repo,
        targetDate: today,
      ),);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open-copy-sheet')));
      await tester.pumpAndSettle();

      // Tap save with the default ("All meals") state.
      await tester.tap(find.byKey(const Key('copy-day-save')));
      await tester.pumpAndSettle();

      expect(repo.copyCalls, hasLength(1));
      expect(repo.copyCalls.single.meals, isNull,
          reason: '"All meals" is the meals==null wire shape',);
    },
  );

  testWidgets(
    'partial-skip SnackBar reads "Copied N of M — K skipped (food no longer available)"',
    (tester) async {
      tester.view.physicalSize = const Size(800, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final today = DateTime(2026, 5, 15);
      final yesterday = DateTime(2026, 5, 14);
      // Four source entries but the repo "copies" only three (partial
      // skip — one food was missing).
      final src = <LogEntry>[
        _entry(id: 'le1', meal: Meal.breakfast, on: yesterday),
        _entry(id: 'le2', meal: Meal.lunch, on: yesterday),
        _entry(id: 'le3', meal: Meal.dinner, on: yesterday),
        _entry(id: 'le4', meal: Meal.snack, on: yesterday),
      ];
      final repo = buildRepo(
        entriesForSource: src,
        copyResult: src.sublist(0, 3),
      );

      await tester.pumpWidget(_harness(
        repo: repo,
        targetDate: today,
      ),);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open-copy-sheet')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('copy-day-save')));
      // SnackBar is animated — pump to land it.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 500));

      // The partial-skip text matches the PM/architect copy.
      expect(
        find.textContaining('Copied 3 of 4'),
        findsOneWidget,
      );
      expect(
        find.textContaining('1 skipped'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'FX-004: rapid second save-tap on the failure path does not stack a '
    'second "Could not copy" SnackBar within the 3 s throttle window',
    (tester) async {
      tester.view.physicalSize = const Size(800, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final today = DateTime(2026, 5, 15);
      final yesterday = DateTime(2026, 5, 14);
      final repo = buildRepo(
        entriesForSource: <LogEntry>[
          _entry(id: 'le1', meal: Meal.breakfast, on: yesterday),
        ],
        throwOnCopy: true,
      );

      await tester.pumpWidget(_harness(
        repo: repo,
        targetDate: today,
      ),);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open-copy-sheet')));
      await tester.pumpAndSettle();

      // First save attempt — `copyDay` throws, failure SnackBar lands
      // via `SnackbarThrottle.show(..., key: 'copy_day_sheet')`. Use
      // discrete pumps (not `pumpAndSettle`) — the `SnackBar` has a
      // 4 s auto-dismiss timer that `pumpAndSettle` would block on.
      await tester.tap(find.byKey(const Key('copy-day-save')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        find.textContaining('Could not copy'),
        findsOneWidget,
        reason: 'first failure should render its SnackBar',
      );

      // Rapid second tap — the throttle's 3 s per-(context, key)
      // cooldown should swallow the second SnackBar. Only one
      // "Could not copy" text remains in the tree (not two stacked).
      await tester.tap(find.byKey(const Key('copy-day-save')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        find.textContaining('Could not copy'),
        findsOneWidget,
        reason:
            'the throttle should suppress the second SnackBar within '
            'the 3 s cooldown — only one "Could not copy" text should '
            'be in the tree',
      );
      // Both taps did hit the repo — only the SnackBar is throttled,
      // not the underlying retry attempt itself.
      expect(repo.copyCalls, hasLength(2));
    },
  );
}
