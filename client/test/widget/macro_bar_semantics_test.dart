import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/macro_bar.dart';

/// T-022 / T-20 — `MacroBar` Semantics audit.
///
/// The architect's contract for the over-budget label is that color is
/// never the sole signal — when `value > target` the Semantics label
/// carries a natural-language `"over by N grams"` suffix so a screen
/// reader announces the over-budget state. These tests pump a single
/// `MacroBar` and assert against the composed Semantics tree.
///
/// **Not run against an analyzer** — this file ships under T-022 as a
/// stub the agent didn't execute. The harness is the standard
/// `ensureSemantics` + `find.bySemanticsLabel` pattern other widget tests
/// in this folder use (see `number_text_test.dart`).
Widget _harness(Widget child) {
  return MaterialApp(
    theme: buildLightTheme(),
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: child,
      ),
    ),
  );
}

void main() {
  testWidgets('over-budget bar announces "over by N grams"', (tester) async {
    final handle = tester.ensureSemantics();
    addTearDown(handle.dispose);

    await tester.pumpWidget(
      _harness(
        MacroBar(
          kind: MacroKind.protein,
          value: Decimal.fromInt(60),
          target: Decimal.fromInt(50),
        ),
      ),
    );

    // The acceptance criterion: 60 g protein vs 50 g target → label
    // includes "over by 10 grams". The leading phrase
    // ("Protein 60 grams of 50 grams") is also part of the label, so we
    // assert substring containment via a regex.
    final node = tester
        .getSemantics(find.bySemanticsLabel(RegExp(r'over by 10 grams')));
    expect(node, isNotNull);
  });

  testWidgets('on-budget bar omits the over suffix', (tester) async {
    final handle = tester.ensureSemantics();
    addTearDown(handle.dispose);

    await tester.pumpWidget(
      _harness(
        MacroBar(
          kind: MacroKind.protein,
          value: Decimal.fromInt(40),
          target: Decimal.fromInt(50),
        ),
      ),
    );

    expect(find.bySemanticsLabel(RegExp(r'over by')), findsNothing);
    // The composed label still announces the value-of-target phrasing
    // (40 grams of 50 grams) so the screen-reader user has the number
    // even without the over qualifier.
    expect(
      find.bySemanticsLabel(RegExp(r'40 grams of 50 grams')),
      findsOneWidget,
    );
  });

  testWidgets('no target — bar announces value alone', (tester) async {
    final handle = tester.ensureSemantics();
    addTearDown(handle.dispose);

    await tester.pumpWidget(
      _harness(
        MacroBar(
          kind: MacroKind.carbs,
          value: Decimal.fromInt(120),
          target: null,
        ),
      ),
    );

    // No target → no "of N grams" suffix. The bar still announces the
    // value with its unit.
    expect(
      find.bySemanticsLabel(RegExp(r'Carbs 120 grams$')),
      findsOneWidget,
    );
  });
}
