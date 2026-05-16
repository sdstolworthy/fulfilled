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
import 'package:fulfilled/features/log_entry/log_entry_sheet.dart';
import 'package:fulfilled/providers/repository_providers.dart';
import 'package:fulfilled/repositories/log_repository.dart';
import 'package:fulfilled/theme/theme_data.dart';

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
      Serving(
        id: 'sv_50g',
        name: '50 g',
        grams: Decimal.fromInt(50),
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
    gramsTotal: Decimal.fromInt(servingId == 'sv_50g' ? 50 : 100) * q,
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
    return _stubReturn ?? throw StateError('no stub return configured');
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

      // Quantity stepper reads 1.5 (the seed quantity).
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const Key('log_entry_quantity_field_host')),
          matching: find.byType(TextField),
        ),
      );
      expect(field.controller!.text, '1.5');

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

      // Bump quantity 1.5 → 2.0 (the only changed field).
      await tester.tap(find.bySemanticsLabel('Increment'));
      await tester.pump();

      await tester.tap(find.byKey(const Key('log_entry_save_button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(repo.lastUpdateId, existing.id);
      final patch = repo.lastUpdatePatch!;
      // 1.5 + 0.5 = 2. Compare via `Decimal.parse` so trailing-zero
      // canonicalisation doesn't matter (`'2'` and `'2.0'` are equal).
      expect(patch.quantity, isNotNull);
      expect(patch.quantity, Decimal.parse('2'));
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
