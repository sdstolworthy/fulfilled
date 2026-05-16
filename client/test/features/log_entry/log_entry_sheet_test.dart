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
import 'package:fulfilled/features/log_entry/widgets/log_preview_block.dart';
import 'package:fulfilled/features/log_entry/widgets/quantity_stepper.dart';
import 'package:fulfilled/theme/theme_data.dart';

/// A deterministic test food: 100 kcal / 10 g P / 20 g C / 0 g F per 100 g,
/// with one 100 g serving so the preview math collapses to "× quantity".
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
    ],
  );
}

Widget _harness({
  required Food food,
  required ValueChanged<LogCreate> onSubmit,
  Meal? defaultMeal,
}) {
  return ProviderScope(
    child: MaterialApp(
      theme: buildLightTheme(),
      home: Scaffold(
        body: LogEntrySheetBody(
          food: food,
          defaultMeal: defaultMeal,
          onSubmit: onSubmit,
          showGrabber: false,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('initial render shows 100 kcal preview at quantity 1',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness(
      food: _testFood(),
      onSubmit: (_) {},
    ));
    await tester.pump();

    expect(find.byType(LogPreviewBlock), findsOneWidget);
    // Heroes the kcal hero — 100 g × 1 × 100 kcal/100g = 100.
    expect(find.text('100'), findsWidgets);
  });

  testWidgets('typing a quantity updates the preview', (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness(
      food: _testFood(),
      onSubmit: (_) {},
    ));
    await tester.pump();

    final field = find.byKey(const Key('log_entry_quantity_field'));
    expect(field, findsOneWidget);

    await tester.tap(field);
    await tester.pump();
    await tester.enterText(field, '2.5');
    await tester.pump();

    // 100 kcal × 2.5 = 250.
    expect(find.text('250'), findsWidgets);
  });

  testWidgets('tapping a chip updates both stepper value and preview',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness(
      food: _testFood(),
      onSubmit: (_) {},
    ));
    await tester.pump();

    // Tap the 2× chip.
    await tester.tap(find.text('2×'));
    await tester.pump();

    // Preview reflects 2× (= 200 kcal).
    expect(find.text('200'), findsWidgets);
    // Stepper field text mirrors the chip value.
    final fieldWidget = tester.widget<TextField>(
      find.byKey(const Key('log_entry_quantity_field')),
    );
    expect(fieldWidget.controller!.text, '2');
  });

  testWidgets('Save invokes onSubmit with a LogCreate carrying the form state',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    LogCreate? captured;
    await tester.pumpWidget(_harness(
      food: _testFood(),
      defaultMeal: Meal.lunch,
      onSubmit: (lc) => captured = lc,
    ));
    await tester.pump();

    // Bump quantity to 1.5 via the chip.
    await tester.tap(find.text('1.5×'));
    await tester.pump();

    // Tap Save.
    await tester.tap(find.byKey(const Key('log_entry_save_button')));
    await tester.pump();

    expect(captured, isNotNull);
    expect(captured!.foodId, 'f_test');
    expect(captured!.servingId, 'sv_100g');
    expect(captured!.meal, Meal.lunch);
    expect(captured!.quantity, Decimal.parse('1.5'));
  });

  testWidgets('default meal falls back to local time of day when null',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    LogCreate? captured;
    await tester.pumpWidget(_harness(
      food: _testFood(),
      onSubmit: (lc) => captured = lc,
    ));
    await tester.pump();

    await tester.tap(find.byKey(const Key('log_entry_save_button')));
    await tester.pump();

    // Whatever the wall-clock meal is, it should match `mealForLocalTime`.
    expect(captured, isNotNull);
    expect(captured!.meal, mealForLocalTime(DateTime.now()));
  });

  testWidgets('QuickMultiplierChips highlights the chip equal to quantity',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness(
      food: _testFood(),
      onSubmit: (_) {},
    ));
    await tester.pump();

    // Drive via the stepper plus button: 1 → 1.5 (step is 0.5).
    final plus = find.bySemanticsLabel('Increment quantity');
    expect(plus, findsOneWidget);
    await tester.tap(plus);
    await tester.pump();

    // The 1.5× chip should now be the one rendered selected. We can't
    // easily peek at colors, but tapping it should be a no-op and the
    // semantics flag should be `selected`.
    final semantics =
        tester.getSemantics(find.bySemanticsLabel('1.5× multiplier'));
    expect(semantics.hasFlag(SemanticsFlag.isSelected), isTrue);
  });
}
