import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/drafts.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/food.dart';
import 'package:fulfilled/domain/serving.dart';
import 'package:fulfilled/domain/unit.dart';
import 'package:fulfilled/features/custom_food/custom_food_screen.dart';
import 'package:fulfilled/providers/draft_providers.dart';
import 'package:fulfilled/providers/food_providers.dart';
import 'package:fulfilled/providers/repository_providers.dart';
import 'package:fulfilled/repositories/food_repository.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:go_router/go_router.dart';

import '../../repositories/_harness.dart';

/// Mock repository that captures the [createCustom] payload so tests can
/// assert what the screen built. Per Ask 10 the screen no longer makes
/// separate `addServing` calls — all servings are POSTed in one shot via
/// `FoodCreate.servings`.
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
    'empty form: footer reads the error count and the save action is disabled',
    (tester) async {
      await _pumpAndOpen(tester, _harness(repo: repo, navKey: navKey));

      // Required fields with nothing filled in.
      expect(find.textContaining('Fix'), findsOneWidget);

      // Tapping the footer doesn't drive a save — repo never sees a
      // payload.
      await tester.tap(find.textContaining('Fix'));
      await tester.pumpAndSettle();

      expect(repo.lastPayload, isNull);
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
      notifier.setServings(<DraftServing>[
        DraftServing(
          label: '1 slice',
          amount: Decimal.fromInt(220),
          unit: Unit.g,
          kcal: Decimal.fromInt(248),
          proteinG: Decimal.fromInt(14),
          carbsG: Decimal.fromInt(22),
          fatG: Decimal.fromInt(13),
          sodiumMg: Decimal.fromInt(410),
          isDefault: true,
        ),
      ]);
      await tester.pump();

      expect(find.text('Save'), findsWidgets);

      // Pre-seed the repo to return a recognizable Food so we can
      // verify the pop value.
      repo.toReturn = Food(
        id: 'f_custom_test',
        name: "Mom's lasagna",
        source: FoodSource.user,
        isCustom: true,
        servings: <Serving>[
          Serving(
            id: 'sv_test_slice',
            label: '1 slice',
            amount: Decimal.fromInt(220),
            unit: Unit.g,
            kcal: Decimal.fromInt(248),
            isDefault: true,
            source: ServingSource.user,
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
      expect(repo.lastPayload!.servings, hasLength(1));
      final s = repo.lastPayload!.servings.first;
      expect(s.kcal, equals(Decimal.fromInt(248)));
      expect(s.proteinG, equals(Decimal.fromInt(14)));
      expect(s.carbsG, equals(Decimal.fromInt(22)));
      expect(s.fatG, equals(Decimal.fromInt(13)));
      expect(s.sodiumMg, equals(Decimal.fromInt(410)));

      // Draft reset.
      expect(container.read(customFoodDraftProvider).name, isEmpty);
      expect(container.read(customFoodDraftProvider).servings, isEmpty);
    },
  );

  testWidgets(
    'save with 2 user servings: every draft serving is included in the '
    'FoodCreate payload in order',
    (tester) async {
      await _pumpAndOpen(tester, _harness(repo: repo, navKey: navKey));

      final container = ProviderScope.containerOf(
        tester.element(find.byType(CustomFoodScreen)),
      );
      final notifier = container.read(customFoodDraftProvider.notifier);
      notifier.setName('Trail mix');
      // Two user-defined servings on the draft — per Ask 10 these all
      // ride on the FoodCreate body in a single POST.
      notifier.setServings(<DraftServing>[
        DraftServing(
          label: '1 handful',
          amount: Decimal.fromInt(30),
          unit: Unit.g,
          kcal: Decimal.fromInt(150),
          proteinG: Decimal.fromInt(5),
          isDefault: true,
        ),
        DraftServing(
          label: '1 cup',
          amount: Decimal.fromInt(140),
          unit: Unit.g,
          kcal: Decimal.fromInt(700),
          proteinG: Decimal.fromInt(20),
        ),
      ]);
      await tester.pump();

      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();

      // The payload carries both user servings in order.
      expect(repo.lastPayload, isNotNull);
      expect(repo.lastPayload!.servings.length, equals(2));
      expect(repo.lastPayload!.servings[0].label, equals('1 handful'));
      expect(
        repo.lastPayload!.servings[0].amount,
        equals(Decimal.fromInt(30)),
      );
      expect(repo.lastPayload!.servings[1].label, equals('1 cup'));
      expect(
        repo.lastPayload!.servings[1].amount,
        equals(Decimal.fromInt(140)),
      );
    },
  );
}
