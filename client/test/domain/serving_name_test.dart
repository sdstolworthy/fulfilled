// Unit tests for `Serving.name` (lib/domain/serving.dart:73) per F4-T3.
//
// The getter has exactly two branches:
//   1. `label` is non-null → return it verbatim.
//   2. `label` is null → fall back to `formatAmountUnit(amount, unit)`.
//
// These two tests pin both branches so future refactors of the
// fallback (or accidental tweaks to the label-passthrough) surface
// here rather than in a screen-render diff.

import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/serving.dart';
import 'package:fulfilled/domain/unit.dart';

void main() {
  group('Serving.name', () {
    test('returns the label when present', () {
      final s = Serving(
        id: 'sv_drumstick',
        label: '1 drumstick',
        amount: Decimal.parse('94.7'),
        unit: Unit.g,
        kcal: Decimal.parse('172'),
        isDefault: true,
        source: ServingSource.system,
      );

      expect(s.name, '1 drumstick');
    });

    test('falls back to formatAmountUnit when label is null', () {
      final s = Serving(
        id: 'sv_100g',
        label: null,
        amount: Decimal.parse('100'),
        unit: Unit.g,
        kcal: Decimal.parse('100'),
        isDefault: false,
        source: ServingSource.system,
      );

      // `formatAmountUnit` trims trailing zeros on the amount, so
      // `Decimal.parse('100')` renders as `"100"` (no `.0`) and the
      // mass-family branch joins it with `unit.shortLabel` → `"100 g"`.
      expect(s.name, '100 g');
      expect(s.name, formatAmountUnit(s.amount, s.unit));
    });
  });
}
