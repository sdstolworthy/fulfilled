import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/serving.dart';
import 'package:fulfilled/domain/unit.dart';
import 'package:fulfilled/features/food_detail/widgets/nutrition_table.dart';
import 'package:fulfilled/theme/theme_data.dart';

/// PM §10 #10 (T-011) — the food detail nutrition meta renders just the
/// source label. The numeric quality score is hidden in v1; the DTO
/// field stays on the wire for v2 sorting / debug.
///
/// One test per source. Each asserts:
///   - The expected source label appears.
///   - No `"quality"` substring leaks (defensive against accidental
///     re-introduction).
///   - No `"0."` numeric prefix appears in the meta line.

void main() {
  group('NutritionTable source-only meta', () {
    testWidgets('FoodSource.off renders "OFF data" — no quality number',
        (tester) async {
      await tester.pumpWidget(_harness(
        source: FoodSource.off,
        qualityScore: 86,
      ),);

      expect(find.text('OFF data'), findsOneWidget);
      expect(find.textContaining('quality'), findsNothing);
      expect(find.textContaining('0.86'), findsNothing);
    });

    testWidgets('FoodSource.usda renders "USDA data"', (tester) async {
      await tester.pumpWidget(_harness(
        source: FoodSource.usda,
        qualityScore: 92,
      ),);

      expect(find.text('USDA data'), findsOneWidget);
      expect(find.textContaining('quality'), findsNothing);
      expect(find.textContaining('0.92'), findsNothing);
    });

    testWidgets('FoodSource.user renders "Your food"', (tester) async {
      await tester.pumpWidget(_harness(
        source: FoodSource.user,
        qualityScore: null,
      ),);

      expect(find.text('Your food'), findsOneWidget);
      expect(find.textContaining('quality'), findsNothing);
    });

    testWidgets('quality score on the DTO is still accepted (param '
        'tolerated, intentionally not rendered)', (tester) async {
      // Belt-and-braces: even when the caller passes the wire value,
      // the panel renders only the source label.
      await tester.pumpWidget(_harness(
        source: FoodSource.off,
        qualityScore: 99,
      ),);

      expect(find.text('OFF data'), findsOneWidget);
      expect(find.textContaining('0.99'), findsNothing);
      expect(find.textContaining('quality 0.99'), findsNothing);
    });
  });
}

Widget _harness({required FoodSource source, required int? qualityScore}) {
  return MaterialApp(
    theme: buildLightTheme(),
    home: Scaffold(
      body: NutritionTable(
        serving: _serving(),
        source: source,
        qualityScore: qualityScore,
      ),
    ),
  );
}

Serving _serving() {
  return Serving(
    id: 'sv_100g',
    label: '100 g',
    amount: Decimal.fromInt(100),
    unit: Unit.g,
    kcal: Decimal.parse('57'),
    proteinG: Decimal.parse('10.3'),
    carbsG: Decimal.parse('3.6'),
    sugarG: Decimal.parse('3.2'),
    fatG: Decimal.parse('0.2'),
    saturatedFatG: Decimal.parse('0.1'),
    fiberG: Decimal.parse('0.0'),
    sodiumMg: Decimal.parse('36'),
    isDefault: true,
    source: ServingSource.off,
  );
}
