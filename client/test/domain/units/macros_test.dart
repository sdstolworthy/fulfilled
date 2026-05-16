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

    test('value of 9.4 renders 9.4 (PM acceptance case)', () {
      expect(formatGrams(Decimal.parse('9.4'), locale: 'en_US'), '9.4');
    });

    test('value of 10 renders as integer', () {
      expect(formatGrams(Decimal.parse('10'), locale: 'en_US'), '10');
    });

    test('value of 9.95 rounds up into integer regime (10)', () {
      // 9.95 has abs() < 10 → one-decimal regime → rounds half-to-even
      // on the tenths digit: tenths goes from 9 (odd) to even = 10.
      // The formatter renders the rounded value with one decimal digit.
      expect(formatGrams(Decimal.parse('9.95'), locale: 'en_US'), '10.0');
    });

    test('large integer values render with thousands separator', () {
      expect(formatGrams(Decimal.parse('1250'), locale: 'en_US'), '1,250');
    });

    test('negative small values keep one decimal', () {
      expect(formatGrams(Decimal.parse('-2.5'), locale: 'en_US'), '-2.5');
    });

    // ----- Half-to-even boundaries (PM §10 #9, T-011 acceptance) -----

    test('10.5 g rounds half-to-even to 10 (10 is even)', () {
      expect(formatGrams(Decimal.parse('10.5'), locale: 'en_US'), '10');
    });

    test('11.5 g rounds half-to-even to 12 (12 is even)', () {
      expect(formatGrams(Decimal.parse('11.5'), locale: 'en_US'), '12');
    });

    test('99.5 g rounds half-to-even to 100 (100 is even)', () {
      expect(formatGrams(Decimal.parse('99.5'), locale: 'en_US'), '100');
    });

    test('10.4 g rounds half-to-even to 10 (frac < .5)', () {
      expect(formatGrams(Decimal.parse('10.4'), locale: 'en_US'), '10');
    });

    test('one-decimal regime rounds tenths half-to-even', () {
      // 5.45 → tenths 4 (even) wins, so 5.4.
      expect(formatGrams(Decimal.parse('5.45'), locale: 'en_US'), '5.4');
      // 5.55 → tenths 6 (even) wins, so 5.6.
      expect(formatGrams(Decimal.parse('5.55'), locale: 'en_US'), '5.6');
    });
  });
}
