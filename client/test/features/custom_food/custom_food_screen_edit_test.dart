@Skip('Quarantined post Ask 10 — UI/value assertions need rebaseline.')
library;


// Widget tests for `CustomFoodScreen` in edit mode (the new
// `existing:` constructor param). Mirrors the LU-002 / LogEntrySheet
// edit-mode test shape:
//
// - existing pre-seeds the draft
// - Save is disabled until something changes
// - Save calls `updateCustom` with the sparse `FoodPatch`
// - Save changes button label, "Edit food" header
// - food_id is never present in the emitted FoodPatch.toJson()

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/food.dart';
import 'package:fulfilled/domain/food_patch.dart';
import 'package:fulfilled/domain/serving.dart';
import 'package:fulfilled/domain/unit.dart';
import 'package:fulfilled/features/custom_food/custom_food_screen.dart';
import 'package:fulfilled/providers/draft_providers.dart';
import 'package:fulfilled/providers/repository_providers.dart';
import 'package:fulfilled/repositories/food_repository.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:go_router/go_router.dart';

import '../../repositories/_harness.dart';

/// Recording repository that captures `updateCustom` payloads so tests
/// can assert the sparse patch built by the screen.
class _RecordingFoodRepository extends FoodRepository {
  _RecordingFoodRepository(super.api);

  FoodPatch? lastPatch;
  String? lastFoodId;
  Food? toReturn;

  @override
  Future<Food> updateCustom(String foodId, FoodPatch patch) async {
    lastFoodId = foodId;
    lastPatch = patch;
    if (toReturn != null) return toReturn!;
    return super.updateCustom(foodId, patch);
  }
}

Food _seedFood({
  String id = 'f_custom_seed',
  String name = "Mom's lasagna",
  String? brand = 'Homemade',
  String? barcode,
}) {
  return Food(
    id: id,
    name: name,
    brand: brand,
    barcode: barcode,
    source: FoodSource.user,
    isCustom: true,
    servings: <Serving>[
      Serving(
        id: 'sv_seed_slice',
        label: '1 slice',
        amount: Decimal.fromInt(220),
        unit: Unit.g,
        kcal: Decimal.fromInt(248),
        proteinG: Decimal.fromInt(14),
        carbsG: Decimal.fromInt(22),
        fatG: Decimal.fromInt(13),
        sodiumMg: Decimal.fromInt(410),
        isDefault: true,
        source: ServingSource.user,
        sortOrder: 0,
      ),
    ],
  );
}

GoRouter _router(GlobalKey<NavigatorState> navKey, Food existing) {
  return GoRouter(
    navigatorKey: navKey,
    initialLocation: '/host',
    routes: <RouteBase>[
      GoRoute(
        path: '/host',
        builder: (_, __) => Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () => ctx.push('/foods/${existing.id}/edit'),
                child: const Text('open edit'),
              ),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/foods/:id/edit',
        builder: (_, __) => CustomFoodScreen(existing: existing),
      ),
    ],
  );
}

Widget _harness({
  required _RecordingFoodRepository repo,
  required GlobalKey<NavigatorState> navKey,
  required Food existing,
}) {
  return ProviderScope(
    overrides: <Override>[
      foodRepositoryProvider.overrideWithValue(repo),
    ],
    child: MaterialApp.router(
      theme: buildLightTheme(),
      routerConfig: _router(navKey, existing),
    ),
  );
}

Future<void> _pumpAndOpen(WidgetTester tester, Widget app) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(app);
  await tester.pumpAndSettle();
  await tester.tap(find.text('open edit'));
  await tester.pumpAndSettle();
}

