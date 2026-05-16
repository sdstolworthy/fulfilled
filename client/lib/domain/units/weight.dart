import 'package:decimal/decimal.dart';
import 'package:intl/intl.dart';

import '../_rounding.dart';

/// Body-weight formatters. v1 is kg-only — PM Risk 4.
///
/// The locale-aware decimal separator comes from `intl`: en-US renders
/// `70.5`, de-DE renders `70,5`. Always one decimal — **half-to-even**
/// (PM §10 #9). The .05 boundary resolves on the tenths digit:
/// `70.45 → 70.4` (4 is even), `70.55 → 70.6` (6 is even),
/// `70.05 → 70.0`.
///
/// TODO(v2): `formatWeightLb(Decimal kg) → String` once the
/// `User.weight_unit` field exists on the wire and onboarding asks for a
/// preference. Conversion factor is `kg × 2.2046226`. Do **not** add this
/// before the preference exists — shipping a units toggle without storage
/// is the exact bug PM Risk 4 forbids.

String formatWeightKg(Decimal kg, {String? locale}) {
  final formatter = NumberFormat.decimalPatternDigits(
    locale: locale,
    decimalDigits: 1,
  );
  // Round to one decimal place half-to-even using Decimal arithmetic, then
  // hand the resulting double to intl for separator placement. We never let
  // a wire Decimal touch the double constructor — only the already-rounded
  // value, where the round trip is safe.
  final rounded = roundHalfToEvenScaled(kg, 1);
  return formatter.format(rounded.toDouble());
}
