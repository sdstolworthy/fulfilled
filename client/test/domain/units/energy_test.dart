import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/units/energy.dart';

void main() {
  group('formatKcal', () {
    test('integer rounding half-up', () {
      expect(formatKcal(Decimal.parse('195.4'), locale: 'en_US'), '195');
      expect(formatKcal(Decimal.parse('195.5'), locale: 'en_US'), '196');
    });

    test('zero is zero', () {
      expect(formatKcal(Decimal.zero, locale: 'en_US'), '0');
    });

    test('thousands separator', () {
      expect(formatKcal(Decimal.parse('2300'), locale: 'en_US'), '2,300');
    });
  });
}
