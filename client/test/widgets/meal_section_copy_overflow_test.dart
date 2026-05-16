// UX-106 F1 — Per-meal copy-day overflow on `MealSection` header.
//
// `MealSection`'s `_Header` renders a trailing 36-px `IconButton36`
// overflow icon (`Icons.more_horiz_outlined`) when the constructor
// receives a non-null `onCopyMeal` callback. Tapping the icon opens a
// `showMenu` with a single "Copy <Meal> from…" item; selecting that
// item invokes `onCopyMeal(meal)` with the section's meal. When
// `onCopyMeal` is null the icon is not rendered (back-compat for the
// existing test fixtures that don't opt in).
//
// Architect §3.4 (A) deep dive; ticket UX-106 §Tests.

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/day_summary.dart';
import 'package:fulfilled/domain/log_entry.dart';
import 'package:fulfilled/domain/meal.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/meal_section.dart';

MealSubtotal _subtotal(Meal meal) => MealSubtotal(
      meal: meal,
      kcal: Decimal.fromInt(420),
      proteinG: Decimal.fromInt(20),
      carbsG: Decimal.fromInt(50),
      fatG: Decimal.fromInt(10),
      entryCount: 1,
    );

Widget _harness({
  required Meal meal,
  void Function(Meal)? onCopyMeal,
  bool Function(Meal)? canCopyMeal,
}) {
  return MaterialApp(
    theme: buildLightTheme(),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 400,
          child: MealSection(
            subtotal: _subtotal(meal),
            entries: const <LogEntry>[],
            onAddTap: () {},
            onCopyMeal: onCopyMeal,
            canCopyMeal: canCopyMeal,
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'overflow icon hidden when onCopyMeal is null',
    (tester) async {
      await tester.pumpWidget(_harness(meal: Meal.breakfast));
      await tester.pump();

      expect(find.byIcon(Icons.more_horiz_outlined), findsNothing);
    },
  );

  testWidgets(
    'overflow icon visible when onCopyMeal is non-null',
    (tester) async {
      await tester.pumpWidget(_harness(
        meal: Meal.breakfast,
        onCopyMeal: (_) {},
      ));
      await tester.pump();

      expect(find.byIcon(Icons.more_horiz_outlined), findsOneWidget);
      // The icon carries the per-meal tooltip (T-20).
      expect(
        find.byTooltip('Copy Breakfast from…'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'tapping the overflow opens a menu with "Copy <Meal> from…"',
    (tester) async {
      await tester.pumpWidget(_harness(
        meal: Meal.lunch,
        onCopyMeal: (_) {},
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_horiz_outlined));
      await tester.pumpAndSettle();

      expect(find.text('Copy Lunch from…'), findsOneWidget);
    },
  );

  testWidgets(
    'selecting the menu item invokes onCopyMeal with the sections meal',
    (tester) async {
      Meal? captured;
      await tester.pumpWidget(_harness(
        meal: Meal.dinner,
        onCopyMeal: (m) => captured = m,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_horiz_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy Dinner from…'));
      await tester.pumpAndSettle();

      expect(captured, equals(Meal.dinner));
    },
  );

  testWidgets(
    'canCopyMeal=false greys the icon but the affordance still fires',
    (tester) async {
      Meal? captured;
      await tester.pumpWidget(_harness(
        meal: Meal.snack,
        onCopyMeal: (m) => captured = m,
        canCopyMeal: (_) => false,
      ));
      await tester.pumpAndSettle();

      // The icon is still rendered (architect §3.4 (A): icon stays
      // visible; the deferred predicate only flips the *colour*).
      expect(find.byIcon(Icons.more_horiz_outlined), findsOneWidget);

      // Open the menu + select the item — the sheet's empty-source
      // state is the fallback UX per UX-106's deferred-predicate note.
      await tester.tap(find.byIcon(Icons.more_horiz_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy Snack from…'));
      await tester.pumpAndSettle();

      expect(captured, equals(Meal.snack));
    },
  );
}

