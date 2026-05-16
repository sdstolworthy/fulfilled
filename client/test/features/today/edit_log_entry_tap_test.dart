// LU-005 — Day-view tap-to-edit wiring + pending-sync guard call site.
//
// Tests cover the four contracts the architect calls out in §2.1 +
// PMgr's ticket:
//
// 1. Tapping a **non-pending** logged row on the day view opens the
//    `LogEntrySheet` in edit mode (we detect this via the
//    `(editing)` suffix the sheet renders in its header — see
//    `log_entry_sheet.dart`'s `_Header.editing` branch).
// 2. Tapping a **pending-sync** row does **not** open the sheet and
//    surfaces the "Still syncing…" SnackBar. The guard reads
//    `LogRepository.isPendingSync` — we stub the repository.
// 3. A failed `foodDetailProvider` surfaces the
//    "Couldn't load this food…" SnackBar and the sheet stays closed.
// 4. The `_EntryRow` Semantics announces a single label ending in
//    `, edit` — the screen-reader contract for T-20.
// 5. `MealSection`'s widget contract is unchanged: the same prop list
//    it shipped pre-LU-005 still pumps cleanly.
//
// The handler under test (`editLogEntry`) lives in
// `lib/features/today/today_internals.dart`. We exercise it through a
// pumped `MealSection` so the production tap path (InkWell → onTap →
// onEntryTap(entry) → editLogEntry) is what the test asserts on.

import 'package:decimal/decimal.dart';
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
import 'package:fulfilled/features/log_entry/log_entry_sheet.dart';
import 'package:fulfilled/features/today/today_internals.dart';
import 'package:fulfilled/providers/food_providers.dart';
import 'package:fulfilled/providers/repository_providers.dart';
import 'package:fulfilled/repositories/food_repository.dart';
import 'package:fulfilled/repositories/goal_repository.dart';
import 'package:fulfilled/repositories/log_repository.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/meal_section.dart';
import 'package:dio/dio.dart';

/// Deterministic test food. 100 g serving, 100 kcal / 100 g. Identical
/// shape to the edit-mode sheet tests so we can hand it to
/// `showLogEntrySheet` without it tripping over missing servings.
Food _testFood() {
  return Food(
    id: 'f_test',
    name: 'Test food',
    brand: 'TestBrand',
    barcode: null,
    source: FoodSource.off,
    isCustom: false,
    qualityScore: null,
    nutriscore: null,
    nutritionPer100g: NutritionPer100g(
      energyKcal: Decimal.fromInt(100),
      proteinG: Decimal.fromInt(10),
      carbsG: Decimal.fromInt(20),
      fatG: Decimal.zero,
    ),
    servings: <Serving>[
      Serving(
        id: 'sv_100g',
        name: '100 g',
        grams: Decimal.fromInt(100),
        isDefault: true,
        source: ServingSource.user,
        sortOrder: 0,
      ),
    ],
  );
}

LogEntry _entry({String id = 'le_existing', String foodId = 'f_test'}) {
  return LogEntry(
    id: id,
    foodId: foodId,
    foodName: 'Test food',
    servingId: 'sv_100g',
    servingName: '100 g',
    consumedOn: DateTime(2026, 5, 14),
    meal: Meal.lunch,
    quantity: Decimal.one,
    gramsTotal: Decimal.fromInt(100),
    nutritionSnapshot: NutritionSnapshot(
      caloriesKcal: Decimal.fromInt(100),
    ),
    note: null,
    createdAt: DateTime(2026, 5, 14, 12, 30),
    updatedAt: DateTime(2026, 5, 14, 12, 30),
  );
}

MealSubtotal _subtotal() {
  return MealSubtotal(
    meal: Meal.lunch,
    kcal: Decimal.fromInt(100),
    proteinG: Decimal.fromInt(10),
    carbsG: Decimal.fromInt(20),
    fatG: Decimal.zero,
    entryCount: 1,
  );
}

/// Fake `LogRepository` that lets each test pick the `isPendingSync`
/// answer without standing up the real outbox + Hive box. Inherits
/// everything else from the real repo — but no test path in this file
/// invokes `create` / `update`, so the inherited mock state is moot.
class _FakeLogRepository extends LogRepository {
  _FakeLogRepository({
    required super.api,
    required super.foodRepository,
    required super.goalRepository,
    required bool pending,
  }) : _pending = pending;

  final bool _pending;

  @override
  bool isPendingSync(String entryId) => _pending;
}

ApiClient _buildApi() => ApiClient(Dio());

