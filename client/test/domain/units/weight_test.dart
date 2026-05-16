import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/units/weight.dart';

void main() {
  group('formatWeightKg', () {
    test('exact 70.0 renders with the trailing zero', () {
      expect(formatWeightKg(Decimal.parse('70'), locale: 'en_US'), '70.0');
    });

    test('70.05 rounds half-up to 70.1', () {
      expect(formatWeightKg(Decimal.parse('70.05'), locale: 'en_US'), '70.1');
    });

    test('70.04 rounds down to 70.0', () {
      expect(formatWeightKg(Decimal.parse('70.04'), locale: 'en_US'), '70.0');
    });

    test('always one decimal even for round kg', () {
      expect(formatWeightKg(Decimal.parse('80'), locale: 'en_US'), '80.0');
    });

    test('handles small fractional values', () {
      expect(formatWeightKg(Decimal.parse('0.5'), locale: 'en_US'), '0.5');
    });
  });
}
