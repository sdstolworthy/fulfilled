import 'package:decimal/decimal.dart';
import 'package:intl/intl.dart';

import '../_rounding.dart';

/// Macro / gram formatters. PM §10 #9 (decimal precision table):
///
/// - For `abs(value) >= 10 g`: render an integer (half-to-even). Sub-gram
///   precision on a 30 g protein scoop is noise.
/// - For `abs(value) < 10 g`: render one decimal place (half-to-even). At
///   low values the decimal is the difference between "0" and "0.5",
///   which matters to power users.
///
/// Rounding is **half-to-even** (banker's) to match the server. The
/// regime threshold is on the *unrounded* magnitude — `9.95` rounds to
/// `10.0` in the one-decimal regime, never up into the integer regime
/// (the threshold check happens before the rounding).
///
/// Sign and magnitude are handled symmetrically — negative values are not
/// expected on the wire but defensive callers may pass them.

final Decimal _ten = Decimal.fromInt(10);

String formatGrams(Decimal grams, {String? locale}) {
  if (grams.abs() >= _ten) {
    final rounded = roundHalfToEven(grams);
    final formatter = NumberFormat.decimalPattern(locale);
    return formatter.format(rounded);
  }

  final formatter = NumberFormat.decimalPatternDigits(
    locale: locale,
    decimalDigits: 1,
  );
  final rounded = roundHalfToEvenScaled(grams, 1);
  return formatter.format(rounded.toDouble());
}
