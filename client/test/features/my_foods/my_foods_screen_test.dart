import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/food.dart';
import 'package:fulfilled/domain/nutrition.dart';
import 'package:fulfilled/domain/serving.dart';
import 'package:fulfilled/features/my_foods/my_foods_screen.dart';
import 'package:fulfilled/features/search/widgets/search_result_row.dart';
import 'package:fulfilled/providers/food_providers.dart';
import 'package:fulfilled/routing/routes.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:go_router/go_router.dart';

/// Widget tests for the My foods screen (T-006).
///
/// Coverage:
/// 1. Populated list renders one `SearchResultRow` per user food.
/// 2. The in-list filter narrows the visible rows case-insensitively
///    without a provider round-trip.
/// 3. The empty-state composition renders the "Create custom food" CTA
///    when the provider yields zero customs, and tapping it navigates to
///    `Routes.foodNewPath`.
/// 4. Tapping the "+" affordance in the top bar pushes
///    `Routes.foodNewPath`.

Food _userFood({required String id, required String name, int kcal = 120}) {
  return Food(
    id: id,
    name: name,
    source: FoodSource.user,
    isCustom: true,
    nutritionPer100g: NutritionPer100g(energyKcal: Decimal.fromInt(kcal)),
    servings: <Serving>[
      Serving(
        id: '${id}_s100',
        name: '1 serving (100 g)',
        grams: Decimal.fromInt(100),
        isDefault: true,
        source: ServingSource.system,
      ),
    ],
  );
}

final _customs = <Food>[
  _userFood(id: 'u_lasagna', name: "Mom's lasagna", kcal: 178),
  _userFood(id: 'u_smoothie', name: 'Home green smoothie', kcal: 62),
  _userFood(id: 'u_chili', name: "Dad's turkey chili", kcal: 103),
];

class _FakeFoodNewScreen extends StatelessWidget {
  const _FakeFoodNewScreen();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('FOOD-NEW-STUB')));
}

class _FakeFoodDetailScreen extends StatelessWidget {
  const _FakeFoodDetailScreen({required this.id});
  final String id;

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: Text('DETAIL-$id')));
}

class _FakeFoodEditScreen extends StatelessWidget {
  const _FakeFoodEditScreen({required this.id});
  final String id;

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: Text('EDIT-$id')));
}

Widget _harness({
  required List<Override> overrides,
}) {
  final router = GoRouter(
    initialLocation: Routes.myFoodsPath,
    routes: <RouteBase>[
      GoRoute(
        path: Routes.myFoodsPath,
        builder: (_, __) => Scaffold(body: const _MyFoodsHost()),
      ),
      GoRoute(
        path: Routes.foodNewPath,
        builder: (_, __) => const _FakeFoodNewScreen(),
      ),
      // Order matters: the more specific `/edit` route must come
      // before the catch-all `/:foodId`.
      GoRoute(
        path: '/foods/:foodId/edit',
        builder: (_, state) =>
            _FakeFoodEditScreen(id: state.pathParameters['foodId']!),
      ),
      GoRoute(
        path: '/foods/:foodId',
        builder: (_, state) =>
            _FakeFoodDetailScreen(id: state.pathParameters['foodId']!),
      ),
    ],
  );
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp.router(
      theme: buildLightTheme(),
      routerConfig: router,
    ),
  );
}

class _MyFoodsHost extends StatelessWidget {
  // Pure pass-through — keeps the route builder readable and matches the
  // shape `MyFoodsScreen` sees in production (mounted inside the
  // shell's `Scaffold` body slot).
  const _MyFoodsHost();

  @override
  Widget build(BuildContext context) => const MyFoodsScreen();
}

