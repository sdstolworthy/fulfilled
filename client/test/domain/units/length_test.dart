import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/units/length.dart';

/// Tests for `formatHeight` / `formatHeightWithUnit` /
/// `parseHeightToCm` / `parseFeetInchesToCm` — QL-103.
///
/// ftIn cases mirror the architect §5.5 carry-edge table verbatim,
/// including the 182 cm carry that's the analog of the stone
/// composite's `13 st 13.6 lb → 14 st` carry. cm cases pin the
/// integer-cm display and the locale-tolerant comma parse path.
void main() {
  group('formatHeight — cm', () {
    test('integer cm renders without decimal place', () {
      expect(
        formatHeight(Decimal.fromInt(175), HeightUnit.cm, locale: 'en_US'),
        '175',
      );
    });

    test('half-to-even rounds 175.5 to 176 (6 is even)', () {
      expect(
        formatHeight(Decimal.parse('175.5'), HeightUnit.cm, locale: 'en_US'),
        '176',
      );
    });

    test('half-to-even rounds 174.5 to 174 (4 is even)', () {
      expect(
        formatHeight(Decimal.parse('174.5'), HeightUnit.cm, locale: 'en_US'),
        '174',
      );
    });

    test('zero renders as "0"', () {
      expect(
        formatHeight(Decimal.zero, HeightUnit.cm, locale: 'en_US'),
        '0',
      );
    });

    test('locale separator: de-DE has no decimal for integer cm', () {
      // Integer cm has no fraction part, so the locale separator never
      // surfaces. The thousands separator would (`1,234` en-US vs
      // `1.234` de-DE), but the body-height range stays well below
      // 1000. Pin the en-US/de-DE parity for a known integer.
      expect(
        formatHeight(Decimal.fromInt(175), HeightUnit.cm, locale: 'de_DE'),
        '175',
      );
    });
  });

  group('formatHeight — ftIn', () {
    // The full architect §5.5 carry-edge table.

    test('0 cm → "0 ft" (edge: zero)', () {
      expect(formatHeight(Decimal.zero, HeightUnit.ftIn), '0 ft');
    });

    test('30.48 cm → "1 ft" (12 inches exact)', () {
      expect(
        formatHeight(Decimal.parse('30.48'), HeightUnit.ftIn),
        '1 ft',
      );
    });

    test('152.4 cm → "5 ft" (60 inches exact, drops the " 0 in")', () {
      expect(
        formatHeight(Decimal.parse('152.4'), HeightUnit.ftIn),
        '5 ft',
      );
    });

    test('175 cm → "5 ft 9 in" (standard adult)', () {
      expect(
        formatHeight(Decimal.fromInt(175), HeightUnit.ftIn),
        '5 ft 9 in',
      );
    });

    test('182.88 cm → "6 ft" (exact six-foot, 72 inches)', () {
      expect(
        formatHeight(Decimal.parse('182.88'), HeightUnit.ftIn),
        '6 ft',
      );
    });

    test(
      '182 cm → "6 ft" (carry edge: 71.65… rounds to 72 → carries; '
      'NOT "5 ft 12 in")',
      () {
        expect(
          formatHeight(Decimal.fromInt(182), HeightUnit.ftIn),
          '6 ft',
        );
      },
    );

    test('181 cm → "5 ft 11 in" (just below carry: 71.26… → 71)', () {
      expect(
        formatHeight(Decimal.fromInt(181), HeightUnit.ftIn),
        '5 ft 11 in',
      );
    });

    test('200 cm → "6 ft 7 in" (tall adult)', () {
      expect(
        formatHeight(Decimal.fromInt(200), HeightUnit.ftIn),
        '6 ft 7 in',
      );
    });

    test('250 cm → "8 ft 2 in" (upper PM bound)', () {
      expect(
        formatHeight(Decimal.fromInt(250), HeightUnit.ftIn),
        '8 ft 2 in',
      );
    });
  });

  group('formatHeightWithUnit', () {
    test('cm appends " cm" suffix', () {
      expect(
        formatHeightWithUnit(
          Decimal.fromInt(175),
          HeightUnit.cm,
          locale: 'en_US',
        ),
        '175 cm',
      );
    });

    test('ftIn composite already includes units — no extra suffix', () {
      expect(
        formatHeightWithUnit(Decimal.fromInt(175), HeightUnit.ftIn),
        '5 ft 9 in',
      );
    });
  });

  group('parseHeightToCm — cm', () {
    test('parses an integer cm string', () {
      expect(
        parseHeightToCm('175', HeightUnit.cm),
        equals(Decimal.fromInt(175)),
      );
    });

    test('parses a decimal cm string', () {
      expect(
        parseHeightToCm('175.5', HeightUnit.cm),
        equals(Decimal.parse('175.5')),
      );
    });

    test('locale-tolerant: accepts comma as decimal separator', () {
      expect(
        parseHeightToCm('175,5', HeightUnit.cm),
        equals(Decimal.parse('175.5')),
      );
    });

    test('throws FormatException on garbage', () {
      expect(
        () => parseHeightToCm('not a number', HeightUnit.cm),
        throwsFormatException,
      );
    });

    test('throws FormatException on empty input', () {
      expect(
        () => parseHeightToCm('', HeightUnit.cm),
        throwsFormatException,
      );
    });
  });

  group('parseHeightToCm — ftIn (string overload)', () {
    test('"5" → 5 ft 0 in (treated as feet, inches=0)', () {
      // 5 ft × 12 × 2.54 = 152.4 cm → rounds to 152 (4 is even).
      expect(
        parseHeightToCm('5', HeightUnit.ftIn),
        equals(Decimal.fromInt(152)),
      );
    });

    test('"5 9" → 5 ft 9 in', () {
      // 69 in × 2.54 = 175.26 cm → rounds half-to-even to 175.
      expect(
        parseHeightToCm('5 9', HeightUnit.ftIn),
        equals(Decimal.fromInt(175)),
      );
    });

    test('"5 ft 9 in" — verbose form round-trips', () {
      expect(
        parseHeightToCm('5 ft 9 in', HeightUnit.ftIn),
        equals(Decimal.fromInt(175)),
      );
    });

    test('throws on garbage ftIn input', () {
      expect(
        () => parseHeightToCm('totally not a height', HeightUnit.ftIn),
        throwsFormatException,
      );
    });
  });

  group('parseFeetInchesToCm — typed overload', () {
    test('(5, 9) → 175 cm (rounded from 175.26)', () {
      expect(parseFeetInchesToCm(5, 9), equals(Decimal.fromInt(175)));
    });

    test('(6, 0) → 183 cm (rounded from 182.88)', () {
      expect(parseFeetInchesToCm(6, 0), equals(Decimal.fromInt(183)));
    });

    test('(0, 0) → 0 cm', () {
      expect(parseFeetInchesToCm(0, 0), equals(Decimal.zero));
    });

    test('(5, 0) → 152 cm (exact 152.4 → half-to-even to 152)', () {
      expect(parseFeetInchesToCm(5, 0), equals(Decimal.fromInt(152)));
    });

    test('negative feet throws ArgumentError', () {
      expect(
        () => parseFeetInchesToCm(-1, 0),
        throwsArgumentError,
      );
    });

    test('negative inches throws ArgumentError', () {
      expect(
        () => parseFeetInchesToCm(5, -1),
        throwsArgumentError,
      );
    });

    test('inches >= 12 throws ArgumentError (carry should happen first)', () {
      expect(
        () => parseFeetInchesToCm(5, 12),
        throwsArgumentError,
      );
    });
  });

  group('round-trip stability', () {
    test('175 cm round-trips through ftIn formatter → parser', () {
      // 175 cm renders as "5 ft 9 in"; parsing "5 ft 9 in" returns
      // 175 cm. Half-to-even at integer inches makes this stable.
      final rendered = formatHeight(
        Decimal.fromInt(175),
        HeightUnit.ftIn,
      );
      expect(rendered, '5 ft 9 in');
      expect(
        parseHeightToCm(rendered, HeightUnit.ftIn),
        equals(Decimal.fromInt(175)),
      );
    });
  });
}
