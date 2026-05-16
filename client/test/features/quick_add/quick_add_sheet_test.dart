import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/data/api_client.dart';
import 'package:fulfilled/domain/log_entry.dart';
import 'package:fulfilled/domain/meal.dart';
import 'package:fulfilled/features/quick_add/quick_add_sheet.dart';
import 'package:fulfilled/providers/repository_providers.dart';
import 'package:fulfilled/repositories/food_repository.dart';
import 'package:fulfilled/repositories/goal_repository.dart';
import 'package:fulfilled/repositories/log_repository.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:dio/dio.dart';

import '../../repositories/_harness.dart';

/// Test double for `LogRepository` — captures the create payload so the
/// test can assert on the synthetic Quick-add `foodId` / `servingId` /
/// quantity wiring without round-tripping through the mock latency
/// + state.
class _CapturingLogRepository extends LogRepository {
  _CapturingLogRepository({
    required super.api,
    required super.foodRepository,
    required super.goalRepository,
  });

  LogCreate? lastPayload;

  @override
  Future<LogEntry> create(LogCreate data) async {
    lastPayload = data;
    final snapshot = await super.create(data);
    // Defensive: also assert the entry id was assigned so the route
    // step of the sheet doesn't NPE on the returned value.
    expect(snapshot.id, isNotEmpty);
    return snapshot;
  }

  @override
  bool isPendingSync(String entryId) => false;
}

Widget _bodyHarness({
  required ValueChanged<LogCreate> onSubmit,
  required _CapturingLogRepository repo,
  Meal? defaultMeal,
  DateTime? defaultDate,
}) {
  return ProviderScope(
    overrides: <Override>[
      logRepositoryProvider.overrideWithValue(repo),
    ],
    child: MaterialApp(
      theme: buildLightTheme(),
      home: Scaffold(
        body: QuickAddSheetBody(
          defaultMeal: defaultMeal,
          defaultDate: defaultDate,
          showGrabber: false,
          onSubmit: onSubmit,
          skipRouteOnSave: true,
        ),
      ),
    ),
  );
}

_CapturingLogRepository _buildRepo() {
  final api = ApiClient(Dio());
  return _CapturingLogRepository(
    api: api,
    foodRepository: FoodRepository(api),
    goalRepository: GoalRepository(api),
  );
}