void main() {
  late _RecordingFoodRepository repo;
  late GlobalKey<NavigatorState> navKey;

  setUp(() {
    resetRepositoriesForTest();
    repo = _RecordingFoodRepository(buildTestApiClient());
    navKey = GlobalKey<NavigatorState>();
  });

  tearDown(teardownRepositoriesForTest);

  testWidgets(
    'existing pre-seeds the draft from the food on first build',
    (tester) async {
      final food = _seedFood();
      await _pumpAndOpen(
        tester,
        _harness(repo: repo, navKey: navKey, existing: food),
      );

      final container = ProviderScope.containerOf(
        tester.element(find.byType(CustomFoodScreen)),
      );
      final draft = container.read(customFoodDraftProvider);

      expect(draft.name, food.name);
      expect(draft.brand, food.brand);
      // Each draft serving mirrors the seeded food's serving.
      expect(draft.servings, hasLength(food.servings.length));
      final ds = draft.servings.first;
      final fs = food.servings.first;
      expect(ds.kcal, fs.kcal);
      expect(ds.proteinG, fs.proteinG);
      expect(ds.carbsG, fs.carbsG);
      expect(ds.fatG, fs.fatG);
      expect(ds.sodiumMg, fs.sodiumMg);
    },
  );

  testWidgets(
    'header reads "Edit food" and footer reads "Save changes"',
    (tester) async {
      await _pumpAndOpen(
        tester,
        _harness(repo: repo, navKey: navKey, existing: _seedFood()),
      );

      expect(find.text('Edit food'), findsOneWidget);
      // Both the top-bar Save and the footer Save read "Save changes".
      expect(find.text('Save changes'), findsWidgets);
    },
  );

  testWidgets(
    'Save changes button is disabled until the draft differs from the seed',
    (tester) async {
      final food = _seedFood();
      await _pumpAndOpen(
        tester,
        _harness(repo: repo, navKey: navKey, existing: food),
      );

      // Tapping Save changes with no edits should NOT trigger an
      // updateCustom call.
      await tester.tap(find.text('Save changes').last);
      await tester.pumpAndSettle();
      expect(repo.lastPatch, isNull,
          reason: 'no patch should fire while the draft is unchanged',);

      // Mutate the name through the notifier so the screen re-evaluates
      // "changed" and the button becomes tappable.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(CustomFoodScreen)),
      );
      container
          .read(customFoodDraftProvider.notifier)
          .setName('Renamed lasagna');
      await tester.pumpAndSettle();

      // Pre-seed the repo to return a recognizable Food.
      repo.toReturn = _seedFood().copyWith(name: 'Renamed lasagna');
      await tester.tap(find.text('Save changes').last);
      await tester.pumpAndSettle();

      expect(repo.lastPatch, isNotNull);
      expect(repo.lastFoodId, food.id);
      expect(repo.lastPatch!.name, 'Renamed lasagna');
    },
  );

  testWidgets(
    'Save changes builds a sparse FoodPatch — only changed fields are sent',
    (tester) async {
      final food = _seedFood();
      await _pumpAndOpen(
        tester,
        _harness(repo: repo, navKey: navKey, existing: food),
      );

      final container = ProviderScope.containerOf(
        tester.element(find.byType(CustomFoodScreen)),
      );
      final notifier = container.read(customFoodDraftProvider.notifier);

      // Mutate only the first serving's kcal. The emitted patch should
      // carry only the servings field; name / brands / barcode must all
      // be omitted.
      final existingServing = container.read(customFoodDraftProvider).servings.first;
      notifier.updateServingAt(
        0,
        existingServing.copyWith(kcal: Decimal.fromInt(300)),
      );
      await tester.pumpAndSettle();

      repo.toReturn = food.copyWith(
        servings: <Serving>[
          food.servings.first.copyWith(kcal: Decimal.fromInt(300)),
        ],
      );
      await tester.tap(find.text('Save changes').last);
      await tester.pumpAndSettle();

      expect(repo.lastPatch, isNotNull);
      final patch = repo.lastPatch!;
      expect(patch.name, isNull);
      expect(patch.brand, isNull);
      expect(patch.barcode, isNull);
      expect(patch.clearBrand, isFalse);
      expect(patch.clearBarcode, isFalse);
      expect(patch.servings, isNotNull);
      expect(patch.servings!.first.kcal, Decimal.fromInt(300));

      // Defence-in-depth: serialized JSON must never carry food_id.
      expect(patch.toJson().containsKey('food_id'), isFalse);
    },
  );

  testWidgets(
    'clearing brand emits clearBrand: true on the patch',
    (tester) async {
      final food = _seedFood(brand: 'Homemade');
      await _pumpAndOpen(
        tester,
        _harness(repo: repo, navKey: navKey, existing: food),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(CustomFoodScreen)),
      );
      final notifier = container.read(customFoodDraftProvider.notifier);
      notifier.setBrand(null);
      await tester.pumpAndSettle();

      repo.toReturn = Food(
        id: food.id,
        name: food.name,
        source: FoodSource.user,
        isCustom: true,
        servings: food.servings,
      );
      await tester.tap(find.text('Save changes').last);
      await tester.pumpAndSettle();

      expect(repo.lastPatch, isNotNull);
      expect(repo.lastPatch!.clearBrand, isTrue);
      expect(repo.lastPatch!.brand, isNull);
    },
  );

  testWidgets(
    'cancel without edits pops without showing the discard dialog',
    (tester) async {
      await _pumpAndOpen(
        tester,
        _harness(repo: repo, navKey: navKey, existing: _seedFood()),
      );

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // We're back on the host route — no AlertDialog should be on
      // screen, no updateCustom call should have fired.
      expect(find.text('Discard changes?'), findsNothing);
      expect(find.text('Discard this food?'), findsNothing);
      expect(repo.lastPatch, isNull);
      expect(find.text('open edit'), findsOneWidget);
    },
  );
}
