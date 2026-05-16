import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/food.dart';
import 'package:fulfilled/domain/nutrition.dart';
import 'package:fulfilled/domain/serving.dart';
import 'package:fulfilled/features/food_detail/food_detail_screen.dart';
import 'package:fulfilled/providers/food_providers.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/empty_state.dart';
import 'package:fulfilled/widgets/skeleton.dart';

/// Widget tests for the food detail screen.
///
/// Covers the contract the architect asked us to nail:
///
/// 1. Smoke — renders without crashing with a mocked
///    `foodDetailProvider`.
/// 2. T-10 — the synthetic 100 g serving carries a `Synthetic` badge.
/// 3. T-21 — sodium renders as `"36 mg"`, not the raw decimal grams that
///    arrive on the wire.
/// 4. T-13 — loading state uses `Skeleton`, never `CircularProgressIndicator`.
/// 5. T-11 + T-13 — error state renders an `EmptyState`, not a spinner
///    or a bare text label.

void main() {
  testWidgets('renders successfully with a mocked foodDetailProvider',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness(food: _yogurt()));
    await tester.pump();

    // Hero title, source label in eyebrow, per-100 g header all paint.
    expect(find.text(_yogurt().name), findsOneWidget);
    expect(find.textContaining('OpenFoodFacts'), findsOneWidget);
    expect(find.text('Per 100 g'), findsOneWidget);
    // PM §10 #10 (T-011): quality score is no longer rendered. The
    // nutrition meta shows just the source label.
    expect(find.text('OFF data'), findsOneWidget);
    expect(find.textContaining('quality'), findsNothing);
    expect(find.textContaining('0.86'), findsNothing);
  });

  testWidgets('synthetic 100 g serving row shows the Synthetic badge',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness(food: _yogurt()));
    await tester.pump();

    // The badge is uppercased in the UI (`Synthetic` → `SYNTHETIC`).
    expect(find.text('SYNTHETIC'), findsOneWidget);
    // And the default serving keeps its own badge too — sanity.
    expect(find.text('DEFAULT'), findsOneWidget);
  });

  testWidgets('sodium renders as "36 mg" — not raw decimal grams',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness(food: _yogurt()));
    await tester.pump();

    // The fixture below stores sodium as 36 mg on the presentation model
    // (i.e. the repository has already converted the wire's 0.036 g →
    // 36 mg). `formatSodiumMg` rounds to integer mg and the row appends
    // ` mg`.
    expect(find.text('36 mg'), findsOneWidget);
    // Defensive: make sure we never render the wire-shaped grams figure.
    expect(find.textContaining('0.036'), findsNothing);
    expect(find.textContaining('0.036 g'), findsNothing);
  });

  testWidgets('loading state renders Skeleton, never CircularProgressIndicator',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // Override the provider with a never-completing future so the screen
    // stays parked in the loading branch through the test.
    final completer = Completer<Food>();
    addTearDown(() {
      if (!completer.isCompleted) completer.complete(_yogurt());
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          foodDetailProvider('f_test_loading')
              .overrideWith((_) => completer.future),
        ],
        child: MaterialApp(
          theme: buildLightTheme(),
          home: const FoodDetailScreen(foodId: 'f_test_loading'),
        ),
      ),
    );
    // A single pump catches the very first frame — no `pumpAndSettle`
    // because the completer never fires.
    await tester.pump();

    // T-013 acceptance — no spinner in the loading branch.
    expect(find.byType(CircularProgressIndicator), findsNothing);
    // T-08 — the layout-matching Skeleton is what the user sees instead.
    expect(find.byType(Skeleton), findsWidgets);
  });

  testWidgets(
      'error branch renders the lifted EmptyState (not a spinner / bare text)',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          foodDetailProvider('f_test_err')
              .overrideWith((_) async => throw Exception('boom')),
        ],
        child: MaterialApp(
          theme: buildLightTheme(),
          home: const FoodDetailScreen(foodId: 'f_test_err'),
        ),
      ),
    );
    await tester.pump(); // resolve the error microtask.
    await tester.pump(); // flush the listen-shim post-frame.

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.text("Couldn't load food details"), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}

// ---------------------------------------------------------------------------
// Fixtures + harness.
// ---------------------------------------------------------------------------

/// Mirrors the OFF yogurt in the mock (`screen_03_food_detail.html`) — same
/// servings, same per-100 g numbers, same quality score. Keeps the test
/// readable from the spec.
Food _yogurt() {
  return Food(
    id: 'f_greek_yogurt_plain',
    name: 'Greek yogurt, plain, nonfat (Total 0%)',
    brand: 'Fage',
    barcode: '0040000123456',
    source: FoodSource.off,
    isCustom: false,
    qualityScore: 86,
    nutritionPer100g: NutritionPer100g(
      energyKcal: Decimal.parse('57'),
      proteinG: Decimal.parse('10.3'),
      carbsG: Decimal.parse('3.6'),
      sugarG: Decimal.parse('3.2'),
      fatG: Decimal.parse('0.2'),
      saturatedFatG: Decimal.parse('0.1'),
      fiberG: Decimal.parse('0.0'),
      sodiumMg: Decimal.parse('36'),
    ),
    servings: <Serving>[
      Serving(
        id: 's_cup',
        name: '1 cup',
        grams: Decimal.parse('227'),
        isDefault: true,
        source: ServingSource.off,
        sortOrder: 0,
      ),
      Serving(
        id: 's_container',
        name: '5.3 oz container',
        grams: Decimal.parse('150'),
        isDefault: false,
        source: ServingSource.off,
        sortOrder: 1,
      ),
      Serving(
        id: 's_half_cup',
        name: '½ cup',
        grams: Decimal.parse('113'),
        isDefault: false,
        source: ServingSource.off,
        sortOrder: 2,
      ),
      Serving(
        id: 's_100g',
        name: '100 g',
        grams: Decimal.fromInt(100),
        isDefault: false,
        source: ServingSource.system,
        sortOrder: 99,
      ),
    ],
  );
}

Widget _harness({required Food food}) {
  return ProviderScope(
    overrides: <Override>[
      foodDetailProvider(food.id)
          .overrideWith((_) async => food),
    ],
    child: MaterialApp(
      theme: buildLightTheme(),
      home: FoodDetailScreen(
        foodId: food.id,
        showLogEntrySheetOverride: (_, {required Food food}) {},
      ),
    ),
  );
}