void main() {
  setUp(() {
    resetRepositoriesForTest();
  });

  tearDown(teardownRepositoriesForTest);

  testWidgets('renders title, kcal field, meal picker, date row',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_bodyHarness(
      onSubmit: (_) {},
      repo: _buildRepo(),
    ));
    await tester.pump();

    expect(find.byKey(const Key('quick_add_title')), findsOneWidget);
    expect(find.text('Quick add calories'), findsOneWidget);
    expect(find.byKey(const Key('quick_add_kcal_field')), findsOneWidget);
    expect(find.byKey(const Key('quick_add_date_row')), findsOneWidget);
    expect(find.byKey(const Key('quick_add_save_button')), findsOneWidget);

    // Macros toggle defaults to collapsed.
    expect(find.text('Add macros (optional)'), findsOneWidget);
    expect(find.byKey(const Key('quick_add_protein_field')), findsNothing);
  });

  testWidgets('Save fires LogCreate with food_quick_add + quantity = kcal',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = _buildRepo();
    LogCreate? captured;
    await tester.pumpWidget(_bodyHarness(
      onSubmit: (lc) => captured = lc,
      repo: repo,
      defaultMeal: Meal.snack,
    ));
    await tester.pump();

    // Replace the default 100 with 105.
    final kcalField = find.descendant(
      of: find.byKey(const Key('quick_add_kcal_field')),
      matching: find.byType(TextField),
    );
    await tester.enterText(kcalField, '105');
    await tester.pump();

    await tester.tap(find.byKey(const Key('quick_add_save_button')));
    // Repo.create awaits mockLatency (zero in test harness); pump a few
    // times for the post-await invalidation chain.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(captured, isNotNull);
    expect(captured!.foodId, equals('food_quick_add'));
    expect(captured!.servingId, equals('sv_kcal'));
    expect(captured!.meal, equals(Meal.snack));
    expect(captured!.quantity, equals(Decimal.fromInt(105)));
    expect(captured!.nutritionOverride, isNull,
        reason: 'macros toggle is collapsed by default, so override is null');

    // The capturing repo received the same payload and surfaced an
    // entry whose snapshot.kcal equals quantity (because the synthetic
    // food's panel is 100 kcal / 100 g / 1 g serving — collapses to 1:1).
    expect(repo.lastPayload?.foodId, equals('food_quick_add'));
  });

  testWidgets('Save without macros toggle yields snapshot with 0 macros',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = _buildRepo();
    await tester.pumpWidget(_bodyHarness(
      onSubmit: (_) {},
      repo: repo,
    ));
    await tester.pump();

    final kcalField = find.descendant(
      of: find.byKey(const Key('quick_add_kcal_field')),
      matching: find.byType(TextField),
    );
    await tester.enterText(kcalField, '200');
    await tester.pump();

    await tester.tap(find.byKey(const Key('quick_add_save_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Verify the entry that landed in the repo has 200 kcal + zero
    // macros (the synthetic food's per-100 g panel is zero P/C/F).
    final entries = await repo.entriesForDate(DateTime.now());
    final added =
        entries.where((e) => e.foodId == 'food_quick_add').toList();
    expect(added, isNotEmpty);
    final entry = added.first;
    expect(entry.kcal, equals(Decimal.fromInt(200)));
    expect(entry.nutritionSnapshot.proteinG, equals(Decimal.zero));
    expect(entry.nutritionSnapshot.carbsG, equals(Decimal.zero));
    expect(entry.nutritionSnapshot.fatG, equals(Decimal.zero));
  });

  testWidgets('toggle "Add macros" commits override → snapshot has macros',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = _buildRepo();
    LogCreate? captured;
    await tester.pumpWidget(_bodyHarness(
      onSubmit: (lc) => captured = lc,
      repo: repo,
    ));
    await tester.pump();

    // Set kcal = 300.
    final kcalField = find.descendant(
      of: find.byKey(const Key('quick_add_kcal_field')),
      matching: find.byType(TextField),
    );
    await tester.enterText(kcalField, '300');
    await tester.pump();

    // Tap the macros toggle.
    await tester.tap(find.byKey(const Key('quick_add_macros_toggle')));
    await tester.pump();

    expect(find.byKey(const Key('quick_add_protein_field')), findsOneWidget);
    expect(find.byKey(const Key('quick_add_carbs_field')), findsOneWidget);
    expect(find.byKey(const Key('quick_add_fat_field')), findsOneWidget);

    // Enter P=25, C=40, F=10.
    Future<void> enter(Key k, String v) async {
      final f = find.descendant(
        of: find.byKey(k),
        matching: find.byType(TextField),
      );
      await tester.enterText(f, v);
      await tester.pump();
    }

    await enter(const Key('quick_add_protein_field'), '25');
    await enter(const Key('quick_add_carbs_field'), '40');
    await enter(const Key('quick_add_fat_field'), '10');

    await tester.tap(find.byKey(const Key('quick_add_save_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // The captured LogCreate carries the override.
    expect(captured, isNotNull);
    expect(captured!.nutritionOverride, isNotNull);
    expect(captured!.nutritionOverride!.proteinG, equals(Decimal.fromInt(25)));
    expect(captured!.nutritionOverride!.carbsG, equals(Decimal.fromInt(40)));
    expect(captured!.nutritionOverride!.fatG, equals(Decimal.fromInt(10)));

    // The repo computed the snapshot using the override: protein
    // override is 25 g per 100 g, quantity is 300 g (300 kcal at 1 g/kcal),
    // serving is 1 g — so the snapshot.proteinG = 25 × (1 × 300 / 100)
    // = 75 g. The test asserts the scaled-up value to confirm the
    // override actually flowed through the snapshot math.
    final entries = await repo.entriesForDate(DateTime.now());
    final added =
        entries.where((e) => e.foodId == 'food_quick_add').toList();
    expect(added, isNotEmpty);
    final entry = added.last;
    expect(entry.kcal, equals(Decimal.fromInt(300)));
    expect(entry.nutritionSnapshot.proteinG, equals(Decimal.fromInt(75)));
    expect(entry.nutritionSnapshot.carbsG, equals(Decimal.fromInt(120)));
    expect(entry.nutritionSnapshot.fatG, equals(Decimal.fromInt(30)));
  });

  testWidgets('Save is disabled when kcal field is cleared', (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_bodyHarness(
      onSubmit: (_) {},
      repo: _buildRepo(),
    ));
    await tester.pump();

    final kcalField = find.descendant(
      of: find.byKey(const Key('quick_add_kcal_field')),
      matching: find.byType(TextField),
    );
    await tester.enterText(kcalField, '');
    await tester.pump();

    final button = tester.widget<FilledButton>(
      find.descendant(
        of: find.byKey(const Key('quick_add_save_button')),
        matching: find.byType(FilledButton),
      ),
    );
    expect(button.onPressed, isNull,
        reason: 'cleared kcal should disable the Save CTA');
  });
}
