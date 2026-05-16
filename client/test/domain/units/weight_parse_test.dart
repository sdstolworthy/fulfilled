import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/units/weight.dart';

/// Tests for `parseWeightToKg` / `parseStoneToKg` — LU-003.
///
/// Round-trip stability is asserted at the kg-storage boundary
/// (formatted lb after parse should differ by at most 0.1 lb from the
/// original input, per PM §3 "Inputs"). The stone string overload
/// accepts the three shapes documented on the helper.
void main() {
  group('parseWeightToKg — kg branch', () {
    test('en-US dot separator: "70.5" → 70.5 kg', () {
      expect(
        parseWeightToKg('70.5', WeightUnit.kg),
        Decimal.parse('70.5'),
      );
    });

    test('de-DE comma separator: "70,5" → 70.5 kg', () {
      expect(
        parseWeightToKg('70,5', WeightUnit.kg),
        Decimal.parse('70.5'),
      );
    });

    test('trims surrounding whitespace', () {
      expect(
        parseWeightToKg('  70.5  ', WeightUnit.kg),
        Decimal.parse('70.5'),
      );
    });

    test('throws FormatException on garbage', () {
      expect(
        () => parseWeightToKg('not a number', WeightUnit.kg),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws FormatException on empty input', () {
      expect(
        () => parseWeightToKg('', WeightUnit.kg),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('parseWeightToKg — lb branch', () {
    test('"175.1" lb → 175.1 * 0.45359237 kg', () {
      final kg = parseWeightToKg('175.1', WeightUnit.lb);
      final expected = Decimal.parse('175.1') * Decimal.parse('0.45359237');
      expect(kg, expected);
    });

    test('comma separator tolerated in lb input ("175,1")', () {
      final kg = parseWeightToKg('175,1', WeightUnit.lb);
      final expected = Decimal.parse('175.1') * Decimal.parse('0.45359237');
      expect(kg, expected);
    });

    test(
        'round-trip stability — entered lb re-displays within ≤ 0.1 lb '
        '(within scale-1 resolution)',
        () {
      // PM §3 "Inputs" caveat: parse 175.1 lb → kg → format lb may show
      // 175.1 OR 175.0 depending on half-to-even; either is fine, the
      // drift is below scale resolution.
      final kg = parseWeightToKg('175.1', WeightUnit.lb);
      final back = formatWeight(kg, WeightUnit.lb, locale: 'en_US');
      expect(<String>['175.0', '175.1'], contains(back));
    });
  });

  group('parseWeightToKg — st string overload', () {
    final expectedTwelveSeven =
        Decimal.fromInt(12 * 14 + 7) * Decimal.parse('0.45359237');

    test('"12 7" composite parses', () {
      expect(parseWeightToKg('12 7', WeightUnit.st), expectedTwelveSeven);
    });

    test('"12 st 7 lb" spelled-out parses', () {
      expect(
        parseWeightToKg('12 st 7 lb', WeightUnit.st),
        expectedTwelveSeven,
      );
    });

    test('"12" bare stones parses as 12 st 0 lb', () {
      final expected =
          Decimal.fromInt(12 * 14) * Decimal.parse('0.45359237');
      expect(parseWeightToKg('12', WeightUnit.st), expected);
    });

    test('parses zero composite "0 st 0 lb" → 0 kg', () {
      expect(parseWeightToKg('0 st 0 lb', WeightUnit.st), Decimal.zero);
    });

    test('throws FormatException on non-numeric stone string', () {
      expect(
        () => parseWeightToKg('twelve seven', WeightUnit.st),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws FormatException on too many parts', () {
      expect(
        () => parseWeightToKg('12 7 3', WeightUnit.st),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('parseStoneToKg — typed overload', () {
    test('(12, 7) → (12*14+7) * 0.45359237 kg', () {
      final expected =
          Decimal.fromInt(12 * 14 + 7) * Decimal.parse('0.45359237');
      expect(parseStoneToKg(12, 7), expected);
    });

    test('(0, 0) → 0 kg', () {
      expect(parseStoneToKg(0, 0), Decimal.zero);
    });

    test('(12, 0) → 168 lb in kg', () {
      final expected =
          Decimal.fromInt(168) * Decimal.parse('0.45359237');
      expect(parseStoneToKg(12, 0), expected);
    });

    test('round-trip: parseStoneToKg(12, 7) → formatWeight(.st) → "12 st 7 lb"',
        () {
      final kg = parseStoneToKg(12, 7);
      expect(formatWeight(kg, WeightUnit.st), '12 st 7 lb');
    });

    test('round-trip: parseStoneToKg(12, 0) → formatWeight(.st) → "12 st"',
        () {
      final kg = parseStoneToKg(12, 0);
      expect(formatWeight(kg, WeightUnit.st), '12 st');
    });

    test('throws ArgumentError on negative stones', () {
      expect(() => parseStoneToKg(-1, 0), throwsArgumentError);
    });

    test('throws ArgumentError on negative pounds', () {
      expect(() => parseStoneToKg(0, -1), throwsArgumentError);
    });
  });

  group('round-trip parse → format', () {
    test('kg: "70.5" → 70.5 kg → "70.5"', () {
      final kg = parseWeightToKg('70.5', WeightUnit.kg);
      expect(formatWeight(kg, WeightUnit.kg, locale: 'en_US'), '70.5');
    });

    test('stone composite stability for "12 st 13 lb"', () {
      // 12 st 13 lb = 181 lb. Round-trips cleanly through Decimal.
      final kg = parseWeightToKg('12 st 13 lb', WeightUnit.st);
      expect(formatWeight(kg, WeightUnit.st), '12 st 13 lb');
    });
  });
}
