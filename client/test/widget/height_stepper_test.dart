import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/units/length.dart';
import 'package:fulfilled/providers/profile_providers.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/height_stepper.dart';

/// QL-103 — `HeightStepper`.
///
/// Original acceptance scenarios from the dev ticket plus the
/// keyboard-input scenarios added when the chrome was re-typeable
/// (LU-010+):
///   (a) cm-mode `+` increments by 1 cm and round-trips canonical cm.
///   (b) cm-mode `+` at maxCm is a no-op (button disabled).
///   (c) ftIn-mode inches `+` at 11 carries to feet.
///   (d) ftIn-mode inches `-` at 0 borrows from feet.
///   (e) typing a cm value and blurring fires onChanged with canonical cm.
///   (f) typing invalid text reverts on blur.
///   (g) typing a value above maxCm clamps to the ceiling on commit.
///   (h) +/- still works after typing.
///   (i) ftIn mode: each sub-field accepts typing independently.
///   (j) typing "13" in inches carries to 1 ft 1 in (FX-005).
///
/// The cm chrome is now a styled `TextField` — visually identical when
/// unfocused, but assertions on the number now target the editable
/// text + a sibling unit `Text` rather than a single composite
/// `Text('175 cm')` glyph.

Widget _harness({
  required Widget child,
  HeightUnit? unitOverride,
}) {
  return ProviderScope(
    overrides: <Override>[
      // Pin the locale-derived fallback so the widget tree doesn't
      // depend on the platform dispatcher's countryCode. The widget
      // reads `heightUnitProvider`, which falls back through
      // `localeDefaultHeightUnitProvider` while `meProvider` is
      // loading. `unitOverride` on `HeightStepper` short-circuits
      // this for tests that need to lock in a specific unit.
      if (unitOverride != null)
        localeDefaultHeightUnitProvider.overrideWithValue(unitOverride),
    ],
    child: MaterialApp(
      theme: buildLightTheme(),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  testWidgets(
    '(a) cm mode +1 increments canonical cm by 1',
    (tester) async {
      Decimal? captured;
      var current = Decimal.fromInt(175);
      await tester.pumpWidget(
        _harness(
          unitOverride: HeightUnit.cm,
          child: StatefulBuilder(
            builder: (context, setState) {
              return HeightStepper(
                value: current,
                unitOverride: HeightUnit.cm,
                onChanged: (cm) {
                  captured = cm;
                  setState(() => current = cm);
                },
              );
            },
          ),
        ),
      );

      // The number lives inside the `TextField`; the unit suffix is a
      // sibling `Text`. The composite `'175 cm'` glyph is gone
      // (post-LU-010 keyboard fix).
      expect(find.text('175'), findsOneWidget);
      expect(find.text('cm'), findsOneWidget);
      expect(find.text('ft'), findsNothing);
      expect(find.text('in'), findsNothing);

      await tester.tap(find.bySemanticsLabel('Increment'));
      await tester.pump();

      // Step is 1 cm. The canonical cm comes back through `onChanged`
      // exactly — cm display unit IS canonical, no conversion seam.
      expect(captured, isNotNull);
      expect(captured, equals(Decimal.fromInt(176)));
      expect(find.text('176'), findsOneWidget);
    },
  );

  testWidgets(
    '(b) cm mode + at maxCm is a no-op (button disabled)',
    (tester) async {
      Decimal? captured;
      await tester.pumpWidget(
        _harness(
          unitOverride: HeightUnit.cm,
          child: HeightStepper(
            value: Decimal.fromInt(250),
            unitOverride: HeightUnit.cm,
            maxCm: Decimal.fromInt(250),
            onChanged: (cm) => captured = cm,
          ),
        ),
      );

      expect(find.text('250'), findsOneWidget);
      expect(find.text('cm'), findsOneWidget);

      // The Increment button is disabled at the ceiling; tapping it
      // must not fire `onChanged`. We tap by semantics label (the
      // Semantics node is still in the tree, with `enabled: false`).
      await tester.tap(find.bySemanticsLabel('Increment'));
      await tester.pump();

      expect(captured, isNull);
      expect(find.text('250'), findsOneWidget);
    },
  );

  testWidgets(
    '(c) ftIn mode inches + at 11 carries to feet (5 ft 11 in → 6 ft)',
    (tester) async {
      Decimal? captured;
      // Seed: 5 ft 11 in. 71 in × 2.54 = 180.34 → rounds to 180 cm.
      final seedCm = parseFeetInchesToCm(5, 11);
      var current = seedCm;

      await tester.pumpWidget(
        _harness(
          unitOverride: HeightUnit.ftIn,
          child: StatefulBuilder(
            builder: (context, setState) {
              return HeightStepper(
                value: current,
                unitOverride: HeightUnit.ftIn,
                onChanged: (cm) {
                  captured = cm;
                  setState(() => current = cm);
                },
              );
            },
          ),
        ),
      );

      // Two display sub-steppers — feet + inches. Number in each
      // `TextField`, unit suffix as a sibling `Text`.
      expect(find.text('5'), findsOneWidget);
      expect(find.text('11'), findsOneWidget);
      expect(find.text('ft'), findsOneWidget);
      expect(find.text('in'), findsOneWidget);

      // Two Increment buttons live in the column (one per sub-stepper).
      // The inches +/- buttons drive the ftIn composite; carry kicks
      // in when inches goes from 11 → 12, which becomes feet += 1.
      final incrementButtons = find.bySemanticsLabel('Increment');
      expect(incrementButtons, findsNWidgets(2));

      // Tap the inches Increment (second of the two, since inches is
      // the lower / second sub-field). 11 + 1 = 12 → carry → 6 ft 0 in.
      await tester.tap(incrementButtons.at(1));
      await tester.pump();

      expect(captured, isNotNull);
      expect(captured, equals(parseFeetInchesToCm(6, 0)));
      expect(find.text('6'), findsOneWidget);
      expect(find.text('0'), findsOneWidget);
    },
  );

  testWidgets(
    '(d) ftIn mode inches - at 0 borrows from feet (6 ft 0 in → 5 ft 11 in)',
    (tester) async {
      Decimal? captured;
      // Seed: 6 ft 0 in. Inches is at the floor; tapping `-` on the
      // inches field should borrow one foot and land on 5 ft 11 in.
      final seedCm = parseFeetInchesToCm(6, 0);
      var current = seedCm;

      await tester.pumpWidget(
        _harness(
          unitOverride: HeightUnit.ftIn,
          child: StatefulBuilder(
            builder: (context, setState) {
              return HeightStepper(
                value: current,
                unitOverride: HeightUnit.ftIn,
                onChanged: (cm) {
                  captured = cm;
                  setState(() => current = cm);
                },
              );
            },
          ),
        ),
      );

      expect(find.text('6'), findsOneWidget);
      expect(find.text('0'), findsOneWidget);

      final decrementButtons = find.bySemanticsLabel('Decrement');
      expect(decrementButtons, findsNWidgets(2));

      // Tap inches Decrement — the lower / second of the two.
      await tester.tap(decrementButtons.at(1));
      await tester.pump();

      expect(captured, isNotNull);
      expect(captured, equals(parseFeetInchesToCm(5, 11)));
      expect(find.text('5'), findsOneWidget);
      expect(find.text('11'), findsOneWidget);
    },
  );

  testWidgets(
    'unitOverride: cm renders cm row even if heightUnitProvider says ftIn',
    (tester) async {
      await tester.pumpWidget(
        _harness(
          // Locale default + provider both say ftIn…
          unitOverride: HeightUnit.ftIn,
          child: HeightStepper(
            value: Decimal.fromInt(175),
            // …but the widget-local override pins cm.
            unitOverride: HeightUnit.cm,
            onChanged: (_) {},
          ),
        ),
      );

      // Only one stepper renders ("175" + "cm"). No ft / in glyphs.
      expect(find.text('175'), findsOneWidget);
      expect(find.text('cm'), findsOneWidget);
      expect(find.text('ft'), findsNothing);
      expect(find.text('in'), findsNothing);
      // And only one Increment button — not the two-field ftIn shape.
      expect(find.bySemanticsLabel('Increment'), findsOneWidget);
    },
  );

  testWidgets(
    '(e) cm mode: typing a new value and blurring fires onChanged with canonical cm',
    (tester) async {
      Decimal? captured;
      var current = Decimal.fromInt(170);
      await tester.pumpWidget(
        _harness(
          unitOverride: HeightUnit.cm,
          child: StatefulBuilder(
            builder: (context, setState) {
              return Column(
                children: <Widget>[
                  HeightStepper(
                    value: current,
                    unitOverride: HeightUnit.cm,
                    onChanged: (cm) {
                      captured = cm;
                      setState(() => current = cm);
                    },
                  ),
                  const TextField(key: Key('blur-target')),
                ],
              );
            },
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).first, '182');
      await tester.tap(find.byKey(const Key('blur-target')));
      await tester.pump();

      expect(captured, isNotNull);
      expect(captured, equals(Decimal.fromInt(182)));
      expect(find.text('182'), findsOneWidget);
    },
  );

  testWidgets(
    '(f) cm mode: typing invalid text reverts to the last canonical value on blur',
    (tester) async {
      Decimal? captured;
      var current = Decimal.fromInt(170);
      await tester.pumpWidget(
        _harness(
          unitOverride: HeightUnit.cm,
          child: StatefulBuilder(
            builder: (context, setState) {
              return Column(
                children: <Widget>[
                  HeightStepper(
                    value: current,
                    unitOverride: HeightUnit.cm,
                    onChanged: (cm) {
                      captured = cm;
                      setState(() => current = cm);
                    },
                  ),
                  const TextField(key: Key('blur-target')),
                ],
              );
            },
          ),
        ),
      );

      // Two decimal points — the formatter lets them through but
      // `Decimal.parse('..')` throws a `FormatException` so the
      // commit path reverts.
      await tester.enterText(find.byType(TextField).first, '..');
      await tester.tap(find.byKey(const Key('blur-target')));
      await tester.pump();

      expect(captured, isNull);
      expect(find.text('170'), findsOneWidget);

      // Also exercise the empty-input branch: clearing the field on
      // blur reverts without propagating `null` (per spec).
      await tester.enterText(find.byType(TextField).first, '');
      await tester.tap(find.byKey(const Key('blur-target')));
      await tester.pump();
      expect(captured, isNull);
      expect(find.text('170'), findsOneWidget);
    },
  );

  testWidgets(
    '(g) cm mode: typing a value above maxCm clamps to the ceiling on commit',
    (tester) async {
      Decimal? captured;
      var current = Decimal.fromInt(170);
      await tester.pumpWidget(
        _harness(
          unitOverride: HeightUnit.cm,
          child: StatefulBuilder(
            builder: (context, setState) {
              return Column(
                children: <Widget>[
                  HeightStepper(
                    value: current,
                    unitOverride: HeightUnit.cm,
                    minCm: Decimal.fromInt(80),
                    maxCm: Decimal.fromInt(250),
                    onChanged: (cm) {
                      captured = cm;
                      setState(() => current = cm);
                    },
                  ),
                  const TextField(key: Key('blur-target')),
                ],
              );
            },
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).first, '999');
      await tester.tap(find.byKey(const Key('blur-target')));
      await tester.pump();

      // Clamped to the 250 cm ceiling.
      expect(captured, isNotNull);
      expect(captured, equals(Decimal.fromInt(250)));
      expect(find.text('250'), findsOneWidget);
    },
  );

  testWidgets(
    '(h) cm mode: +/- still works correctly after typing a value',
    (tester) async {
      Decimal? captured;
      var current = Decimal.fromInt(170);
      await tester.pumpWidget(
        _harness(
          unitOverride: HeightUnit.cm,
          child: StatefulBuilder(
            builder: (context, setState) {
              return Column(
                children: <Widget>[
                  HeightStepper(
                    value: current,
                    unitOverride: HeightUnit.cm,
                    onChanged: (cm) {
                      captured = cm;
                      setState(() => current = cm);
                    },
                  ),
                  const TextField(key: Key('blur-target')),
                ],
              );
            },
          ),
        ),
      );

      await tester.enterText(find.byType(TextField).first, '180');
      await tester.tap(find.byKey(const Key('blur-target')));
      await tester.pump();
      expect(captured, equals(Decimal.fromInt(180)));

      // Tap `+` — should bump from 180 to 181.
      await tester.tap(find.bySemanticsLabel('Increment'));
      await tester.pump();
      expect(captured, equals(Decimal.fromInt(181)));
      expect(find.text('181'), findsOneWidget);
    },
  );

  testWidgets(
    '(j) ftIn mode: typing 13 in inches carries to 1 ft 1 in (FX-005)',
    (tester) async {
      Decimal? captured;
      // Seed: 5 ft 0 in. Typing 13 in inches → carry: feet += 1, in = 1
      // → 6 ft 1 in. This exercises both the carry math and the
      // re-paint of the feet sub-field on a pounds-side commit.
      var current = parseFeetInchesToCm(5, 0);
      await tester.pumpWidget(
        _harness(
          unitOverride: HeightUnit.ftIn,
          child: StatefulBuilder(
            builder: (context, setState) {
              return Column(
                children: <Widget>[
                  HeightStepper(
                    value: current,
                    unitOverride: HeightUnit.ftIn,
                    onChanged: (cm) {
                      captured = cm;
                      setState(() => current = cm);
                    },
                  ),
                  const TextField(key: Key('blur-target')),
                ],
              );
            },
          ),
        ),
      );

      final stepperFields = find.byType(TextField);
      expect(stepperFields, findsNWidgets(3));

      // Type "13" into the inches sub-field (second of the two stepper
      // fields). Pre-fix this clamped to 11; post-fix it carries to
      // 6 ft 1 in (5 feet + (13 // 12) = 6; 13 % 12 = 1 inch).
      await tester.enterText(stepperFields.at(1), '13');
      await tester.tap(find.byKey(const Key('blur-target')));
      await tester.pump();

      expect(captured, isNotNull);
      expect(captured, equals(parseFeetInchesToCm(6, 1)));
      // Feet sub-field reflects the carry; inches reseeds to 1.
      expect(find.text('6'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
    },
  );

  testWidgets(
    '(i) ftIn mode: each sub-field accepts typing independently',
    (tester) async {
      Decimal? captured;
      // Seed: 5 ft 9 in.
      var current = parseFeetInchesToCm(5, 9);
      await tester.pumpWidget(
        _harness(
          unitOverride: HeightUnit.ftIn,
          child: StatefulBuilder(
            builder: (context, setState) {
              return Column(
                children: <Widget>[
                  HeightStepper(
                    value: current,
                    unitOverride: HeightUnit.ftIn,
                    onChanged: (cm) {
                      captured = cm;
                      setState(() => current = cm);
                    },
                  ),
                  const TextField(key: Key('blur-target')),
                ],
              );
            },
          ),
        ),
      );

      // Two TextFields for ft + in (plus the off-stepper blur target).
      final stepperFields = find.byType(TextField);
      expect(stepperFields, findsNWidgets(3));

      // Type a fresh feet value into the first sub-field.
      await tester.enterText(stepperFields.at(0), '6');
      await tester.tap(find.byKey(const Key('blur-target')));
      await tester.pump();
      expect(captured, equals(parseFeetInchesToCm(6, 9)));

      // Now type a fresh inches value into the second sub-field.
      await tester.enterText(stepperFields.at(1), '4');
      await tester.tap(find.byKey(const Key('blur-target')));
      await tester.pump();
      expect(captured, equals(parseFeetInchesToCm(6, 4)));
    },
  );
}
