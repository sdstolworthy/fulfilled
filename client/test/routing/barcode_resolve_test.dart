import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/food.dart';
import 'package:fulfilled/domain/nutrition.dart';
import 'package:fulfilled/domain/serving.dart';
import 'package:fulfilled/repositories/food_repository.dart';
import 'package:fulfilled/routing/app_router.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:go_router/go_router.dart';

import '../repositories/_harness.dart';

/// T-021 — `/foods/barcode/:barcode` resolver.
///
/// The resolver runs `FoodRepository.byBarcode` and `pushReplacement`s
/// to either `/foods/:id` on a hit or `/foods/new?barcode=:value` on a
/// 404. These tests mount the real router with a stubbed repository so
/// the assertions cover both branches end-to-end.

/// Stub repository that lets each test pick the byBarcode response.
class _StubFoodRepository extends FoodRepository {
  _StubFoodRepository(super.api, {this.byBarcodeResult});

  /// Either a `Food` (success path) or a `FoodNotFoundError` (404 path).
  /// `null` keeps the seed-list behavior — used by tests that don't
  /// care about the resolver itself.
  final Object? byBarcodeResult;

  @override
  Future<Food> byBarcode(String barcode) async {
    final res = byBarcodeResult;
    if (res is Food) return res;
    if (res is FoodNotFoundError) throw res;
    return super.byBarcode(barcode);
  }
}

Food _seedFood(String id) => Food(
      id: id,
      name: 'Stubbed food',
      source: FoodSource.off,
      isCustom: false,
      nutritionPer100g: NutritionPer100g(energyKcal: Decimal.fromInt(100)),
      servings: <Serving>[
        Serving(
          id: '${id}_100g',
          name: '100 g',
          grams: Decimal.fromInt(100),
          isDefault: true,
          source: ServingSource.system,
        ),
      ],
    );

Widget _routerHarness(_StubFoodRepository repo) {
  return ProviderScope(
    overrides: <Override>[
      foodRepositoryProvider.overrideWithValue(repo),
    ],
    child: Consumer(
      builder: (context, ref, _) {
        final router = ref.watch(appRouterProvider);
        return MaterialApp.router(
          theme: buildLightTheme(),
          routerConfig: router,
        );
      },
    ),
  );
}

Future<void> _pumpAndGoTo(
  WidgetTester tester,
  Widget app,
  String location,
) async {
  // Compact-sized viewport keeps the shell predictable; the resolver
  // screen itself is breakpoint-agnostic.
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(app);
  await tester.pumpAndSettle();

  // Drive the router to the resolver via the in-tree GoRouter.
  final routerContext = tester.element(find.byType(MaterialApp));
  GoRouter.of(routerContext).go(location);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    resetRepositoriesForTest();
  });
  tearDown(teardownRepositoriesForTest);

  testWidgets('byBarcode hit → pushReplacement /foods/:id', (tester) async {
    final food = _seedFood('f_stub_hit');
    final repo = _StubFoodRepository(
      buildTestApiClient(),
      byBarcodeResult: food,
    );

    await _pumpAndGoTo(
      tester,
      _routerHarness(repo),
      '/foods/barcode/12345678',
    );

    // Resolver fires a post-frame `pushReplacement` to /foods/:id.
    // Food detail then loads via `foodDetailProvider`, which we haven't
    // overridden — the screen will show its loading/error chrome, but
    // the router location is what we're asserting.
    final routerContext = tester.element(find.byType(MaterialApp));
    final location =
        GoRouter.of(routerContext).routerDelegate.currentConfiguration.uri.path;
    expect(location, '/foods/${food.id}');
  });

  testWidgets('byBarcode 404 → pushReplacement /foods/new?barcode=…',
      (tester) async {
    final repo = _StubFoodRepository(
      buildTestApiClient(),
      byBarcodeResult: FoodNotFoundError('00000000'),
    );

    await _pumpAndGoTo(
      tester,
      _routerHarness(repo),
      '/foods/barcode/00000000',
    );

    final routerContext = tester.element(find.byType(MaterialApp));
    final uri =
        GoRouter.of(routerContext).routerDelegate.currentConfiguration.uri;
    expect(uri.path, '/foods/new');
    expect(uri.queryParameters['barcode'], '00000000');
  });

  testWidgets('404 path prefills the custom-food draft barcode field',
      (tester) async {
    final repo = _StubFoodRepository(
      buildTestApiClient(),
      byBarcodeResult: FoodNotFoundError('00000000'),
    );

    await _pumpAndGoTo(
      tester,
      _routerHarness(repo),
      '/foods/barcode/00000000',
    );

    // After the resolver lands on /foods/new?barcode=00000000 the
    // custom-food form prefills the barcode field on its first frame.
    // We assert by finding the `EditableText` whose value equals the
    // barcode (the screen uses an internal `_TextField` that wraps a
    // Material `TextField`).
    expect(
      find.byWidgetPredicate(
        (w) => w is EditableText && w.controller.text == '00000000',
      ),
      findsOneWidget,
    );
  });
}
