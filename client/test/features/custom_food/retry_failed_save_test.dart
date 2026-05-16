// QL-109 — custom-food Retry-on-failure SnackBar.
//
// When `FoodRepository.createCustom` (create flow) or `updateCustom`
// (edit flow) throws, the screen surfaces a SnackBar with a Retry
// action. Tapping Retry re-invokes the same save path with the still-
// populated draft. The draft is never reset on the failure path.

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/food.dart';
import 'package:fulfilled/domain/food_patch.dart';
import 'package:fulfilled/domain/nutrition.dart';
import 'package:fulfilled/domain/serving.dart';
import 'package:fulfilled/features/custom_food/custom_food_screen.dart';
import 'package:fulfilled/providers/draft_providers.dart';
import 'package:fulfilled/providers/repository_providers.dart';
import 'package:fulfilled/repositories/food_repository.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:go_router/go_router.dart';

import '../../repositories/_harness.dart';

/// Configurable repository: the first N `createCustom` / `updateCustom`
/// calls throw, after that the real mock implementation runs. Counts
/// every call so the test can assert "retry re-invoked the save path".
class _FlakyFoodRepository extends FoodRepository {
  _FlakyFoodRepository(super.api, {this.failuresBeforeSuccess = 1});

  int failuresBeforeSuccess;
  int createCalls = 0;
  int updateCalls = 0;

  @override
  Future<Food> createCustom(FoodCreate data) async {
    createCalls++;
    if (failuresBeforeSuccess > 0) {
      failuresBeforeSuccess--;
      throw StateError('boom — simulated network failure');
    }
    return super.createCustom(data);
  }

  @override
  Future<Food> updateCustom(String foodId, FoodPatch patch) async {
    updateCalls++;
    if (failuresBeforeSuccess > 0) {
      failuresBeforeSuccess--;
      throw StateError('boom — simulated network failure');
    }
    return super.updateCustom(foodId, patch);
  }
}

Food _seedFood() {
  return Food(
    id: 'f_seed',
    name: "Mom's lasagna",
    brand: 'Homemade',
    source: FoodSource.user,
    isCustom: true,
    nutritionPer100g: NutritionPer100g(
      energyKcal: Decimal.fromInt(248),
      proteinG: Decimal.fromInt(14),
      carbsG: Decimal.fromInt(22),
      fatG: Decimal.fromInt(13),
    ),
    servings: <Serving>[
      Serving(
        id: 'sv_seed_100g',
        name: '100 g',
        grams: Decimal.fromInt(100),
        isDefault: true,
        source: ServingSource.system,
      ),
    ],
  );
}

GoRouter _createRouter(GlobalKey<NavigatorState> navKey) {
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
                onPressed: () => ctx.push('/foods/new'),
                child: const Text('open form'),
              ),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/foods/new',
        builder: (_, __) => const CustomFoodScreen(),
      ),
    ],
  );
}

GoRouter _editRouter(GlobalKey<NavigatorState> navKey, Food existing) {
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

void _setPhoneSize(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  setUp(resetRepositoriesForTest);
  tearDown(teardownRepositoriesForTest);

  testWidgets(
    'createCustom failure surfaces a SnackBar with a Retry action; '
    'tapping Retry re-invokes createCustom with the same draft',
    (tester) async {
      _setPhoneSize(tester);

      final repo = _FlakyFoodRepository(
        buildTestApiClient(),
        failuresBeforeSuccess: 1,
      );
      final navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            foodRepositoryProvider.overrideWithValue(repo),
          ],
          child: MaterialApp.router(
            theme: buildLightTheme(),
            routerConfig: _createRouter(navKey),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open form'));
      await tester.pumpAndSettle();

      // Seed a valid draft via the notifier (typing through widgets is
      // brittle and already covered by other tests).
      final container = ProviderScope.containerOf(
        tester.element(find.byType(CustomFoodScreen)),
      );
      final notifier = container.read(customFoodDraftProvider.notifier);
      notifier.setName('Retry me');
      notifier.setEnergyKcal(Decimal.fromInt(100));
      notifier.setProteinG(Decimal.fromInt(10));
      notifier.setCarbsG(Decimal.fromInt(20));
      notifier.setFatG(Decimal.fromInt(5));
      notifier.setSodiumMg(Decimal.fromInt(150));
      await tester.pump();

      // Tap footer Save — repo throws on the first attempt.
      await tester.tap(find.text('Save').last);
      // Drain the save microtask + the SnackBar slide-in. Use `pump`
      // (not `pumpAndSettle`) because the SnackBar's 4 s auto-dismiss
      // timer would otherwise be advanced and hide the action before
      // we can tap it.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(repo.createCalls, equals(1));
      // The screen did NOT pop — we're still on the form.
      expect(find.byType(CustomFoodScreen), findsOneWidget);
      // SnackBar with a Retry action surfaces.
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      // Draft survived the failure path.
      expect(
        container.read(customFoodDraftProvider).name,
        equals('Retry me'),
      );

      // Tap the Retry action — second attempt should succeed.
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(repo.createCalls, equals(2),
          reason: 'Retry must re-invoke createCustom against the same draft');
      // Success path: screen pops back to the host, draft reset.
      expect(find.text('open form'), findsOneWidget);
      expect(container.read(customFoodDraftProvider).name, isEmpty);
    },
  );

  testWidgets(
    'updateCustom failure surfaces a SnackBar with a Retry action; '
    'tapping Retry re-invokes updateCustom against the same draft',
    (tester) async {
      _setPhoneSize(tester);

      final existing = _seedFood();
      // Start with no flakiness so the seed insert succeeds, then dial
      // failures back up once the screen mounts.
      final repo = _FlakyFoodRepository(
        buildTestApiClient(),
        failuresBeforeSuccess: 0,
      );
      // Seed the repo's catalog so `updateCustom` can resolve the id
      // on the retry success path.
      await repo.createCustom(FoodCreate(
        name: existing.name,
        brand: existing.brand,
        nutrition: existing.nutritionPer100g,
      ));
      // The first call above counted; reset so the assertions focus
      // on screen-driven calls below.
      repo.createCalls = 0;
      // The just-inserted food has a new id; `customFoods` appends
      // freshly-created rows at the tail, so use `.last`.
      final inserted = (await repo.customFoods()).last;
      // Now arm one failure for the upcoming updateCustom call.
      repo.failuresBeforeSuccess = 1;

      final navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            foodRepositoryProvider.overrideWithValue(repo),
          ],
          child: MaterialApp.router(
            theme: buildLightTheme(),
            routerConfig: _editRouter(navKey, inserted),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open edit'));
      await tester.pumpAndSettle();

      // Mutate one field so the patch is non-empty.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(CustomFoodScreen)),
      );
      final notifier = container.read(customFoodDraftProvider.notifier);
      notifier.setName('Renamed');
      await tester.pump();

      // First save attempt — throws.
      await tester.tap(find.text('Save changes').last);
      // See create-flow test above for why `pump` not `pumpAndSettle`.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(repo.updateCalls, equals(1));
      expect(find.byType(CustomFoodScreen), findsOneWidget);
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      // Draft survived (still says Renamed).
      expect(
        container.read(customFoodDraftProvider).name,
        equals('Renamed'),
      );

      // Tap Retry — second attempt succeeds.
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(repo.updateCalls, equals(2),
          reason: 'Retry must re-invoke updateCustom against the same draft');
      // Popped back to host.
      expect(find.text('open edit'), findsOneWidget);
    },
  );
}
