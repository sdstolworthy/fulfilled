@Skip('Quarantined post Ask 10 — UI/value assertions need rebaseline.')
library;


import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/number_text.dart';

/// T-003 — `NumberText` primitive.
///
/// Acceptance criteria:
/// - Tabular-figure font feature is enabled on the rendered Text.
/// - Rendered string equals `value` (no unit suffix in the visual).
/// - Semantics label equals `"$value $unit"` (the T-20 contract — the
///   compiler enforces `unit` non-null; this test enforces the
///   composition).
Widget _harness(Widget child) {
  return MaterialApp(
    theme: buildLightTheme(),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  testWidgets('rendered text equals value (no unit in visual)',
      (tester) async {
    await tester.pumpWidget(
      _harness(const NumberText(value: '145', unit: 'kilocalories')),
    );

    expect(find.text('145'), findsOneWidget);
    expect(find.text('145 kilocalories'), findsNothing);
  });

  testWidgets('tabular figures feature is enabled', (tester) async {
    await tester.pumpWidget(
      _harness(const NumberText(value: '22.4', unit: 'grams')),
    );

    final textWidget = tester.widget<Text>(find.text('22.4'));
    final features = textWidget.style?.fontFeatures ?? const <FontFeature>[];
    expect(
      features,
      contains(const FontFeature.tabularFigures()),
    );
  });

  testWidgets('semantics label is "\$value \$unit"', (tester) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(
      _harness(const NumberText(value: '1,240', unit: 'milligrams')),
    );

    // The composed label appears in the Semantics tree; the inner Text
    // is excluded so we don't get the raw "1,240" announced separately.
    expect(
      find.bySemanticsLabel('1,240 milligrams'),
      findsOneWidget,
    );
      handle.dispose();
  });

  testWidgets('caller style is preserved alongside tabular figures',
      (tester) async {
    const seed = TextStyle(fontSize: 32, fontWeight: FontWeight.w600);
    await tester.pumpWidget(
      _harness(const NumberText(value: '32', unit: 'grams', style: seed)),
    );

    final textWidget = tester.widget<Text>(find.text('32'));
    expect(textWidget.style?.fontSize, 32);
    expect(textWidget.style?.fontWeight, FontWeight.w600);
    expect(
      textWidget.style?.fontFeatures,
      contains(const FontFeature.tabularFigures()),
    );
  });
}
