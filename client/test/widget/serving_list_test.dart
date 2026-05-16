import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/nutrition.dart';
import 'package:fulfilled/domain/serving.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/serving_list.dart';

/// T-002 — `ServingList` canonical widget (read-only variant).
///
/// Acceptance criteria:
/// - The synthetic 100 g serving always renders with a `Synthetic` badge
///   (T-10).
/// - Tapping a row emits `onSelect(id)`.
/// - `selectedId` controls the selected visual.
Widget _harness(Widget child) {
  return MaterialApp(
    theme: buildLightTheme(),
    home: Scaffold(body: child),
  );
}

Serving _synthetic() => Serving(
      id: 'sv_100g',
      name: '100 g',
      grams: Decimal.fromInt(100),
      isDefault: false,
      source: ServingSource.system,
      sortOrder: 0,
    );

Serving _named({required String id, required String name, required int g}) =>
    Serving(
      id: id,
      name: name,
      grams: Decimal.fromInt(g),
      isDefault: false,
      source: ServingSource.off,
      sortOrder: 1,
    );

NutritionPer100g _nutrition() => NutritionPer100g(
      energyKcal: Decimal.fromInt(100),
      proteinG: Decimal.fromInt(10),
      carbsG: Decimal.fromInt(20),
      fatG: Decimal.zero,
    );

void main() {
  testWidgets('synthetic 100 g serving always renders with the badge',
      (tester) async {
    await tester.pumpWidget(
      _harness(
        ServingList(
          servings: <Serving>[_synthetic()],
          nutritionPer100g: _nutrition(),
        ),
      ),
    );

    expect(find.text('100 g'), findsOneWidget);
    expect(find.text('SYNTHETIC'), findsOneWidget);
  });

  testWidgets('synthetic + named servings both render', (tester) async {
    await tester.pumpWidget(
      _harness(
        ServingList(
          servings: <Serving>[
            _synthetic(),
            _named(id: 'sv_container', name: '1 container', g: 170),
          ],
          nutritionPer100g: _nutrition(),
        ),
      ),
    );

    expect(find.text('100 g'), findsOneWidget);
    expect(find.text('1 container'), findsOneWidget);
    expect(find.text('SYNTHETIC'), findsOneWidget);
  });

  testWidgets('tapping a row emits onSelect(id)', (tester) async {
    String? captured;
    await tester.pumpWidget(
      _harness(
        ServingList(
          servings: <Serving>[
            _synthetic(),
            _named(id: 'sv_container', name: '1 container', g: 170),
          ],
          nutritionPer100g: _nutrition(),
          onSelect: (id) => captured = id,
        ),
      ),
    );

    await tester.tap(find.text('1 container'));
    await tester.pump();
    expect(captured, equals('sv_container'));
  });

  testWidgets('selectedId paints the row with the accentSoft fill',
      (tester) async {
    final handle = tester.ensureSemantics();
    addTearDown(handle.dispose);

    await tester.pumpWidget(
      _harness(
        ServingList(
          servings: <Serving>[
            _synthetic(),
            _named(id: 'sv_container', name: '1 container', g: 170),
          ],
          nutritionPer100g: _nutrition(),
          selectedId: 'sv_container',
          onSelect: (_) {},
        ),
      ),
    );

    // The selected row registers as a selected button in the semantics.
    final semantics = tester.getSemantics(find.bySemanticsLabel('1 container'));
    expect(semantics.hasFlag(SemanticsFlag.isSelected), isTrue);
  });

  testWidgets('with no onSelect the row has no InkWell (non-interactive)',
      (tester) async {
    await tester.pumpWidget(
      _harness(
        ServingList(
          servings: <Serving>[_synthetic()],
          nutritionPer100g: _nutrition(),
        ),
      ),
    );

    // Without `onSelect` the row should not be wrapped in an InkWell —
    // the read-only food-detail screen relies on this absence so the
    // synthetic row isn't tappable.
    expect(find.byType(InkWell), findsNothing);
  });
}
