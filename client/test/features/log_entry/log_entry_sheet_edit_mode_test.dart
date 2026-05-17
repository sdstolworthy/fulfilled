import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/food.dart';
import 'package:fulfilled/domain/log_entry.dart';
import 'package:fulfilled/domain/meal.dart';
import 'package:fulfilled/domain/nutrition.dart';
import 'package:fulfilled/domain/serving.dart';
import 'package:fulfilled/domain/unit.dart';
import 'package:fulfilled/features/log_entry/log_entry_sheet.dart';
import 'package:fulfilled/providers/repository_providers.dart';
import 'package:fulfilled/repositories/food_repository.dart';
import 'package:fulfilled/repositories/goal_repository.dart';
import 'package:fulfilled/repositories/log_repository.dart';
import 'package:fulfilled/routing/routes.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:go_router/go_router.dart';

import '../../repositories/_harness.dart';

/// Deterministic test food: 100 kcal / 10 g P / 20 g C / 0 g F per 100 g,
/// with one 100 g serving so the preview math collapses to "× quantity".
/// Mirrors the create-mode test's fixture for consistency.
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
    servings: <Serving>[
      Serving(
        id: 'sv_100g',
        label: '100 g',
        amount: Decimal.fromInt(100),
        unit: Unit.g,
        kcal: Decimal.fromInt(100),
        proteinG: Decimal.fromInt(10),
        carbsG: Decimal.fromInt(20),
        fatG: Decimal.zero,
        isDefault: true,
        source: ServingSource.user,
        sortOrder: 0,
      ),
      Serving(
        id: 'sv_50g',
        label: '50 g',
        amount: Decimal.fromInt(50),
        unit: Unit.g,
        kcal: Decimal.fromInt(50),
        proteinG: Decimal.fromInt(5),
        carbsG: Decimal.fromInt(10),
        fatG: Decimal.zero,
        isDefault: false,
        source: ServingSource.user,
        sortOrder: 1,
      ),
    ],
  );
}

/// Pre-built [LogEntry] used as the `existing` seed. Quantity 1.5, the
/// non-default serving, meal = `lunch`, a non-empty note. The choices
/// here are deliberate: every field differs from the create-mode
/// defaults so seed-vs-default mismatches are easy to spot in failing
/// assertions.
LogEntry _existingEntry({
  String? note = 'before yoga',
  Meal meal = Meal.lunch,
  String servingId = 'sv_50g',
  Decimal? quantity,
  DateTime? consumedOn,
}) {
  final q = quantity ?? Decimal.parse('1.5');
  final on = consumedOn ?? DateTime(2026, 5, 1);
  return LogEntry(
    id: 'le_existing_0',
    foodId: 'f_test',
    foodName: 'Test food',
    servingId: servingId,
    servingName: servingId == 'sv_50g' ? '50 g' : '100 g',
    consumedOn: DateTime(on.year, on.month, on.day),
    meal: meal,
    quantity: q,
    enteredAmount: Decimal.fromInt(servingId == 'sv_50g' ? 50 : 100) * q,
    enteredUnit: Unit.g,
    nutritionSnapshot: NutritionSnapshot(
      caloriesKcal: Decimal.fromInt(75),
    ),
    note: note,
    createdAt: DateTime(2026, 5, 1, 12, 30),
    updatedAt: DateTime(2026, 5, 1, 12, 30),
  );
}

/// Wraps the real `LogRepository` and records what
/// [LogRepository.update] was called with so tests can assert the
/// emitted `LogPatch` shape. Inherits everything else — `create`,
/// `entriesForDate`, etc. all go through the seed.
class _RecordingLogRepository extends LogRepository {
  _RecordingLogRepository({
    required super.api,
    required super.foodRepository,
    required super.goalRepository,
  });

  String? lastUpdateId;
  LogPatch? lastUpdatePatch;

  /// When non-null, [update] throws this instead of running the mock
  /// branch. The failure-mode test sets it to surface the SnackBar.
  Object? errorToThrow;

