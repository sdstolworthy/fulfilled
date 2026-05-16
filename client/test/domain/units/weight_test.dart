import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/units/weight.dart';

void main() {
  group('formatWeight (kg)', () {
    test('exact 70.0 renders with the trailing zero', () {
      expect(
        formatWeight(Decimal.parse('70'), WeightUnit.kg, locale: 'en_US'),
        '70.0',
      );
    });

    test('always one decimal even for round kg', () {
      expect(
        formatWeight(Decimal.parse('80'), WeightUnit.kg, locale: 'en_US'),
        '80.0',
      );
    });

    test('handles small fractional values', () {
      expect(
        formatWeight(Decimal.parse('0.5'), WeightUnit.kg, locale: 'en_US'),
        '0.5',
      );
    });

    test('one-decimal-always: 78.4 → 78.4', () {
      expect(
        formatWeight(Decimal.parse('78.4'), WeightUnit.kg, locale: 'en_US'),
        '78.4',
      );
    });

    test('one-decimal-always: 82.0 → 82.0', () {
      expect(
        formatWeight(Decimal.parse('82.0'), WeightUnit.kg, locale: 'en_US'),
        '82.0',
      );
    });

    // ----- Half-to-even on tenths (PM §10 #9, T-011 acceptance) -----

    test('70.04 rounds frac < .5 down to 70.0', () {
      expect(
        formatWeight(Decimal.parse('70.04'), WeightUnit.kg, locale: 'en_US'),
        '70.0',
      );
    });

    test('70.45 rounds half-to-even to 70.4 (4 is even)', () {
      expect(
        formatWeight(Decimal.parse('70.45'), WeightUnit.kg, locale: 'en_US'),
        '70.4',
      );
    });

    test('70.55 rounds half-to-even to 70.6 (6 is even)', () {
      expect(
        formatWeight(Decimal.parse('70.55'), WeightUnit.kg, locale: 'en_US'),
        '70.6',
      );
    });

    test('70.05 rounds half-to-even to 70.0 (0 is even)', () {
      expect(
        formatWeight(Decimal.parse('70.05'), WeightUnit.kg, locale: 'en_US'),
        '70.0',
      );
    });

    test('70.15 rounds half-to-even to 70.2 (2 is even)', () {
      expect(
        formatWeight(Decimal.parse('70.15'), WeightUnit.kg, locale: 'en_US'),
        '70.2',
      );
    });
  });
}
