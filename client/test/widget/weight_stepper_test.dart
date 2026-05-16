import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/units/weight.dart';
import 'package:fulfilled/providers/profile_providers.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/weight_stepper.dart';

/// LU-007 — `WeightStepper`.
///
/// The four original acceptance scenarios from the dev ticket plus the
/// keyboard-input scenarios added when the chrome was re-typeable
/// (LU-010+):
///   (a) `kg` round-trips a Decimal change through the +/- button.
///   (b) `lb` mode emits the right canonical kg when the displayed
///       pounds value is bumped via the `+` button.
///   (c) `st` mode renders two fields and the pounds +/- carries past
///       13 into the stones field.
///   (d) `st` mode borrows from stones when decrementing past 0 pounds.
///   (e) typing a kg value and blurring fires onChanged with the
///       canonical Decimal.
///   (f) typing invalid text reverts on blur.
///   (g) typing a value outside `min/max` clamps to bounds.
///   (h) +/- still works after typing.
///   (i) each sub-field of stone mode accepts typing independently.
///
/// The kg/lb chrome is now a styled `TextField` (LU-010 keyboard input
/// fix) — visually identical when unfocused, but assertions on the
/// number now target the editable text + a sibling unit `Text` rather
/// than a single composite `Text('79.4 kg')` glyph.

