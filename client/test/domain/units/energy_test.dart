import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/units/energy.dart';

void main() {
  group('formatKcal', () {
    test('rounds frac < 0.5 down', () {
      expect(formatKcal(Decimal.parse('195.4'), locale: 'en_US'), '195');
    });

    test('rounds frac > 0.5 up', () {
      expect(formatKcal(Decimal.parse('195.6'), locale: 'en_US'), '196');
    });

    test('zero is zero', () {
      expect(formatKcal(Decimal.zero, locale: 'en_US'), '0');
    });

    test('thousands separator', () {
      expect(formatKcal(Decimal.parse('2300'), locale: 'en_US'), '2,300');
    });

    // ----- Half-to-even (PM §10 #9, T-011 acceptance) -----

    test('1850.5 rounds half-to-even to 1850 (1850 is even)', () {
      expect(formatKcal(Decimal.parse('1850.5'), locale: 'en_US'), '1,850');
    });

    test('1851.5 rounds half-to-even to 1852 (1852 is even)', () {
      expect(formatKcal(Decimal.parse('1851.5'), locale: 'en_US'), '1,852');
    });

    test('0.5 rounds half-to-even to 0', () {
      expect(formatKcal(Decimal.parse('0.5'), locale: 'en_US'), '0');
    });

    test('1.5 rounds half-to-even to 2', () {
      expect(formatKcal(Decimal.parse('1.5'), locale: 'en_US'), '2');
    });

    test('negative -0.5 rounds half-to-even to 0', () {
      expect(formatKcal(Decimal.parse('-0.5'), locale: 'en_US'), '0');
    });

    test('negative -1.5 rounds half-to-even to -2', () {
      expect(formatKcal(Decimal.parse('-1.5'), locale: 'en_US'), '-2');
    });
  });
}
