import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/day_summary.dart';
import 'package:fulfilled/domain/meal.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/ring_summary_card.dart';

/// Widget tests for the expanded `RingSummaryCard`'s "Burned" row
/// (T-020 / B8). Under the passive-view rule (testing_guide.md §4.4)
/// the row no longer reads providers itself — the value is threaded in
/// via the `burnedKcal` constructor parameter and rendered directly.
/// `null` is the silent `'—'` fallback (covers loading + error in the
/// container).
///
/// All tests pin `compact: false` so the "Burned" row is in scope —
/// the compact variant intentionally omits it. No `ProviderScope` is
/// needed: the leaf is a pure presentation widget.

DaySummary _summary() {
  return DaySummary(
    date: DateTime(2026, 5, 16),
    kcal: Decimal.fromInt(1288),
    protein: Decimal.fromInt(58),
    carbs: Decimal.fromInt(110),
    fat: Decimal.fromInt(50),
    kcalTarget: Decimal.fromInt(2100),
    proteinTarget: Decimal.fromInt(130),
    carbsTarget: Decimal.fromInt(263),
    fatTarget: Decimal.fromInt(70),
    byMeal: <Meal, MealSubtotal>{
      for (final m in Meal.values) m: MealSubtotal.empty(m),
    },
  );
}

Widget _harness({required Decimal? burnedKcal}) {
  return MaterialApp(
    theme: buildLightTheme(),
    home: Scaffold(
      body: SingleChildScrollView(
        child: RingSummaryCard(
          summary: _summary(),
          compact: false,
          burnedKcal: burnedKcal,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'Burned row renders formatted kcal when burnedKcal is non-null',
    (tester) async {
      // The leaf renders whatever the container resolved. Pin a
      // representative TDEE-shaped value and assert the suffix format.
      await tester.pumpWidget(
        _harness(burnedKcal: Decimal.fromInt(2734)),
      );
      await tester.pump();

      expect(find.text('Burned'), findsOneWidget);
      // No fallback dash on the Burned line — the value resolved.
      // (The Eaten / Goal rows also render values; finding any "—"
      // in the card would only happen if no burnedKcal were threaded.)
      expect(find.text('—'), findsNothing);
      // The value is "${formatKcal(kcal)} kcal" — every kv-row value
      // ends with the kcal suffix, so a "kcal" textContaining find
      // surfaces the Burned row alongside Eaten / Goal. We assert
      // three matches: Eaten, Goal, and Burned.
      expect(find.textContaining('kcal'), findsNWidgets(3));
    },
  );

  testWidgets(
    'Burned row silently falls back to — when burnedKcal is null',
    (tester) async {
      // `null` covers both the upstream-loading and upstream-error
      // branches in the container — the container resolves the
      // provider, and either passes the resolved value or null. The
      // leaf renders `—` for both, by design.
      await tester.pumpWidget(_harness(burnedKcal: null));
      await tester.pump();

      expect(find.text('Burned'), findsOneWidget);
      // Exactly one `—` in the card — the Burned row's silent
      // fallback. (Eaten / Goal both render values: `_summary()`
      // pins both `kcal` and `kcalTarget`.)
      expect(find.text('—'), findsOneWidget);
    },
  );
}