/// Pump a `MealSection` wired to `editLogEntry` exactly as the day view
/// wires it in production. The harness lets each test pin
/// `logRepositoryProvider` (for the pending-sync gate) and
/// `foodDetailProvider(foodId)` (for the food-fetch gate).
///
/// `foodResult` controls the food-fetch outcome:
///  - `Food` → the override returns it (happy path).
///  - `Object` (any non-`Food`) → treated as an error to throw.
///  - `null` → no override (default repository wiring).
Widget _harness({
  required LogEntry entry,
  required _FakeLogRepository repo,
  Object? foodResult,
}) {
  return ProviderScope(
    overrides: <Override>[
      logRepositoryProvider.overrideWithValue(repo),
      if (foodResult != null)
        foodDetailProvider(entry.foodId).overrideWith((ref) async {
          if (foodResult is Food) return foodResult;
          // Anything else (Exception subclass, raw String, etc.) is
          // surfaced as a fetch failure so the call site's `try/catch`
          // fires.
          throw foodResult;
        }),
    ],
    child: MaterialApp(
      theme: buildLightTheme(),
      // Phone-sized so the sheet (DraggableScrollableSheet on compact)
      // mounts on the modal layer rather than the desktop dialog. Both
      // paths render the `(editing)` suffix; pinning compact here keeps
      // the test deterministic.
      home: Consumer(
        builder: (ctx, ref, _) => Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              child: MealSection(
                subtotal: _subtotal(),
                entries: <LogEntry>[entry],
                onAddTap: () {},
                onEntryTap: (e) => editLogEntry(ref, ctx, e),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  // The fake repo doesn't touch the real api/food/goal mocks, but
  // `LogRepository`'s constructor still demands them. Build cheap
  // throwaway instances per test.
  late _FakeLogRepository repo;

  setUp(() {
    LogRepository.resetForTesting();
    FoodRepository.resetForTesting();
    GoalRepository.resetForTesting();
  });

  _FakeLogRepository buildRepo({required bool pending}) {
    final api = _buildApi();
    return _FakeLogRepository(
      api: api,
      foodRepository: FoodRepository(api),
      goalRepository: GoalRepository(api),
      pending: pending,
    );
  }

  testWidgets(
    'tap on a non-pending entry opens the LogEntrySheet in edit mode',
    (tester) async {
      // Compact viewport — `showLogEntrySheet` picks the bottom-sheet
      // path here; the `(editing)` suffix renders identically on both.
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      repo = buildRepo(pending: false);
      final entry = _entry();

      await tester.pumpWidget(_harness(
        entry: entry,
        repo: repo,
        foodResult: _testFood(),
      ));
      await tester.pump();

      // Sanity: the row rendered with the food name.
      expect(find.text('Test food'), findsOneWidget);

      // Sheet is not open yet.
      expect(
        find.byKey(const Key('log_entry_header_editing_suffix')),
        findsNothing,
      );

      // Tap the row.
      await tester.tap(find.text('Test food'));
      // Drive the async pipeline: tap dispatch → `editLogEntry`'s
      // `ref.read(foodDetailProvider.future)` microtask → bottom-sheet
      // route push → sheet enter animation settles. `pumpAndSettle` is
      // safe here because the bottom-sheet path uses bounded
      // animations (no infinite tickers in `LogEntrySheetBody`).
      await tester.pumpAndSettle();

      // Edit-mode confirmation #1: the `(editing)` suffix on the header.
      expect(
        find.byKey(const Key('log_entry_header_editing_suffix')),
        findsOneWidget,
      );
      // Edit-mode confirmation #2: the CTA reads "Save changes",
      // not "Save to log".
      expect(find.text('Save changes'), findsOneWidget);
      expect(find.text('Save to log'), findsNothing);
    },
  );

  testWidgets(
    'tap on a pending-sync entry shows the "Still syncing" SnackBar '
    'and does not open the sheet',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      repo = buildRepo(pending: true);
      final entry = _entry();

      await tester.pumpWidget(_harness(
        entry: entry,
        repo: repo,
        // Even if the food override is provided, the pending gate
        // should short-circuit before the fetch runs.
        foodResult: _testFood(),
      ));
      await tester.pump();

      await tester.tap(find.text('Test food'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // The pending-sync SnackBar appears with the architect's copy.
      expect(
        find.text('Still syncing — edit when sync finishes'),
        findsOneWidget,
      );
      // Sheet did NOT open.
      expect(
        find.byKey(const Key('log_entry_header_editing_suffix')),
        findsNothing,
      );
      expect(find.text('Save changes'), findsNothing);
    },
  );

  testWidgets(
    'food load failure shows error SnackBar and does not open the sheet',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      repo = buildRepo(pending: false);
      final entry = _entry();

      await tester.pumpWidget(_harness(
        entry: entry,
        repo: repo,
        // The provider throws on read — emulates a 404 / network error.
        foodResult: FoodNotFoundError(entry.foodId),
      ));
      await tester.pump();

      await tester.tap(find.text('Test food'));
      await tester.pump();
      // Drain the async future before the SnackBar pumps.
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        find.text("Couldn't load this food — try again"),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('log_entry_header_editing_suffix')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'entry row carries a Semantics label ending in ", edit"',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Engage the semantics tree so `find.bySemanticsLabel` resolves
      // (mirrors `macro_bar_semantics_test.dart`'s pattern).
      final handle = tester.ensureSemantics();
      addTearDown(handle.dispose);

      repo = buildRepo(pending: false);
      final entry = _entry();

      await tester.pumpWidget(_harness(
        entry: entry,
        repo: repo,
      ));
      await tester.pump();

      // The Semantics label is the merged announcement — food name,
      // serving, kcal, and the literal "edit" affordance suffix.
      // We don't pin the exact string (locale-dependent thousands
      // separators would creep in over time); we anchor on the trailing
      // affordance.
      expect(
        find.bySemanticsLabel(RegExp(r', edit$')),
        findsOneWidget,
      );
    },
  );

  test(
    'MealSection widget contract is unchanged — its construction props '
    'match the pre-LU-005 shape',
    () {
      // The widget exposes the same constructor parameters it shipped
      // with: `subtotal`, `entries`, `onAddTap` are required;
      // `onEntryTap` and `dense` are optional. The literal construction
      // below catches accidental rename / removal — if a future agent
      // tweaks the signature this file fails the analyzer first.
      final widget = MealSection(
        subtotal: MealSubtotal.empty(Meal.lunch),
        entries: const <LogEntry>[],
        onAddTap: () {},
        dense: false,
        onEntryTap: null,
      );
      expect(widget.subtotal, isA<MealSubtotal>());
      expect(widget.entries, isEmpty);
      expect(widget.dense, isFalse);
      expect(widget.onEntryTap, isNull);
      expect(widget.onAddTap, isA<VoidCallback>());
    },
  );
}
