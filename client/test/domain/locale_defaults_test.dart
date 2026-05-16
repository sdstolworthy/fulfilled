import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/locale_defaults.dart';

/// Tests for `defaultWeightUnitForLocale` — LU-003.
///
/// All cases use `countryCodeOverride` (the test seam — architect §3.4)
/// so we don't take a dependency on `WidgetsBinding` and the platform
/// dispatcher.
void main() {
  group('defaultWeightUnitForLocale', () {
    test('US → lb', () {
      expect(
        defaultWeightUnitForLocale(countryCodeOverride: 'US'),
        WeightUnit.lb,
      );
    });

    test('LR (Liberia) → lb (non-metric carve-out)', () {
      expect(
        defaultWeightUnitForLocale(countryCodeOverride: 'LR'),
        WeightUnit.lb,
      );
    });

    test('MM (Myanmar) → lb (non-metric carve-out)', () {
      expect(
        defaultWeightUnitForLocale(countryCodeOverride: 'MM'),
        WeightUnit.lb,
      );
    });

    test('GB → st', () {
      expect(
        defaultWeightUnitForLocale(countryCodeOverride: 'GB'),
        WeightUnit.st,
      );
    });

    test('IM (Isle of Man) → st (Crown Dependency)', () {
      expect(
        defaultWeightUnitForLocale(countryCodeOverride: 'IM'),
        WeightUnit.st,
      );
    });

    test('JE (Jersey) → st (Crown Dependency)', () {
      expect(
        defaultWeightUnitForLocale(countryCodeOverride: 'JE'),
        WeightUnit.st,
      );
    });

    test('GG (Guernsey) → st (Crown Dependency)', () {
      expect(
        defaultWeightUnitForLocale(countryCodeOverride: 'GG'),
        WeightUnit.st,
      );
    });

    test('DE → kg (metric default)', () {
      expect(
        defaultWeightUnitForLocale(countryCodeOverride: 'DE'),
        WeightUnit.kg,
      );
    });

    test('JP → kg (metric default, non-special-cased)', () {
      expect(
        defaultWeightUnitForLocale(countryCodeOverride: 'JP'),
        WeightUnit.kg,
      );
    });

    test('empty string override → kg fallback', () {
      // PM doc §3 "Decision: locale default" — empty country code falls
      // through to kg.
      expect(
        defaultWeightUnitForLocale(countryCodeOverride: ''),
        WeightUnit.kg,
      );
    });

    test('unknown country code → kg fallback', () {
      expect(
        defaultWeightUnitForLocale(countryCodeOverride: 'XX'),
        WeightUnit.kg,
      );
    });
  });
}
