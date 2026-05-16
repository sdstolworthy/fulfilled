import 'package:flutter/widgets.dart';

import 'enums.dart';

/// All locale-derived display defaults in one pass.
///
/// The architect (§2 Refactor 1) unified the per-axis locale chains
/// behind a single function so the country-code switch is written once.
/// New display-unit axes (a hypothetical `EnergyUnit`, a future
/// date-format preference) plug into this record without forking the
/// fallback chain.
///
/// **Per-axis providers stay.** The architect explicitly ruled (§2.1)
/// against a unified `userPreferencesProvider` record at the provider
/// layer — `weightUnitProvider` and `heightUnitProvider` remain
/// separate so widget rebuilds stay granular (tenant T-18). The
/// unification lives only inside this locale-default seam.
class UnitDefaults {
  const UnitDefaults({required this.weightUnit, required this.heightUnit});

  final WeightUnit weightUnit;
  final HeightUnit heightUnit;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UnitDefaults &&
          other.weightUnit == weightUnit &&
          other.heightUnit == heightUnit;

  @override
  int get hashCode => Object.hash(weightUnit, heightUnit);

  @override
  String toString() =>
      'UnitDefaults(weightUnit: $weightUnit, heightUnit: $heightUnit)';
}

/// Best-guess locale-derived display defaults from the platform locale's
/// country code.
///
/// Used **once** at first onboarding submit (when the User is being
/// created and `User.weight_unit` / `User.height_unit` are not yet on
/// the wire). Not re-read on subsequent launches — once persisted on
/// the user record, the server is canonical.
///
/// Fallback chain (architect §2.2 — the joined weight + height chain):
///   - `US`, `LR` (Liberia), `MM` (Myanmar) → `(weight: lb, height: ftIn)`
///   - `GB` + the British Crown Dependencies (`IM` Isle of Man, `JE`
///     Jersey, `GG` Guernsey) → `(weight: st, height: ftIn)`
///   - everything else → `(weight: kg, height: cm)`
///   - `null` / `''` country code → `(weight: kg, height: cm)`
///
/// The two axes agree on the metric-edge countries (US/LR/MM/GB/IM/JE/GG
/// → imperial-flavoured) but diverge on the *which* imperial:
/// GB+Crown-Deps use `st` for weight while every imperial-leaning
/// locale uses `ftIn` for height. Matches the existing
/// [defaultWeightUnitForLocale] chain exactly so callers don't drift.
///
/// [countryCodeOverride] is the test seam — pass an ISO-3166 alpha-2
/// code (or `null`) directly instead of relying on `WidgetsBinding`'s
/// platform dispatcher.
UnitDefaults defaultUnitsForLocale({String? countryCodeOverride}) {
  // Read from the platform dispatcher only when no override is
  // supplied. The dispatcher is available without a `WidgetsBinding`
  // attached (Flutter framework provides a sensible default), but
  // tests should pass `countryCodeOverride` to avoid taking a
  // dependency on the embedder.
  final cc = countryCodeOverride ??
      WidgetsBinding.instance.platformDispatcher.locale.countryCode;
  if (cc == null || cc.isEmpty) {
    return const UnitDefaults(
      weightUnit: WeightUnit.kg,
      heightUnit: HeightUnit.cm,
    );
  }
  switch (cc) {
    case 'US':
    case 'LR':
    case 'MM':
      return const UnitDefaults(
        weightUnit: WeightUnit.lb,
        heightUnit: HeightUnit.ftIn,
      );
    case 'GB':
    case 'IM':
    case 'JE':
    case 'GG':
      return const UnitDefaults(
        weightUnit: WeightUnit.st,
        heightUnit: HeightUnit.ftIn,
      );
    default:
      return const UnitDefaults(
        weightUnit: WeightUnit.kg,
        heightUnit: HeightUnit.cm,
      );
  }
}

/// Best-guess weight unit from the platform locale's country code.
///
/// Kept as a thin wrapper around [defaultUnitsForLocale] for one
/// release of source-compat with the existing call sites in
/// `profile_providers.dart` / `draft_providers.dart`. The follow-up
/// sweep (QL-104) migrates those readers to the record and the wrapper
/// gets deleted.
@Deprecated('Use defaultUnitsForLocale(...).weightUnit.')
WeightUnit defaultWeightUnitForLocale({String? countryCodeOverride}) =>
    defaultUnitsForLocale(countryCodeOverride: countryCodeOverride).weightUnit;

/// Best-guess height unit from the platform locale's country code.
///
/// Symmetry-only wrapper around [defaultUnitsForLocale] so the
/// height-feature ticket (QL-001 client work) can be written without
/// the migration landing first. Annotated `@Deprecated` so new call
/// sites are nudged toward the record reader instead of a third
/// per-axis caller.
@Deprecated('Use defaultUnitsForLocale(...).heightUnit.')
HeightUnit defaultHeightUnitForLocale({String? countryCodeOverride}) =>
    defaultUnitsForLocale(countryCodeOverride: countryCodeOverride).heightUnit;
