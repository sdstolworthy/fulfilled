import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/units/weight.dart';

/// Tests for `formatWeight` / `formatWeightWithUnit` — LU-003.
///
/// kg cases mirror the existing `formatWeightKg` tests at parity (the
/// kg branch IS the old body, now routed through `formatWeight`). lb
/// cases cover the half-to-even rule at one decimal. Stone cases
/// cover the composite carry rule from architect §3.7.
void main() {
  group('formatWeight — kg', () {
    test('exact 70 renders with the trailing zero', () {
      expect(
        formatWeight(Decimal.parse('70'), WeightUnit.kg, locale: 'en_US'),
        '70.0',
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

    test('half-to-even on tenths: 70.45 → 70.4 (4 is even)', () {
      expect(
        formatWeight(Decimal.parse('70.45'), WeightUnit.kg, locale: 'en_US'),
        '70.4',
      );
    });

    test('half-to-even on tenths: 70.55 → 70.6 (6 is even)', () {
      expect(
        formatWeight(Decimal.parse('70.55'), WeightUnit.kg, locale: 'en_US'),
        '70.6',
      );
    });

    test('zero renders as "0.0"', () {
      expect(
        formatWeight(Decimal.zero, WeightUnit.kg, locale: 'en_US'),
        '0.0',
      );
    });
  });

  group('formatWeight — lb', () {
    test('82.0 kg → 180.8 lb (half-to-even, hundredths = 7)', () {
      // 82.0 * 2.2046226218 = 180.77905...; tenths digit 7, hundredths
      // 7, half-to-even pushes up to 180.8.
      expect(
        formatWeight(Decimal.parse('82.0'), WeightUnit.lb, locale: 'en_US'),
        '180.8',
      );
    });

    test('79.4 kg → 175.0 lb (half-to-even, hundredths = 4 rounds down)',
        () {
      // 79.4 * 2.2046226218 = 175.04703...; the hundredths digit is 4,
      // so half-to-even floors the tenths to 175.0. Documents the
      // round-trip-stability caveat from PM §3 ("entered 175.1 lb may
      // re-display as 175.0 lb after the kg round-trip").
      expect(
        formatWeight(Decimal.parse('79.4'), WeightUnit.lb, locale: 'en_US'),
        '175.0',
      );
    });

    test('exact 0 kg → 0.0 lb', () {
      expect(
        formatWeight(Decimal.zero, WeightUnit.lb, locale: 'en_US'),
        '0.0',
      );
    });

    test('locale-aware separator: de_DE renders a comma', () {
      // 82.0 kg → 180.8 lb. de-DE writes "180,8".
      expect(
        formatWeight(Decimal.parse('82.0'), WeightUnit.lb, locale: 'de_DE'),
        '180,8',
      );
    });
  });

  group('formatWeight — st (composite)', () {
    test('0 kg → "0 st" (remainder-zero branch)', () {
      expect(formatWeight(Decimal.zero, WeightUnit.st), '0 st');
    });

    test('~1 st input → "1 st" (carry edge: 14 lb rounds clean)', () {
      // 6.35 kg → 13.9993... lb → rounds half-to-even to 14 → 1 st 0 lb.
      expect(formatWeight(Decimal.parse('6.35'), WeightUnit.st), '1 st');
    });

    test('~100 lb input → "7 st 2 lb"', () {
      // 45.36 kg → 99.991... lb → 100 → 100 / 14 = 7 r 2.
      expect(formatWeight(Decimal.parse('45.36'), WeightUnit.st), '7 st 2 lb');
    });

    test('exactly 12 st (168 lb) — no remainder line', () {
      // 76.2 kg → 167.992... lb → 168 → 168 / 14 = 12 r 0.
      expect(formatWeight(Decimal.parse('76.2'), WeightUnit.st), '12 st');
    });

    test('12 st 13 lb (181 lb) — just below the carry to 13 st', () {
      // 82.1 kg → 181.00... lb → 181 → 181 / 14 = 12 r 13.
      expect(
        formatWeight(Decimal.parse('82.1'), WeightUnit.st),
        '12 st 13 lb',
      );
    });

    test('carry edge: 88.9 kg → "14 st" (195.99 lb rounds to 196)', () {
      // 88.9 * 2.2046226218 = 195.991... → 196 → 196 / 14 = 14 r 0.
      // The architect's named carry edge: NOT "13 st 14 lb".
      expect(formatWeight(Decimal.parse('88.9'), WeightUnit.st), '14 st');
    });

    test('exact 20 st (280 lb)', () {
      // 127.0 kg → 279.98... lb → 280 → 280 / 14 = 20 r 0.
      expect(formatWeight(Decimal.parse('127.0'), WeightUnit.st), '20 st');
    });
  });

  group('formatWeightWithUnit', () {
    test('kg appends " kg" suffix', () {
      expect(
        formatWeightWithUnit(Decimal.parse('79.4'), WeightUnit.kg,
            locale: 'en_US'),
        '79.4 kg',
      );
    });

    test('lb appends " lb" suffix', () {
      expect(
        formatWeightWithUnit(Decimal.parse('82.0'), WeightUnit.lb,
            locale: 'en_US'),
        '180.8 lb',
      );
    });

    test('st does NOT append a suffix (composite is already inline)', () {
      // 82.1 kg → "12 st 13 lb" — no trailing " st".
      expect(
        formatWeightWithUnit(Decimal.parse('82.1'), WeightUnit.st),
        '12 st 13 lb',
      );
    });

    test('st remainder-zero composite still has no extra suffix', () {
      expect(
        formatWeightWithUnit(Decimal.parse('76.2'), WeightUnit.st),
        '12 st',
      );
    });
  });

  group('formatWeightKg (deprecated wrapper) — still works', () {
    // ignore: deprecated_member_use_from_same_package
    test('routes through to the kg branch', () {
      // ignore: deprecated_member_use_from_same_package
      expect(formatWeightKg(Decimal.parse('70'), locale: 'en_US'), '70.0');
    });
  });
}
