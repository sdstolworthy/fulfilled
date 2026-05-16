import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/units/weight.dart';

void main() {
  group('formatWeightKg', () {
    test('exact 70.0 renders with the trailing zero', () {
      expect(formatWeightKg(Decimal.parse('70'), locale: 'en_US'), '70.0');
    });

    test('always one decimal even for round kg', () {
      expect(formatWeightKg(Decimal.parse('80'), locale: 'en_US'), '80.0');
    });

    test('handles small fractional values', () {
      expect(formatWeightKg(Decimal.parse('0.5'), locale: 'en_US'), '0.5');
    });

    test('one-decimal-always: 78.4 → 78.4', () {
      expect(formatWeightKg(Decimal.parse('78.4'), locale: 'en_US'), '78.4');
    });

    test('one-decimal-always: 82.0 → 82.0', () {
      expect(formatWeightKg(Decimal.parse('82.0'), locale: 'en_US'), '82.0');
    });

    // ----- Half-to-even on tenths (PM §10 #9, T-011 acceptance) -----

    test('70.04 rounds frac < .5 down to 70.0', () {
      expect(formatWeightKg(Decimal.parse('70.04'), locale: 'en_US'), '70.0');
    });

    test('70.45 rounds half-to-even to 70.4 (4 is even)', () {
      expect(formatWeightKg(Decimal.parse('70.45'), locale: 'en_US'), '70.4');
    });

    test('70.55 rounds half-to-even to 70.6 (6 is even)', () {
      expect(formatWeightKg(Decimal.parse('70.55'), locale: 'en_US'), '70.6');
    });

    test('70.05 rounds half-to-even to 70.0 (0 is even)', () {
      expect(formatWeightKg(Decimal.parse('70.05'), locale: 'en_US'), '70.0');
    });

    test('70.15 rounds half-to-even to 70.2 (2 is even)', () {
      expect(formatWeightKg(Decimal.parse('70.15'), locale: 'en_US'), '70.2');
    });
  });
}