  @override
  Future<LogEntry> update(String entryId, LogPatch patch) async {
    lastUpdateId = entryId;
    lastUpdatePatch = patch;
    if (errorToThrow != null) {
      // Same throw shape a real Dio failure would surface — caught by
      // the sheet's submit `try/catch` and rendered as a SnackBar.
      throw errorToThrow!;
    }
    // Don't delegate to `super.update` — the test fixture's food isn't
    // in the mock seed catalog, so `FoodRepository.lookup` would throw
    // before we got to compare assertions. Return an arbitrary entry;
    // the sheet only forwards it to `Navigator.pop`, which the test
    // ignores.
    final stub = _stubReturn;
    if (stub == null) throw StateError('no stub return configured');
    return stub;
  }

  /// What [update] returns on the happy path. Set per-test if the
  /// assertion needs to inspect the returned entry; otherwise the test
  /// just looks at [lastUpdatePatch] and ignores the return value.
  LogEntry? _stubReturn;
  set stubReturn(LogEntry e) => _stubReturn = e;
}

/// Pump the inner body with overrides for `logRepositoryProvider` and
/// the sheet's scoped `quantityProvider`. Tests pump the body directly
/// (the same approach as `log_entry_sheet_test.dart`) so we don't have
/// to wrestle with the `showModalBottomSheet` plumbing.
Widget _harness({
  required Food food,
  required LogEntry existing,
  required _RecordingLogRepository repo,
  ValueChanged<LogCreate>? onSubmit,
}) {
  return ProviderScope(
    overrides: <Override>[
      logRepositoryProvider.overrideWithValue(repo),
      // Re-seed `quantityProvider` so the body reads the existing
      // entry's quantity (mirrors what `showLogEntrySheet` does in
      // production).
      quantityProvider.overrideWith((ref) => existing.quantity),
    ],
    child: MaterialApp(
      theme: buildLightTheme(),
      home: Scaffold(
        body: LogEntrySheetBody(
          food: food,
          existing: existing,
          onSubmit: onSubmit ?? (_) {},
          showGrabber: false,
        ),
      ),
    ),
  );
}

