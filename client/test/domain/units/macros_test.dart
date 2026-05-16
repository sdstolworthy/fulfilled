import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/units/macros.dart';

void main() {
  group('formatGrams', () {
    test('value of 9 (below 10) renders one decimal', () {
      expect(formatGrams(Decimal.parse('9'), locale: 'en_US'), '9.0');
    });

    test('value of 9.5 renders 9.5', () {
      expect(formatGrams(Decimal.parse('9.5'), locale: 'en_US'), '9.5');
    });

    test('value of 10 renders as integer', () {
      expect(formatGrams(Decimal.parse('10'), locale: 'en_US'), '10');
    });

    test('value of 9.95 rounds up into integer regime (10)', () {
      // 9.95 has abs() < 10 → one-decimal regime → rounds half-up to 10.0.
      // We assert the one-decimal regime wins for the threshold check; the
      // formatter then renders the rounded value.
      expect(formatGrams(Decimal.parse('9.95'), locale: 'en_US'), '10.0');
    });

    test('large integer values render with thousands separator', () {
      expect(formatGrams(Decimal.parse('1250'), locale: 'en_US'), '1,250');
    });

    test('negative small values keep one decimal', () {
      expect(formatGrams(Decimal.parse('-2.5'), locale: 'en_US'), '-2.5');
    });
  });
}
