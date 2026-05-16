import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/units/weight.dart';
import 'package:fulfilled/providers/profile_providers.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/quantity_stepper.dart';
import 'package:fulfilled/widgets/weight_stepper.dart';

/// LU-007 — `WeightStepper`.
///
/// The four acceptance scenarios from the dev ticket:
///   (a) `kg` round-trips a Decimal change through the +/- button.
///   (b) `lb` mode emits the right canonical kg given a 175.0-lb input.
///   (c) `st` mode renders two fields and the pounds +/- carries past
///       13 into the stones field.
///   (d) `st` mode borrows from stones when decrementing past 0 pounds.

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

      // Renders one stepper with the kg suffix and the 1-dp display.
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
    '(b) lb mode emits the right canonical kg for a 175.0-lb typed input',
    (tester) async {
      Decimal? captured;
      await tester.pumpWidget(
        _harness(
          unitOverride: WeightUnit.lb,
          child: WeightStepper(
            value: Decimal.parse('79.4'),
            unitOverride: WeightUnit.lb,
            onChanged: (kg) => captured = kg,
          ),
        ),
      );

      // Renders one stepper with the lb suffix.
      expect(find.text('lb'), findsOneWidget);
      expect(find.text('kg'), findsNothing);

      // Type 175.0 directly into the field. The wrapper converts back
      // to canonical kg via `parseWeightToKg(_, WeightUnit.lb)` — which
      // is `lb * _kgPerLb` with the exact avoirdupois constant.
      await tester.enterText(find.byType(TextField), '175.0');
      await tester.pump();

      final expected = parseWeightToKg('175.0', WeightUnit.lb);
      expect(captured, equals(expected));
      // Sanity-check the numeric magnitude: 175 lb ≈ 79.378664750 kg.
      // Compare via `Decimal` so we don't have to guess the scale the
      // multiplication settles on (175.0 × 0.45359237 = 79.378664750).
      expect(
        captured,
        equals(Decimal.parse('175.0') * Decimal.parse('0.45359237')),
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

      // Two QuantityStepper sub-fields side-by-side — st + lb.
      expect(find.byType(QuantityStepper), findsNWidgets(2));
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
}