Widget _harness({
  required Widget child,
  WeightUnit? unitOverride,
}) {
  return ProviderScope(
    overrides: <Override>[
      // Pin the locale-derived fallback so the widget tree doesn't
      // depend on the platform dispatcher's countryCode. The widget
      // reads `weightUnitProvider`, which falls back through
      // `localeDefaultWeightUnitProvider` while `meProvider` is
      // loading. `unitOverride` on `WeightStepper` short-circuits this
      // for tests that need to lock in a specific unit.
      if (unitOverride != null)
        localeDefaultWeightUnitProvider.overrideWithValue(unitOverride),
    ],
    child: MaterialApp(
      theme: buildLightTheme(),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  testWidgets(
    '(a) kg mode round-trips a Decimal change via the + button',
    (tester) async {
      Decimal? captured;
      var current = Decimal.parse('79.4');
      await tester.pumpWidget(
        _harness(
          unitOverride: WeightUnit.kg,
          child: StatefulBuilder(
            builder: (context, setState) {
              return WeightStepper(
                value: current,
                unitOverride: WeightUnit.kg,
                onChanged: (kg) {
                  captured = kg;
                  setState(() => current = kg);
                },
              );
            },
          ),
        ),
      );

      // The number lives in the `TextField` controller; the unit
      // suffix is a sibling `Text`. The composite `'79.4 kg'` is no
      // longer a single rendered glyph (post-LU-010 keyboard fix).
      expect(find.text('79.4'), findsOneWidget);
      expect(find.text('kg'), findsOneWidget);
      expect(find.text('lb'), findsNothing);

      await tester.tap(find.bySemanticsLabel('Increment'));
      await tester.pump();

      // Step is 0.1 kg. The canonical kg comes back through `onChanged`
      // exactly — kg display unit IS canonical, no conversion seam.
      expect(captured, isNotNull);
      expect(captured, equals(Decimal.parse('79.5')));
    },
  );

  testWidgets(
    '(b) lb mode emits the right canonical kg when + bumps the displayed pounds',
    (tester) async {
      Decimal? captured;
      // Seed with the canonical kg for exactly 175.0 lb so the display
      // sits at "175.0 lb" before we tap. One `+` press bumps the
      // displayed lb to 175.1, which the wrapper converts back to
      // canonical kg via `parseWeightToKg(_, WeightUnit.lb)` — i.e.
      // `lb * _kgPerLb` with the exact avoirdupois constant.
      final seedKg = parseWeightToKg('175.0', WeightUnit.lb);
      await tester.pumpWidget(
        _harness(
          unitOverride: WeightUnit.lb,
          child: WeightStepper(
            value: seedKg,
            unitOverride: WeightUnit.lb,
            onChanged: (kg) => captured = kg,
          ),
        ),
      );

      // Renders the lb label as a sibling `Text` — the number sits in
      // the `TextField`.
      expect(find.text('175.0'), findsOneWidget);
      expect(find.text('lb'), findsOneWidget);
      expect(find.text('kg'), findsNothing);

      await tester.tap(find.bySemanticsLabel('Increment'));
      await tester.pump();

      // Step is 0.1 lb. Expected canonical kg = 175.1 lb in kg.
      final expected = parseWeightToKg('175.1', WeightUnit.lb);
      expect(captured, isNotNull);
      expect(captured, equals(expected));
      // Sanity-check the numeric magnitude: 175.1 lb × 0.45359237 kg/lb.
      expect(
        captured,
        equals(Decimal.parse('175.1') * Decimal.parse('0.45359237')),
      );
    },
  );

  testWidgets(
    '(c) st mode renders two fields; incrementing from 13 lb carries to stones',
    (tester) async {
      Decimal? captured;
      // Seed: 12 st 13 lb. 12*14 + 13 = 181 lb → 181 * _kgPerLb kg.
      final seedKg = parseStoneToKg(12, 13);
      var current = seedKg;

      await tester.pumpWidget(
        _harness(
          unitOverride: WeightUnit.st,
          child: StatefulBuilder(
            builder: (context, setState) {
              return WeightStepper(
                value: current,
                unitOverride: WeightUnit.st,
                onChanged: (kg) {
                  captured = kg;
                  setState(() => current = kg);
                },
              );
            },
          ),
        ),
      );

      // Two display sub-steppers side-by-side — st + lb. The number
      // is in each `TextField`, the unit is a sibling `Text`.
      expect(find.text('12'), findsOneWidget);
      expect(find.text('13'), findsOneWidget);
      expect(find.text('st'), findsOneWidget);
      expect(find.text('lb'), findsOneWidget);

      // Two Increment buttons live in the row (one per sub-stepper).
      // The pounds +/- buttons drive the stone composite; carry kicks
      // in when pounds goes from 13 → 14, which becomes stones += 1.
      final incrementButtons = find.bySemanticsLabel('Increment');
      expect(incrementButtons, findsNWidgets(2));

      // Tap the pounds Increment (second of the two, since pounds is
      // the rightmost field). 13 + 1 = 14 → carry → 13 st 0 lb.
      await tester.tap(incrementButtons.at(1));
      await tester.pump();

      expect(captured, isNotNull);
      expect(captured, equals(parseStoneToKg(13, 0)));
    },
  );

  testWidgets(
    '(d) st mode decrementing from 0 lb borrows from stones',
    (tester) async {
      Decimal? captured;
      // Seed: 12 st 0 lb. Pounds is at the floor; tapping `-` on the
      // pounds field should borrow one stone and land on 11 st 13 lb.
      final seedKg = parseStoneToKg(12, 0);
      var current = seedKg;

      await tester.pumpWidget(
        _harness(
          unitOverride: WeightUnit.st,
          child: StatefulBuilder(
            builder: (context, setState) {
              return WeightStepper(
                value: current,
                unitOverride: WeightUnit.st,
                onChanged: (kg) {
                  captured = kg;
                  setState(() => current = kg);
                },
              );
            },
          ),
        ),
      );

      final decrementButtons = find.bySemanticsLabel('Decrement');
      expect(decrementButtons, findsNWidgets(2));

      // Tap pounds Decrement — the rightmost of the two.
      await tester.tap(decrementButtons.at(1));
      await tester.pump();

      expect(captured, isNotNull);
      expect(captured, equals(parseStoneToKg(11, 13)));
    },
  );

  testWidgets(
    '(e) kg mode: typing a new value and blurring fires onChanged with canonical kg',
    (tester) async {
      Decimal? captured;
      var current = Decimal.parse('70.0');
      await tester.pumpWidget(
        _harness(
          unitOverride: WeightUnit.kg,
          child: StatefulBuilder(
            builder: (context, setState) {
              return Column(
                children: <Widget>[
                  WeightStepper(
                    value: current,
                    unitOverride: WeightUnit.kg,
                    onChanged: (kg) {
                      captured = kg;
                      setState(() => current = kg);
                    },
                  ),
                  // Sibling focusable target so we can move focus away
                  // from the stepper and trigger the commit-on-blur
                  // listener.
                  const TextField(key: Key('blur-target')),
                ],
              );
            },
          ),
        ),
      );

      // Focus the stepper's TextField (the EditableText sibling of
      // the unit Text). `enterText` focuses and replaces the controller.
      await tester.enterText(find.byType(TextField).first, '82.7');
      // Move focus to the sibling field — this fires the commit-on-blur
      // listener on the stepper's FocusNode.
      await tester.tap(find.byKey(const Key('blur-target')));
      await tester.pump();

      expect(captured, isNotNull);
      // kg mode is canonical, rounded to 1dp on commit.
      expect(captured, equals(Decimal.parse('82.7')));
      // Field re-seeds to the canonical glyph.
      expect(find.text('82.7'), findsOneWidget);
    },
  );

  testWidgets(
    '(f) kg mode: typing invalid text reverts to the last canonical value on blur',
    (tester) async {
      Decimal? captured;
      var current = Decimal.parse('70.0');
      await tester.pumpWidget(
        _harness(
          unitOverride: WeightUnit.kg,
          child: StatefulBuilder(
            builder: (context, setState) {
              return Column(
                children: <Widget>[
                  WeightStepper(
                    value: current,
                    unitOverride: WeightUnit.kg,
                    onChanged: (kg) {
                      captured = kg;
                      setState(() => current = kg);
                    },
                  ),
                  const TextField(key: Key('blur-target')),
                ],
              );
            },
          ),
        ),
      );

      // The input formatter strips alpha characters before the
      // controller sees them, so feed a shape the formatter passes
      // through but the parser rejects: two decimal points in a row,
      // which `Decimal.parse('..')` rejects as a `FormatException`.
      await tester.enterText(find.byType(TextField).first, '..');
      await tester.tap(find.byKey(const Key('blur-target')));
      await tester.pump();

      // No commit fired — value stayed at 70.0.
      expect(captured, isNull);
      // Field reverts to the canonical glyph for 70.0 kg.
      expect(find.text('70.0'), findsOneWidget);

      // Also exercise the empty-input branch: clearing the field on
      // blur reverts without propagating `null` (per spec).
      await tester.enterText(find.byType(TextField).first, '');
      await tester.tap(find.byKey(const Key('blur-target')));
      await tester.pump();
      expect(captured, isNull);
      expect(find.text('70.0'), findsOneWidget);
    },
  );

  testWidgets(
    '(g) kg mode: typing a value above max clamps to the ceiling on commit',
    (tester) async {
      Decimal? captured;
      var current = Decimal.parse('70.0');
      await tester.pumpWidget(
        _harness(
          unitOverride: WeightUnit.kg,
          child: StatefulBuilder(
            builder: (context, setState) {
              return Column(
                children: <Widget>[
                  WeightStepper(
                    value: current,
                    unitOverride: WeightUnit.kg,
                    minKg: Decimal.parse('40.0'),
                    maxKg: Decimal.parse('200.0'),
                    onChanged: (kg) {
                      captured = kg;
                      setState(() => current = kg);
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

      // Clamped to the 200 kg ceiling.
      expect(captured, isNotNull);
      expect(captured, equals(Decimal.parse('200.0')));
      expect(find.text('200.0'), findsOneWidget);
    },
  );

  testWidgets(
    '(h) kg mode: +/- still works correctly after typing a value',
    (tester) async {
      Decimal? captured;
      var current = Decimal.parse('70.0');
      await tester.pumpWidget(
        _harness(
          unitOverride: WeightUnit.kg,
          child: StatefulBuilder(
            builder: (context, setState) {
              return Column(
                children: <Widget>[
                  WeightStepper(
                    value: current,
                    unitOverride: WeightUnit.kg,
                    onChanged: (kg) {
                      captured = kg;
                      setState(() => current = kg);
                    },
                  ),
                  const TextField(key: Key('blur-target')),
                ],
              );
            },
          ),
        ),
      );

      // Type a fresh value and commit via blur.
      await tester.enterText(find.byType(TextField).first, '80.5');
      await tester.tap(find.byKey(const Key('blur-target')));
      await tester.pump();
      expect(captured, equals(Decimal.parse('80.5')));

      // Now tap `+` — it should bump the displayed value (which
      // matches the controller text post-commit) by 0.1 kg.
      await tester.tap(find.bySemanticsLabel('Increment'));
      await tester.pump();
      expect(captured, equals(Decimal.parse('80.6')));
      expect(find.text('80.6'), findsOneWidget);
    },
  );

  testWidgets(
    '(i) st mode: each sub-field accepts typing independently',
    (tester) async {
      Decimal? captured;
      // Seed: 12 st 7 lb.
      var current = parseStoneToKg(12, 7);
      await tester.pumpWidget(
        _harness(
          unitOverride: WeightUnit.st,
          child: StatefulBuilder(
            builder: (context, setState) {
              return Column(
                children: <Widget>[
                  WeightStepper(
                    value: current,
                    unitOverride: WeightUnit.st,
                    onChanged: (kg) {
                      captured = kg;
                      setState(() => current = kg);
                    },
                  ),
                  const TextField(key: Key('blur-target')),
                ],
              );
            },
          ),
        ),
      );

      // Two TextFields for st + lb (plus the off-stepper blur target).
      final stepperFields = find.byType(TextField);
      expect(stepperFields, findsNWidgets(3));

      // Type a fresh stones value into the first sub-field.
      await tester.enterText(stepperFields.at(0), '11');
      await tester.tap(find.byKey(const Key('blur-target')));
      await tester.pump();
      expect(captured, equals(parseStoneToKg(11, 7)));

      // Now type a fresh pounds value into the second sub-field.
      await tester.enterText(stepperFields.at(1), '3');
      await tester.tap(find.byKey(const Key('blur-target')));
      await tester.pump();
      expect(captured, equals(parseStoneToKg(11, 3)));
    },
  );

  testWidgets(
    'lb mode: comma decimal separator parses on commit (locale tolerance)',
    (tester) async {
      Decimal? captured;
      final seedKg = parseWeightToKg('175.0', WeightUnit.lb);
      var current = seedKg;
      await tester.pumpWidget(
        _harness(
          unitOverride: WeightUnit.lb,
          child: StatefulBuilder(
            builder: (context, setState) {
              return Column(
                children: <Widget>[
                  WeightStepper(
                    value: current,
                    unitOverride: WeightUnit.lb,
                    onChanged: (kg) {
                      captured = kg;
                      setState(() => current = kg);
                    },
                  ),
                  const TextField(key: Key('blur-target')),
                ],
              );
            },
          ),
        ),
      );

      // de-DE-shape `,` separator — `parseWeightToKg` normalises it.
      await tester.enterText(find.byType(TextField).first, '180,5');
      await tester.tap(find.byKey(const Key('blur-target')));
      await tester.pump();

      expect(captured, isNotNull);
      expect(captured, equals(parseWeightToKg('180.5', WeightUnit.lb)));
    },
  );
}
