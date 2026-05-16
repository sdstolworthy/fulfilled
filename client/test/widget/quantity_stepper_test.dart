import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/theme/context_extensions.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/quantity_stepper.dart';

/// T-002 — `QuantityStepper` canonical widget.
///
/// Acceptance criteria:
/// - Typing emits `onChanged` with the parsed `Decimal` (T-17).
/// - Stepper plus button increments by `step`.
/// - Floor at `min` for both typing (rejected) and minus tap (clamped).
/// - `hasError: true` renders the error border (`colors.danger`).
/// - `placeholder` shows when `value == null`.
/// - `showStepperButtons: false` hides the +/- buttons.
Widget _harness(Widget child) {
  return MaterialApp(
    theme: buildLightTheme(),
    home: Scaffold(body: child),
  );
}

void main() {
  testWidgets('typing emits onChanged with the parsed Decimal',
      (tester) async {
    Decimal? captured;
    await tester.pumpWidget(
      _harness(
        QuantityStepper(
          value: Decimal.one,
          onChanged: (v) => captured = v,
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '2.5');
    await tester.pump();
    expect(captured, equals(Decimal.parse('2.5')));
  });

  testWidgets('clearing the field emits onChanged(null)', (tester) async {
    Decimal? captured = Decimal.one;
    var calls = 0;
    await tester.pumpWidget(
      _harness(
        QuantityStepper(
          value: Decimal.one,
          onChanged: (v) {
            captured = v;
            calls += 1;
          },
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(calls, greaterThan(0));
    expect(captured, isNull);
  });

  testWidgets('plus button increments by step', (tester) async {
    Decimal? captured;
    await tester.pumpWidget(
      _harness(
        QuantityStepper(
          value: Decimal.one,
          step: Decimal.parse('0.5'),
          onChanged: (v) => captured = v,
        ),
      ),
    );

    await tester.tap(find.bySemanticsLabel('Increment'));
    await tester.pump();
    expect(captured, equals(Decimal.parse('1.5')));
  });

  testWidgets('minus button clamps at min', (tester) async {
    Decimal? captured;
    await tester.pumpWidget(
      _harness(
        QuantityStepper(
          value: Decimal.parse('0.5'),
          step: Decimal.parse('0.5'),
          min: Decimal.parse('0.5'),
          onChanged: (v) => captured = v,
        ),
      ),
    );

    await tester.tap(find.bySemanticsLabel('Decrement'));
    await tester.pump();
    expect(captured, equals(Decimal.parse('0.5')));
  });

  testWidgets('typing below min is rejected (no callback fires)',
      (tester) async {
    final calls = <Decimal?>[];
    await tester.pumpWidget(
      _harness(
        QuantityStepper(
          value: Decimal.fromInt(5),
          min: Decimal.fromInt(3),
          onChanged: calls.add,
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), '1');
    await tester.pump();
    // `1` < min `3` is silently rejected — no value below 3 is emitted.
    expect(calls.any((d) => d != null && d < Decimal.fromInt(3)), isFalse);
  });

  testWidgets('hasError renders the danger border', (tester) async {
    Color? danger;
    await tester.pumpWidget(
      _harness(
        Builder(builder: (context) {
          danger = context.colors.danger;
          return QuantityStepper(
            value: null,
            hasError: true,
            showStepperButtons: false,
            onChanged: (_) {},
          );
        }),
      ),
    );

    // The outer field Container is the one with a 46 px box; grab its
    // decoration and confirm the border resolves to the danger token.
    final container = tester.widgetList<Container>(
      find.ancestor(
        of: find.byType(TextField),
        matching: find.byType(Container),
      ),
    ).firstWhere((c) => c.decoration is BoxDecoration);
    final decoration = container.decoration! as BoxDecoration;
    expect(decoration.border, isA<Border>());
    final border = decoration.border! as Border;
    expect(border.top.color, equals(danger));
  });

  testWidgets('placeholder shows when value is null', (tester) async {
    await tester.pumpWidget(
      _harness(
        QuantityStepper(
          value: null,
          placeholder: '0',
          onChanged: (_) {},
        ),
      ),
    );

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, isEmpty);
    expect(field.decoration!.hintText, equals('0'));
  });

  testWidgets('showStepperButtons: false hides the +/- buttons',
      (tester) async {
    await tester.pumpWidget(
      _harness(
        QuantityStepper(
          value: Decimal.one,
          showStepperButtons: false,
          onChanged: (_) {},
        ),
      ),
    );

    expect(find.bySemanticsLabel('Increment'), findsNothing);
    expect(find.bySemanticsLabel('Decrement'), findsNothing);
  });

  testWidgets('unitSuffix renders the unit in lowercase', (tester) async {
    await tester.pumpWidget(
      _harness(
        QuantityStepper(
          value: Decimal.fromInt(80),
          unitSuffix: 'KG',
          showStepperButtons: false,
          onChanged: (_) {},
        ),
      ),
    );

    expect(find.text('kg'), findsOneWidget);
  });
}
