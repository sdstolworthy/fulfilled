// Quick-add row rendering inside `_EntryRow`.
//
// When a log entry's `foodId == 'food_quick_add'` the row is the synthetic
// "Quick add" affordance — its serving label is the unit "kcal", which would
// render as "kcal · 105 kcal" if we left the default meta line in place.
// `meal_section.dart` therefore special-cases the meta line: hide it for
// Quick-add rows. The title still reads "Quick add" (the food name on the
// entry) and the trailing `_KcalCell` still surfaces the numeric kcal.

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/day_summary.dart';
import 'package:fulfilled/domain/log_entry.dart';
import 'package:fulfilled/domain/meal.dart';
import 'package:fulfilled/domain/nutrition.dart';
import 'package:fulfilled/domain/unit.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/meal_section.dart';

LogEntry _quickAddEntry(int kcal) => LogEntry(
      id: 'le_qa_1',
      foodId: 'food_quick_add',
      foodName: 'Quick add',
      servingId: 'sv_kcal',
      servingName: 'kcal',
      consumedOn: DateTime(2026, 5, 14),
      meal: Meal.snack,
      quantity: Decimal.fromInt(kcal),
      enteredAmount: Decimal.fromInt(kcal),
      enteredUnit: Unit.serving,
      nutritionSnapshot:
          NutritionSnapshot(caloriesKcal: Decimal.fromInt(kcal)),
      createdAt: DateTime(2026, 5, 14, 15),
      updatedAt: DateTime(2026, 5, 14, 15),
    );

LogEntry _regularEntry() => LogEntry(
      id: 'le_reg_1',
      foodId: 'f_apple',
      foodName: 'Apple',
      servingId: 'sv_apple_medium',
      servingName: '1 medium (182 g)',
      consumedOn: DateTime(2026, 5, 14),
      meal: Meal.snack,
      quantity: Decimal.one,
      enteredAmount: Decimal.fromInt(182),
      enteredUnit: Unit.g,
      nutritionSnapshot:
          NutritionSnapshot(caloriesKcal: Decimal.fromInt(95)),
      createdAt: DateTime(2026, 5, 14, 15),
      updatedAt: DateTime(2026, 5, 14, 15),
    );

MealSubtotal _subtotal() => MealSubtotal(
      meal: Meal.snack,
      kcal: Decimal.fromInt(105),
      proteinG: Decimal.zero,
      carbsG: Decimal.zero,
      fatG: Decimal.zero,
      entryCount: 1,
    );

Widget _harness({required LogEntry entry}) {
  return MaterialApp(
    theme: buildLightTheme(),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 360,
          child: MealSection(
            subtotal: _subtotal(),
            entries: <LogEntry>[entry],
            onAddTap: () {},
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'Quick-add row title shows "Quick add" and no "kcal" meta qualifier',
    (tester) async {
      await tester.pumpWidget(_harness(entry: _quickAddEntry(105)));
      await tester.pump();

      // Title.
      expect(find.text('Quick add'), findsOneWidget);

      // The kcal cell renders the numeric. `formatKcal(105)` → '105'.
      expect(find.text('105'), findsOneWidget);

      // The meta line is hidden: there must be no Text child rendering
      // the serving label "kcal". (The unit label inside `_KcalCell` is
      // "KCAL" all-caps, so "kcal" lowercase would only appear if the
      // meta line wasn't suppressed.)
      expect(find.text('kcal'), findsNothing);
    },
  );

  testWidgets(
    'Regular row keeps its serving meta line (regression check)',
    (tester) async {
      await tester.pumpWidget(_harness(entry: _regularEntry()));
      await tester.pump();

      expect(find.text('Apple'), findsOneWidget);
      // The meta line still surfaces the serving label.
      expect(find.text('1 medium (182 g)'), findsOneWidget);
    },
  );
}
