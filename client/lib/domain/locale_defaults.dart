import 'package:flutter/widgets.dart';

import 'enums.dart';

/// Best-guess weight unit from the platform locale's country code.
///
/// Used **once** at first onboarding submit (when the User is being
/// created and `User.weight_unit` is not yet on the wire). Not re-read
/// on subsequent launches — once persisted on `User.weight_unit`, the
/// server is canonical.
///
/// Fallback chain (PM doc §3 "locale default"):
///   - `US`, `LR` (Liberia), `MM` (Myanmar) → `lb` (the three
///     non-metric countries)
///   - `GB` + the British Crown Dependencies (`IM` Isle of Man, `JE`
///     Jersey, `GG` Guernsey) → `st`
///   - everything else → `kg`
///   - `null` / `''` country code → `kg`
///
/// [countryCodeOverride] is the test seam — pass an ISO-3166 alpha-2
/// code (or `null`) directly instead of relying on `WidgetsBinding`'s
/// platform dispatcher. Architect §3.4 picked this over
/// `localesTestValue` for ergonomics: no `WidgetsBinding` to spin up
/// in unit tests.
WeightUnit defaultWeightUnitForLocale({String? countryCodeOverride}) {
  // Read from the platform dispatcher only when no override is
  // supplied. The dispatcher is available without a `WidgetsBinding`
  // attached (Flutter framework provides a sensible default), but
  // tests should pass `countryCodeOverride` to avoid taking a
  // dependency on the embedder.
  final cc = countryCodeOverride ??
      WidgetsBinding.instance.platformDispatcher.locale.countryCode;
  if (cc == null || cc.isEmpty) return WeightUnit.kg;
  switch (cc) {
    case 'US':
    case 'LR':
    case 'MM':
      return WeightUnit.lb;
    case 'GB':
    case 'IM':
    case 'JE':
    case 'GG':
      return WeightUnit.st;
    default:
      return WeightUnit.kg;
  }
}