void main() {
  testWidgets('populated list renders one SearchResultRow per user food',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness(
      overrides: <Override>[
        myFoodsProvider.overrideWith((_) async => _customs),
      ],
    ));
    await tester.pumpAndSettle();

    expect(find.byType(SearchResultRow), findsNWidgets(_customs.length));
    expect(find.text("Mom's lasagna"), findsOneWidget);
    expect(find.text('Home green smoothie'), findsOneWidget);
    expect(find.text("Dad's turkey chili"), findsOneWidget);
  });

  testWidgets('filter narrows the list case-insensitively', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness(
      overrides: <Override>[
        myFoodsProvider.overrideWith((_) async => _customs),
      ],
    ));
    await tester.pumpAndSettle();

    // Type "lasagna" — should leave one row visible.
    final filter = find.byKey(const Key('my-foods-filter'));
    expect(filter, findsOneWidget);
    await tester.enterText(filter, 'LASAGNA');
    await tester.pumpAndSettle();

    expect(find.byType(SearchResultRow), findsOneWidget);
    expect(find.text("Mom's lasagna"), findsOneWidget);
    expect(find.text('Home green smoothie'), findsNothing);

    // Type something that matches none — empty "No customs match" body.
    await tester.enterText(filter, 'zzz_no_match');
    await tester.pumpAndSettle();
    expect(find.byType(SearchResultRow), findsNothing);
    expect(find.textContaining('No customs match'), findsOneWidget);
  });

  testWidgets('empty data renders the Create custom food CTA → /foods/new',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness(
      overrides: <Override>[
        myFoodsProvider.overrideWith((_) async => const <Food>[]),
      ],
    ));
    await tester.pumpAndSettle();

    expect(find.text('No custom foods yet'), findsOneWidget);
    expect(find.text('Tap + to create one'), findsOneWidget);

    final cta = find.text('Create custom food');
    expect(cta, findsOneWidget);

    await tester.tap(cta);
    await tester.pumpAndSettle();
    expect(find.text('FOOD-NEW-STUB'), findsOneWidget);
  });

  testWidgets('tapping a user-source row navigates to /foods/:id/edit',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness(
      overrides: <Override>[
        myFoodsProvider.overrideWith((_) async => _customs),
      ],
    ));
    await tester.pumpAndSettle();

    // Tap the first row — every row here is `source == user`, so the
    // tap target is the edit route, not the read-only detail.
    final rowFinder = find.byType(SearchResultRow).first;
    await tester.tap(rowFinder);
    await tester.pumpAndSettle();

    expect(find.text('EDIT-${_customs.first.id}'), findsOneWidget);
    expect(find.text('DETAIL-${_customs.first.id}'), findsNothing);
  });

  testWidgets(
    'tapping a non-user row falls back to /foods/:id (defensive guard)',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // myFoodsProvider normally only returns user-source rows, but the
      // screen has a defence-in-depth branch for non-user rows. Force
      // one through the override to exercise that branch.
      final off = Food(
        id: 'f_off_test',
        name: 'Public food',
        source: FoodSource.off,
        isCustom: false,
        nutritionPer100g: NutritionPer100g(energyKcal: Decimal.fromInt(100)),
        servings: <Serving>[
          Serving(
            id: 'sv_off_100g',
            name: '100 g',
            grams: Decimal.fromInt(100),
            isDefault: true,
            source: ServingSource.system,
          ),
        ],
      );
      await tester.pumpWidget(_harness(
        overrides: <Override>[
          myFoodsProvider.overrideWith((_) async => <Food>[off]),
        ],
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(SearchResultRow).first);
      await tester.pumpAndSettle();

      expect(find.text('DETAIL-f_off_test'), findsOneWidget);
      expect(find.text('EDIT-f_off_test'), findsNothing);
    },
  );

  testWidgets('tapping + in the top bar pushes /foods/new', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness(
      overrides: <Override>[
        myFoodsProvider.overrideWith((_) async => _customs),
      ],
    ));
    await tester.pumpAndSettle();

    // The "+" affordance is the only `Icons.add` glyph on the screen.
    final add = find.byIcon(Icons.add);
    expect(add, findsOneWidget);
    await tester.tap(add);
    await tester.pumpAndSettle();

    expect(find.text('FOOD-NEW-STUB'), findsOneWidget);
  });

  group('applyMyFoodsFilter (pure)', () {
    test('empty / whitespace query passes everything through', () {
      expect(applyMyFoodsFilter(_customs, ''), equals(_customs));
      expect(applyMyFoodsFilter(_customs, '   '), equals(_customs));
    });

    test('case-insensitive substring match on name', () {
      final hit = applyMyFoodsFilter(_customs, 'SMOOTHIE');
      expect(hit.length, equals(1));
      expect(hit.first.id, equals('u_smoothie'));
    });

    test('no matches → empty list', () {
      expect(applyMyFoodsFilter(_customs, 'zzz'), isEmpty);
    });
  });
}
