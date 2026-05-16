import 'package:decimal/decimal.dart';
import 'package:intl/intl.dart';

/// Macro / gram formatters. Architect Q9 default (PM-blessed in the Display
/// Units Principle table):
///
/// - For `>= 10 g`: render an integer (round half-up). Sub-gram precision on
///   a 30 g protein scoop is noise.
/// - For `< 10 g`: render one decimal place. At low values the decimal is
///   the difference between "0" and "0.5", which matters to power users.
///
/// Sign and magnitude are handled symmetrically — negative values are not
/// expected on the wire but defensive callers may pass them.

String formatGrams(Decimal grams, {String? locale}) {
  final abs = grams.abs();
  final ten = Decimal.fromInt(10);

  if (abs >= ten) {
    final rounded = grams.round(scale: 0).toBigInt();
    final formatter = NumberFormat.decimalPattern(locale);
    return formatter.format(rounded.toInt());
  }

  final formatter = NumberFormat.decimalPatternDigits(
    locale: locale,
    decimalDigits: 1,
  );
  final rounded = grams.round(scale: 1);
  return formatter.format(rounded.toDouble());
}