void main() {
  late _RecordingLogRepository repo;

  setUp(() {
    resetRepositoriesForTest();
    repo = _RecordingLogRepository(
      api: buildTestApiClient(),
      foodRepository: FoodRepositoryProxy.boot(),
      goalRepository: GoalRepositoryProxy.boot(),
    );
    // Happy-path return for `update` — tests only inspect the patch,
    // but the sheet still pops with whatever the repo returns, so we
    // need a non-null entry to avoid a `Future<Null>` cast surprise.
    repo.stubReturn = _existingEntry();
  });

  tearDown(() {
    teardownRepositoriesForTest();
  });

  testWidgets(
    'existing pre-seeds quantity / serving / meal / date / note + (editing) suffix',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final existing = _existingEntry();
      await tester.pumpWidget(_harness(
        food: _testFood(),
        existing: existing,
        repo: repo,
      ));
      await tester.pump();

      // Header suffix.
      expect(
        find.byKey(const Key('log_entry_header_editing_suffix')),
        findsOneWidget,
      );
      expect(find.text('(editing)'), findsOneWidget);

      // Per Ask 10 the AMOUNT stepper shows the consumed amount in
      // the entered unit (serving.amount × quantity, converted to
      // entered_unit). Seed: quantity=1.5, serving={50, g} ⇒ 75 g.
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const Key('log_entry_quantity_field_host')),
          matching: find.byType(TextField),
        ),
      );
      expect(field.controller!.text, '75');

      // Serving label shows the seed serving ("50 g"), not the default.
      expect(find.text('50 g'), findsWidgets);

      // Note pre-filled.
      expect(find.text('before yoga'), findsOneWidget);

      // CTA reads "Save changes".
      expect(find.text('Save changes'), findsOneWidget);
      expect(find.text('Save to log'), findsNothing);
    },
  );

  testWidgets('save disabled until form differs from the seed', (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final existing = _existingEntry();
    await tester.pumpWidget(_harness(
      food: _testFood(),
      existing: existing,
      repo: repo,
    ));
    await tester.pump();

    // Initially the button is disabled (form matches the seed exactly).
    final btn = tester.widget<FilledButton>(
      find.byKey(const Key('log_entry_save_button')),
    );
    expect(btn.onPressed, isNull);

    // Bump quantity via the stepper "Increment" button.
    final plus = find.bySemanticsLabel('Increment');
    await tester.tap(plus);
    await tester.pump();

    final btn2 = tester.widget<FilledButton>(
      find.byKey(const Key('log_entry_save_button')),
    );
    expect(btn2.onPressed, isNotNull);
  });

  testWidgets(
    'submit invokes LogRepository.update with a sparse LogPatch '
    'that omits unchanged fields and never sends food_id',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final existing = _existingEntry();
      await tester.pumpWidget(_harness(
        food: _testFood(),
        existing: existing,
        repo: repo,
      ));
      await tester.pump();

      // Per Ask 10 the stepper now nudges the AMOUNT (in the entered
      // unit) by a per-unit step — for grams the step is 1, so the
      // single Increment tap moves 75 g → 76 g, which back-computes
      // to a multiplier of 76 / 50 = 1.52.
      await tester.tap(find.bySemanticsLabel('Increment'));
      await tester.pump();

      await tester.tap(find.byKey(const Key('log_entry_save_button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(repo.lastUpdateId, existing.id);
      final patch = repo.lastUpdatePatch!;
      expect(patch.quantity, isNotNull);
      expect(patch.quantity, Decimal.parse('1.52'));
      // Everything else is sparse — the user touched nothing else.
      expect(patch.servingId, isNull);
      expect(patch.consumedOn, isNull);
      expect(patch.meal, isNull);
      expect(patch.note, isNull);
      expect(patch.clearNote, isFalse);
      // food_id is never modelled; assert at the wire too.
      expect(patch.toJson().containsKey('food_id'), isFalse);
    },
  );

  testWidgets('blanking a previously-non-null note emits clearNote: true',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final existing = _existingEntry(note: 'before yoga');
    await tester.pumpWidget(_harness(
      food: _testFood(),
      existing: existing,
      repo: repo,
    ));
    await tester.pump();

    // Clear the note field.
    final noteField = find.widgetWithText(TextField, 'before yoga');
    expect(noteField, findsOneWidget);
    await tester.enterText(noteField, '');
    await tester.pump();

    await tester.tap(find.byKey(const Key('log_entry_save_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final patch = repo.lastUpdatePatch!;
    expect(patch.note, isNull);
    expect(patch.clearNote, isTrue);
    // Wire shape: `"note": null` is the explicit clear signal.
    final json = patch.toJson();
    expect(json.containsKey('note'), isTrue);
    expect(json['note'], isNull);
    expect(json.containsKey('food_id'), isFalse);
  });

  testWidgets(
    'unchanged note (empty seed → empty form) emits neither note nor clearNote',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Seed with a null note; change quantity so the save button enables.
      final existing = _existingEntry(note: null);
      await tester.pumpWidget(_harness(
        food: _testFood(),
        existing: existing,
        repo: repo,
      ));
      await tester.pump();

      await tester.tap(find.bySemanticsLabel('Increment'));
      await tester.pump();

      await tester.tap(find.byKey(const Key('log_entry_save_button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final patch = repo.lastUpdatePatch!;
      expect(patch.note, isNull);
      expect(patch.clearNote, isFalse);
      final json = patch.toJson();
      expect(json.containsKey('note'), isFalse);
      expect(json.containsKey('food_id'), isFalse);
    },
  );

  testWidgets('submit failure keeps sheet open and surfaces a SnackBar',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    repo.errorToThrow = StateError('boom');

    final existing = _existingEntry();
    await tester.pumpWidget(_harness(
      food: _testFood(),
      existing: existing,
      repo: repo,
    ));
    await tester.pump();

    await tester.tap(find.bySemanticsLabel('Increment'));
    await tester.pump();

    await tester.tap(find.byKey(const Key('log_entry_save_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // SnackBar surfaced with the architect's copy.
    expect(
      find.textContaining('Could not save changes'),
      findsOneWidget,
    );
    // Sheet still mounted (the body is still on screen).
    expect(find.byType(LogEntrySheetBody), findsOneWidget);
  });

  // QL-105 — T-24 Case 2 router assertions for edit mode. After a
  // successful PATCH (or the no-op-PATCH branch), the sheet routes to
  // `pathForDay(newDate)` — the **new** date, even if the user shifted
  // it. Failure branch is unchanged (covered by the existing failure
  // test above).
  group('QL-105 — edit-mode save routes to pathForDay(newDate)', () {
    late _RecordingLogRepository routerRepo;

    setUp(() {
      // Re-use the suite-level setUp to reset repos, then build a
      // fresh recording repo for the router-aware tests below.
      routerRepo = _RecordingLogRepository(
        api: buildTestApiClient(),
        foodRepository: FoodRepositoryProxy.boot(),
        goalRepository: GoalRepositoryProxy.boot(),
      );
    });

    testWidgets(
      'save without date change routes to /today/<original-date>',
      (tester) async {
        tester.view.physicalSize = const Size(390, 1200);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        // Backdated seed so the expected path is `/today/2026-05-14`,
        // not the bare `/today` — gives us an unambiguous assertion.
        final existing = _existingEntry(
          consumedOn: DateTime(2026, 5, 14),
        );
        routerRepo.stubReturn = existing;
        // The repo update returns `existing` (date unchanged) — the
        // sheet routes to `pathForDay(newDate)` where newDate == _date
        // == existing.consumedOn.
        final expectedPath = '/today/2026-05-14';

        final router = _editRouterWithSheet(
          food: _testFood(),
          existing: existing,
        );

        await tester.pumpWidget(_editRouterHarness(
          router: router,
          repo: routerRepo,
          existing: existing,
        ));
        await tester.pumpAndSettle();
        await tester.tap(find.text('open sheet'));
        await tester.pumpAndSettle();

        // Bump quantity so the no-op-PATCH guard doesn't fire — we
        // want to exercise the success branch here.
        await tester.tap(find.bySemanticsLabel('Increment'));
        await tester.pump();

        await tester.tap(find.byKey(const Key('log_entry_save_button')));
        // Explicit pumps for the `await repo.update` + the post-await
        // `pop` + `context.go` chain. Edit-mode success has no
        // SnackBar but we keep the pump style identical to the
        // create-mode tests so any future SnackBar addition doesn't
        // silently stall this test.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(router.routerDelegate.currentConfiguration.uri.path,
            equals(expectedPath));
      },
    );

    testWidgets(
      'save WITH date shift routes to /today/<new-date>, NOT original',
      (tester) async {
        tester.view.physicalSize = const Size(390, 1200);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        // Simulate the user editing a May 14 entry and shifting its
        // date to May 15: `existing.consumedOn = May 14`, then drive
        // the form's `_date` to May 15 via the `initialDate`
        // `@visibleForTesting` seam (the production DATE picker lands
        // in QL-107; until then this seam is the cleanest way to
        // exercise the date-shift router path).
        final existing = _existingEntry(
          consumedOn: DateTime(2026, 5, 14),
        );
        routerRepo.stubReturn = existing;

        final shiftedDate = DateTime(2026, 5, 15);

        final router = GoRouter(
          initialLocation: '/host',
          routes: <RouteBase>[
            GoRoute(
              path: '/host',
              builder: (_, __) => Scaffold(
                body: Builder(
                  builder: (ctx) => Center(
                    child: TextButton(
                      onPressed: () => ctx.push('/foods/f_test'),
                      child: const Text('open sheet'),
                    ),
                  ),
                ),
              ),
            ),
            GoRoute(
              path: '/foods/:foodId',
              builder: (_, __) => Scaffold(
                body: LogEntrySheetBody(
                  food: _testFood(),
                  existing: existing,
                  initialDate: shiftedDate,
                  onSubmit: (_) {},
                  showGrabber: false,
                ),
              ),
            ),
            GoRoute(
              path: Routes.todayPath,
              routes: <RouteBase>[
                GoRoute(
                  path: ':date',
                  builder: (_, state) => Scaffold(
                    body: Center(
                      child: Text('day ${state.pathParameters['date']}'),
                    ),
                  ),
                ),
              ],
              builder: (_, __) =>
                  const Scaffold(body: Center(child: Text('today'))),
            ),
          ],
        );

        await tester.pumpWidget(_editRouterHarness(
          router: router,
          repo: routerRepo,
          existing: existing,
        ));
        await tester.pumpAndSettle();
        await tester.tap(find.text('open sheet'));
        await tester.pumpAndSettle();

        // The `initialDate` seam forced `_date == May 15` even though
        // `existing.consumedOn == May 14`. `_buildLogPatch` therefore
        // emits a `consumedOn: May 15` field (the only diff), so
        // `patch.isEmpty == false` and the success branch runs.
        await tester.tap(find.byKey(const Key('log_entry_save_button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        // Route uses **newDate** (May 15), not `existing.consumedOn`
        // (May 14). Architect §6.5 is explicit.
        expect(router.routerDelegate.currentConfiguration.uri.path,
            equals('/today/2026-05-15'));
        expect(router.routerDelegate.currentConfiguration.uri.path,
            isNot(equals('/today/2026-05-14')));
      },
    );
  });
}

/// Build a GoRouter for the edit-mode router tests. The host route
/// renders an "open sheet" button that pushes the sheet route; the
/// sheet route renders `LogEntrySheetBody` in edit mode against the
/// supplied [existing] entry. Destination routes mirror the production
/// shape (`/today`, `/today/:date`).
GoRouter _editRouterWithSheet({
  required Food food,
  required LogEntry existing,
}) {
  return GoRouter(
    initialLocation: '/host',
    routes: <RouteBase>[
      GoRoute(
        path: '/host',
        builder: (_, __) => Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () => ctx.push('/foods/${food.id}'),
                child: const Text('open sheet'),
              ),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/foods/:foodId',
        builder: (_, __) => Scaffold(
          body: LogEntrySheetBody(
            food: food,
            existing: existing,
            onSubmit: (_) {},
            showGrabber: false,
          ),
        ),
      ),
      GoRoute(
        path: Routes.todayPath,
        routes: <RouteBase>[
          GoRoute(
            path: ':date',
            builder: (_, state) => Scaffold(
              body: Center(child: Text('day ${state.pathParameters['date']}')),
            ),
          ),
        ],
        builder: (_, __) => const Scaffold(body: Center(child: Text('today'))),
      ),
    ],
  );
}

/// Wrap the edit-mode router under a `ProviderScope` that overrides
/// `logRepositoryProvider` (so PATCHes flow through the recording repo)
/// and re-seeds `quantityProvider` to the entry's quantity (mirrors
/// `showLogEntrySheet`'s production wiring).
Widget _editRouterHarness({
  required GoRouter router,
  required _RecordingLogRepository repo,
  required LogEntry existing,
}) {
  return ProviderScope(
    overrides: <Override>[
      logRepositoryProvider.overrideWithValue(repo),
      quantityProvider.overrideWith((ref) => existing.quantity),
    ],
    child: MaterialApp.router(
      theme: buildLightTheme(),
      routerConfig: router,
    ),
  );
}

/// Thin proxy factories that build the real (mock-backed) sibling
/// repositories `LogRepository` needs at construction. The mock food /
/// goal repositories don't carry test-specific state for these
/// scenarios; their seed catalog is enough.
class FoodRepositoryProxy {
  static FoodRepository boot() => FoodRepository(buildTestApiClient());
}

class GoalRepositoryProxy {
  static GoalRepository boot() => GoalRepository(buildTestApiClient());
}
