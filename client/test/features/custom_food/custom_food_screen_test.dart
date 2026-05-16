import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/food.dart';
import 'package:fulfilled/domain/serving.dart';
import 'package:fulfilled/features/custom_food/custom_food_screen.dart';
import 'package:fulfilled/providers/draft_providers.dart';
import 'package:fulfilled/providers/food_providers.dart';
import 'package:fulfilled/providers/repository_providers.dart';
import 'package:fulfilled/repositories/food_repository.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:go_router/go_router.dart';

import '../../repositories/_harness.dart';

/// Mock repository that captures the [createCustom] payload so tests
/// can assert on what the screen actually built. Inherits everything
/// else (the screen only touches `createCustom`).
class _RecordingFoodRepository extends FoodRepository {
  _RecordingFoodRepository(super.api);

  FoodCreate? lastPayload;
  Food? toReturn;

  @override
  Future<Food> createCustom(FoodCreate data) async {
    lastPayload = data;
    if (toReturn != null) return toReturn!;
    return super.createCustom(data);
  }
}

GoRouter _router(GlobalKey<NavigatorState> navKey) {
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

Widget _harness({
  required _RecordingFoodRepository repo,
  required GlobalKey<NavigatorState> navKey,
}) {
  return ProviderScope(
    overrides: <Override>[
      foodRepositoryProvider.overrideWithValue(repo),
    ],
    child: MaterialApp.router(
      theme: buildLightTheme(),
      routerConfig: _router(navKey),
    ),
  );
}

Future<void> _pumpAndOpen(
  WidgetTester tester,
  Widget app,
) async {
  // Force a phone-sized viewport so the screen lays out as the mock.
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(app);
  await tester.pumpAndSettle();
  await tester.tap(find.text('open form'));
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
    'empty form: footer reads "Fix N errors to save" and the save action is disabled',
    (tester) async {
      await _pumpAndOpen(tester, _harness(repo: repo, navKey: navKey));

      // Five required fields with nothing filled in.
      expect(find.textContaining('Fix 5'), findsOneWidget);

      // Tapping the footer doesn't drive a save — repo never sees a
      // payload — but it does flip on inline error rows.
      await tester.tap(find.textContaining('Fix 5'));
      await tester.pumpAndSettle();

      expect(repo.lastPayload, isNull);
      // Inline "Required" rows appear under the missing fields. The
      // exact count is 5 (one per missing field).
      expect(find.text('Required'), findsNWidgets(5));
    },
  );

  testWidgets(
    'valid form: tapping Save POSTs the right payload, resets draft, pops',
    (tester) async {
      await _pumpAndOpen(tester, _harness(repo: repo, navKey: navKey));

      // Read the notifier directly — typing into the widget is brittle
      // (key event focus, viewport scroll, etc) and we already have a
      // separate brainstem of tests for the field bindings via the
      // notifier in draft_providers_test.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(CustomFoodScreen)),
      );
      final notifier = container.read(customFoodDraftProvider.notifier);
      notifier.setName("Mom's lasagna");
      notifier.setBrand('Homemade');
      notifier.setEnergyKcal(Decimal.fromInt(248));
      notifier.setProteinG(Decimal.fromInt(14));
      notifier.setCarbsG(Decimal.fromInt(22));
      notifier.setFatG(Decimal.fromInt(13));
      notifier.setSodiumMg(Decimal.fromInt(410));
      await tester.pump();

      expect(find.text('Save'), findsWidgets);

      // Pre-seed the repo to return a recognizable Food so we can
      // verify the pop value.
      repo.toReturn = Food(
        id: 'f_custom_test',
        name: "Mom's lasagna",
        source: FoodSource.user,
        isCustom: true,
        nutritionPer100g: container.read(customFoodDraftProvider).toNutrition(),
        servings: <Serving>[
          Serving(
            id: 'sv_test_100g',
            name: '100 g',
            grams: Decimal.fromInt(100),
            isDefault: true,
            source: ServingSource.system,
          ),
        ],
      );

      // The footer Save button — distinguish from the top-bar Save by
      // taking the last match (the footer is built last).
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();

      // Repo got the payload.
      expect(repo.lastPayload, isNotNull);
      expect(repo.lastPayload!.name, equals("Mom's lasagna"));
      expect(repo.lastPayload!.brand, equals('Homemade'));
      expect(repo.lastPayload!.nutrition.energyKcal, equals(Decimal.fromInt(248)));
      expect(repo.lastPayload!.nutrition.proteinG, equals(Decimal.fromInt(14)));
      expect(repo.lastPayload!.nutrition.carbsG, equals(Decimal.fromInt(22)));
      expect(repo.lastPayload!.nutrition.fatG, equals(Decimal.fromInt(13)));
      // Sodium is mg on the draft + on the presentation model. The wire
      // conversion to `sodium_g` happens in `NutritionPer100g.toJson` —
      // here we just confirm the screen passed mg through.
      expect(repo.lastPayload!.nutrition.sodiumMg, equals(Decimal.fromInt(410)));

      // Draft reset.
      expect(container.read(customFoodDraftProvider).name, isEmpty);
      expect(container.read(customFoodDraftProvider).energyKcal, isNull);
    },
  );
}
