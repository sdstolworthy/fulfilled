import 'package:decimal/decimal.dart';
import 'package:intl/intl.dart';

import '../_rounding.dart';

/// Energy formatters. v1 is kcal-only.
///
/// kJ ships in v2 alongside a `User.energy_unit` preference — see PM
/// Display Units Principle. Until then the conversion factor is not in
/// this module; we are explicitly not shipping kJ math.
///
/// kcal renders as an integer everywhere. **Rounding is half-to-even**
/// (banker's, PM §10 #9) — this matches the server's `f64::round()`
/// behavior so client and server agree on the displayed integer given
/// the same Decimal input. See `lib/domain/_rounding.dart`.
///
/// Sub-kcal precision is meaningless on a calorie label and would jitter
/// the ring every tick. Thousands separator comes from the active locale.

String formatKcal(Decimal kcal, {String? locale}) {
  final rounded = roundHalfToEven(kcal);
  final formatter = NumberFormat.decimalPattern(locale);
  return formatter.format(rounded);
}
