import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/locale_defaults.dart';

/// Tests for `defaultUnitsForLocale` + the per-axis wrappers
/// `defaultWeightUnitForLocale` / `defaultHeightUnitForLocale`
/// (architect §2 Refactor 1 — QL-102).
///
/// All cases use `countryCodeOverride` (the test seam — architect §3.4)
/// so we don't take a dependency on `WidgetsBinding` and the platform
/// dispatcher.
void main() {
  group('defaultUnitsForLocale', () {
    test('US → (lb, ftIn)', () {
      final r = defaultUnitsForLocale(countryCodeOverride: 'US');
      expect(r.weightUnit, WeightUnit.lb);
      expect(r.heightUnit, HeightUnit.ftIn);
    });

    test('LR (Liberia) → (lb, ftIn) — non-metric carve-out', () {
      final r = defaultUnitsForLocale(countryCodeOverride: 'LR');
      expect(r.weightUnit, WeightUnit.lb);
      expect(r.heightUnit, HeightUnit.ftIn);
    });

    test('MM (Myanmar) → (lb, ftIn) — non-metric carve-out', () {
      final r = defaultUnitsForLocale(countryCodeOverride: 'MM');
      expect(r.weightUnit, WeightUnit.lb);
      expect(r.heightUnit, HeightUnit.ftIn);
    });

    test('GB → (st, ftIn)', () {
      final r = defaultUnitsForLocale(countryCodeOverride: 'GB');
      expect(r.weightUnit, WeightUnit.st);
      expect(r.heightUnit, HeightUnit.ftIn);
    });

    test('IM (Isle of Man) → (st, ftIn) — Crown Dependency', () {
      final r = defaultUnitsForLocale(countryCodeOverride: 'IM');
      expect(r.weightUnit, WeightUnit.st);
      expect(r.heightUnit, HeightUnit.ftIn);
    });

    test('JE (Jersey) → (st, ftIn) — Crown Dependency', () {
      final r = defaultUnitsForLocale(countryCodeOverride: 'JE');
      expect(r.weightUnit, WeightUnit.st);
      expect(r.heightUnit, HeightUnit.ftIn);
    });

    test('GG (Guernsey) → (st, ftIn) — Crown Dependency', () {
      final r = defaultUnitsForLocale(countryCodeOverride: 'GG');
      expect(r.weightUnit, WeightUnit.st);
      expect(r.heightUnit, HeightUnit.ftIn);
    });

    test('DE → (kg, cm) — metric default', () {
      final r = defaultUnitsForLocale(countryCodeOverride: 'DE');
      expect(r.weightUnit, WeightUnit.kg);
      expect(r.heightUnit, HeightUnit.cm);
    });

    test('JP → (kg, cm) — metric default, non-special-cased', () {
      final r = defaultUnitsForLocale(countryCodeOverride: 'JP');
      expect(r.weightUnit, WeightUnit.kg);
      expect(r.heightUnit, HeightUnit.cm);
    });

    test('empty string override → (kg, cm) fallback', () {
      final r = defaultUnitsForLocale(countryCodeOverride: '');
      expect(r.weightUnit, WeightUnit.kg);
      expect(r.heightUnit, HeightUnit.cm);
    });

    test('unknown country code → (kg, cm) fallback', () {
      final r = defaultUnitsForLocale(countryCodeOverride: 'XX');
      expect(r.weightUnit, WeightUnit.kg);
      expect(r.heightUnit, HeightUnit.cm);
    });
  });

  group('UnitDefaults value semantics', () {
    test('equality and hashCode honour both fields', () {
      const a = UnitDefaults(
        weightUnit: WeightUnit.lb,
        heightUnit: HeightUnit.ftIn,
      );
      const b = UnitDefaults(
        weightUnit: WeightUnit.lb,
        heightUnit: HeightUnit.ftIn,
      );
      const differentWeight = UnitDefaults(
        weightUnit: WeightUnit.kg,
        heightUnit: HeightUnit.ftIn,
      );
      const differentHeight = UnitDefaults(
        weightUnit: WeightUnit.lb,
        heightUnit: HeightUnit.cm,
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(differentWeight));
      expect(a, isNot(differentHeight));
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // Deprecated per-axis wrappers — kept for one release of source-compat.
  // The body of each is `defaultUnitsForLocale(...).{weight,height}Unit` so
  // these tests double as a behaviour-parity check.
  // ───────────────────────────────────────────────────────────────────────

  group('defaultWeightUnitForLocale (deprecated wrapper)', () {
    test('US → lb', () {
      expect(
        // ignore: deprecated_member_use_from_same_package
        defaultWeightUnitForLocale(countryCodeOverride: 'US'),
        WeightUnit.lb,
      );
    });

    test('GB → st', () {
      expect(
        // ignore: deprecated_member_use_from_same_package
        defaultWeightUnitForLocale(countryCodeOverride: 'GB'),
        WeightUnit.st,
      );
    });

    test('DE → kg', () {
      expect(
        // ignore: deprecated_member_use_from_same_package
        defaultWeightUnitForLocale(countryCodeOverride: 'DE'),
        WeightUnit.kg,
      );
    });

    test('empty string override → kg fallback', () {
      expect(
        // ignore: deprecated_member_use_from_same_package
        defaultWeightUnitForLocale(countryCodeOverride: ''),
        WeightUnit.kg,
      );
    });

    test('unknown country code → kg fallback', () {
      expect(
        // ignore: deprecated_member_use_from_same_package
        defaultWeightUnitForLocale(countryCodeOverride: 'XX'),
        WeightUnit.kg,
      );
    });
  });

  group('defaultHeightUnitForLocale (deprecated wrapper)', () {
    test('US → ftIn', () {
      expect(
        // ignore: deprecated_member_use_from_same_package
        defaultHeightUnitForLocale(countryCodeOverride: 'US'),
        HeightUnit.ftIn,
      );
    });

    test('GB → ftIn', () {
      expect(
        // ignore: deprecated_member_use_from_same_package
        defaultHeightUnitForLocale(countryCodeOverride: 'GB'),
        HeightUnit.ftIn,
      );
    });

    test('DE → cm', () {
      expect(
        // ignore: deprecated_member_use_from_same_package
        defaultHeightUnitForLocale(countryCodeOverride: 'DE'),
        HeightUnit.cm,
      );
    });

    test('empty string override → cm fallback', () {
      expect(
        // ignore: deprecated_member_use_from_same_package
        defaultHeightUnitForLocale(countryCodeOverride: ''),
        HeightUnit.cm,
      );
    });

    test('unknown country code → cm fallback', () {
      expect(
        // ignore: deprecated_member_use_from_same_package
        defaultHeightUnitForLocale(countryCodeOverride: 'XX'),
        HeightUnit.cm,
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // HeightUnit enum wire / fromWire round-trip — keeps the enum honest
  // (T-17 — boundary errors surface at parse, not in a widget).
  // ───────────────────────────────────────────────────────────────────────

  group('HeightUnit wire / fromWire', () {
    test('cm round-trip', () {
      expect(HeightUnit.cm.wire, 'cm');
      expect(HeightUnit.fromWire('cm'), HeightUnit.cm);
    });

    test('ftIn round-trip (underscore wire string)', () {
      expect(HeightUnit.ftIn.wire, 'ft_in');
      expect(HeightUnit.fromWire('ft_in'), HeightUnit.ftIn);
    });

    test('fromWire is strict — throws ArgumentError on unknown', () {
      expect(() => HeightUnit.fromWire('feet'), throwsArgumentError);
      expect(() => HeightUnit.fromWire(''), throwsArgumentError);
    });

    test('short and long labels match the chooser copy', () {
      expect(HeightUnit.cm.shortLabel, 'cm');
      expect(HeightUnit.cm.longLabel, 'centimeters');
      expect(HeightUnit.ftIn.shortLabel, 'ft·in');
      expect(HeightUnit.ftIn.longLabel, 'feet and inches');
    });
  });
}
