import 'package:decimal/decimal.dart';
import 'package:intl/intl.dart';

/// Energy formatters. v1 is kcal-only.
///
/// kJ ships in v2 alongside a `User.energy_unit` preference — see PM
/// Display Units Principle. Until then the conversion factor is not in
/// this module; we are explicitly not shipping kJ math.
///
/// kcal renders as an integer everywhere (round half-up). Sub-kcal
/// precision is meaningless on a calorie label and would jitter the ring
/// every tick. Thousands separator comes from the active locale.

String formatKcal(Decimal kcal, {String? locale}) {
  final rounded = kcal.round(scale: 0).toBigInt();
  final formatter = NumberFormat.decimalPattern(locale);
  return formatter.format(rounded.toInt());
}
