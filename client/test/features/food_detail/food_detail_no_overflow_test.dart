import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/food.dart';
import 'package:fulfilled/domain/unit.dart';
import 'package:fulfilled/features/food_detail/food_detail_screen.dart';
import 'package:fulfilled/providers/food_providers.dart';
import 'package:fulfilled/theme/theme_data.dart';

import '../../_fixtures.dart';

/// UX-111 (Theme C dead-affordance sweep) — regression.
///
/// The `more_horiz` overflow `IconButton` on the food detail app bar
/// (formerly `onPressed: () {}`) is deleted. No surface of this screen
/// should mount that icon. The test pumps the screen at both compact
/// and expanded form factors because the deleted affordance lived on
/// the compact branch (where `showAddToLog == false`).
///
/// Tenants: T-20 (no false affordances — every visible button has a
/// real action).
void main() {
  testWidgets('food detail screen has no more_horiz overflow at compact size',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness(food: _yogurt()));
    await tester.pump();

    expect(
      find.byIcon(Icons.more_horiz),
      findsNothing,
      reason: 'UX-111: the no-op `more_horiz` overflow on the food '
          'detail app bar must not be reintroduced. The PR cut it as '
          'part of the Theme C dead-affordance sweep.',
    );
  });

  testWidgets('food detail screen has no more_horiz overflow at expanded size',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness(food: _yogurt()));
    await tester.pump();

    expect(
      find.byIcon(Icons.more_horiz),
      findsNothing,
      reason: 'UX-111: the `more_horiz` overflow must remain absent '
          'on the expanded form factor too — neither branch of the '
          'AppBar should reintroduce it.',
    );
  });
}

Food _yogurt() => buildFood(
      id: 'f_greek_yogurt_plain',
      name: 'Greek yogurt, plain, nonfat (Total 0%)',
      brand: 'Fage',
      barcode: '0040000123456',
      qualityScore: 86,
      servings: [
        buildServing(
          id: 's_cup',
          label: '1 cup',
          amount: Decimal.parse('1'),
          unit: Unit.cup,
          kcal: Decimal.parse('129'),
          proteinG: Decimal.parse('23.4'),
          carbsG: Decimal.parse('8.2'),
          sugarG: Decimal.parse('7.3'),
          fatG: Decimal.parse('0.5'),
          saturatedFatG: Decimal.parse('0.2'),
          fiberG: Decimal.parse('0.0'),
          sodiumMg: Decimal.parse('82'),
          source: ServingSource.off,
        ),
      ],
    );

Widget _harness({required Food food}) {
  return ProviderScope(
    overrides: <Override>[
      foodDetailProvider(food.id).overrideWith((_) async => food),
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
