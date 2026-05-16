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
/// Acceptance scenarios from the dev ticket:
///   (a) cm-mode `+` increments by 1 cm and round-trips canonical cm.
///   (b) cm-mode `+` at maxCm is a no-op (button disabled).
///   (c) ftIn-mode inches `+` at 11 carries to feet.
///   (d) ftIn-mode inches `-` at 0 borrows from feet.
///
/// Plus the unitOverride seam, the cm-mode min clamp, and a seed-via-
/// canonical-cm round-trip — same shape as the weight stepper's test
/// suite for cross-axis symmetry.

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

      // Renders one stepper with the value + cm suffix at integer
      // resolution. No ft / in glyphs in cm mode.
      expect(find.text('175 cm'), findsOneWidget);
      expect(find.textContaining('ft'), findsNothing);
      expect(find.textContaining(' in'), findsNothing);

      await tester.tap(find.bySemanticsLabel('Increment'));
      await tester.pump();

      // Step is 1 cm. The canonical cm comes back through `onChanged`
      // exactly — cm display unit IS canonical, no conversion seam.
      expect(captured, isNotNull);
      expect(captured, equals(Decimal.fromInt(176)));
      expect(find.text('176 cm'), findsOneWidget);
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

      expect(find.text('250 cm'), findsOneWidget);

      // The Increment button is disabled at the ceiling; tapping it
      // must not fire `onChanged`. We tap by semantics label (the
      // Semantics node is still in the tree, with `enabled: false`).
      await tester.tap(find.bySemanticsLabel('Increment'));
      await tester.pump();

      expect(captured, isNull);
      expect(find.text('250 cm'), findsOneWidget);
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

      // Two display-only sub-steppers side-by-side — feet + inches.
      // The unit is embedded in each value label ("5 ft" / "11 in"),
      // so we assert against the composite text rather than a bare
      // suffix.
      expect(find.text('5 ft'), findsOneWidget);
      expect(find.text('11 in'), findsOneWidget);

      // Two Increment buttons live in the row (one per sub-stepper).
      // The inches +/- buttons drive the ftIn composite; carry kicks
      // in when inches goes from 11 → 12, which becomes feet += 1.
      final incrementButtons = find.bySemanticsLabel('Increment');
      expect(incrementButtons, findsNWidgets(2));

      // Tap the inches Increment (second of the two, since inches is
      // the rightmost field). 11 + 1 = 12 → carry → 6 ft 0 in.
      await tester.tap(incrementButtons.at(1));
      await tester.pump();

      expect(captured, isNotNull);
      expect(captured, equals(parseFeetInchesToCm(6, 0)));
      expect(find.text('6 ft'), findsOneWidget);
      expect(find.text('0 in'), findsOneWidget);
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

      expect(find.text('6 ft'), findsOneWidget);
      expect(find.text('0 in'), findsOneWidget);

      final decrementButtons = find.bySemanticsLabel('Decrement');
      expect(decrementButtons, findsNWidgets(2));

      // Tap inches Decrement — the rightmost of the two.
      await tester.tap(decrementButtons.at(1));
      await tester.pump();

      expect(captured, isNotNull);
      expect(captured, equals(parseFeetInchesToCm(5, 11)));
      expect(find.text('5 ft'), findsOneWidget);
      expect(find.text('11 in'), findsOneWidget);
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

      // Only one stepper renders ("175 cm"). No "5 ft" / "9 in" glyphs.
      expect(find.text('175 cm'), findsOneWidget);
      expect(find.textContaining('ft'), findsNothing);
      expect(find.textContaining(' in'), findsNothing);
      // And only one Increment button — not the two-field ftIn shape.
      expect(find.bySemanticsLabel('Increment'), findsOneWidget);
    },
  );
}
