import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/units/sodium.dart';

void main() {
  group('gramsToMilligrams', () {
    test('multiplies by 1000 exactly', () {
      expect(
        gramsToMilligrams(Decimal.parse('0.13')),
        Decimal.parse('130'),
      );
    });

    test('preserves Decimal precision (no double round-trip)', () {
      // 0.1 + 0.2 == 0.3 in Decimal; would be 0.30000...4 in double.
      final sum = Decimal.parse('0.1') + Decimal.parse('0.2');
      expect(gramsToMilligrams(sum), Decimal.parse('300.0'));
    });

    test('handles zero', () {
      expect(gramsToMilligrams(Decimal.zero), Decimal.zero);
    });
  });

  group('formatSodiumMg', () {
    test('integer rendering under 1000', () {
      expect(formatSodiumMg(Decimal.parse('130'), locale: 'en_US'), '130');
    });

    test('rounds half-to-even to integer mg (PM §10 #9)', () {
      expect(formatSodiumMg(Decimal.parse('130.4'), locale: 'en_US'), '130');
      // 130.5 → 130 (even); 131.5 → 132 (even).
      expect(formatSodiumMg(Decimal.parse('130.5'), locale: 'en_US'), '130');
      expect(formatSodiumMg(Decimal.parse('131.5'), locale: 'en_US'), '132');
      expect(formatSodiumMg(Decimal.parse('130.9'), locale: 'en_US'), '131');
    });

    test('integer values pass through unchanged', () {
      expect(formatSodiumMg(Decimal.parse('245'), locale: 'en_US'), '245');
      expect(formatSodiumMg(Decimal.zero, locale: 'en_US'), '0');
    });

    test('thousands separator over 1000 in en_US', () {
      expect(formatSodiumMg(Decimal.parse('1250'), locale: 'en_US'), '1,250');
      expect(formatSodiumMg(Decimal.parse('12500'), locale: 'en_US'), '12,500');
    });

    test('round-trip from grams → mg → formatted', () {
      final mg = gramsToMilligrams(Decimal.parse('1.25'));
      expect(formatSodiumMg(mg, locale: 'en_US'), '1,250');
    });
  });
}
