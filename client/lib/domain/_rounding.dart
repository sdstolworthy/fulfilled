/// Half-to-even (banker's) rounding helpers — PM §10 #9.
///
/// `package:decimal` ^3.0.2 documents its `.round()` as half-away-from-zero,
/// which is the wrong mode for the server-match rule. So we floor + reason
/// about the fractional part by hand. Pure Decimal arithmetic; no IEEE-754
/// ever touches the value.
///
/// This file is the *one* canonical home for the rounding helper — see
/// architect §A6 note "one canonical function, used by both" and dev_tickets
/// T-011 "the half-to-even rounding helper lives in the lifted file; reuse
/// it." Callers: `domain/calories/estimate.dart` (BMR/TDEE/macro grams),
/// `domain/units/energy.dart` (formatKcal), `domain/units/macros.dart`
/// (formatGrams), `domain/units/weight.dart` (formatWeightKg),
/// `domain/units/sodium.dart` (formatSodiumMg), `domain/decimal_format.dart`
/// (formatQuantity, formatRate).
///
/// Semantics:
///   - If the fractional part is strictly less than 0.5, round toward
///     negative infinity (floor).
///   - If the fractional part is strictly greater than 0.5, round toward
///     positive infinity (ceil).
///   - If the fractional part is exactly 0.5, round to the nearest even
///     integer. (e.g. 1850.5 → 1850; 1851.5 → 1852; −0.5 → 0; −1.5 → −2.)
library;

import 'package:decimal/decimal.dart';

final Decimal _half = Decimal.parse('0.5');

/// Round [value] half-to-even to the nearest integer. See library docstring.
int roundHalfToEven(Decimal value) {
  // Floor toward -infinity. `Decimal.toBigInt()` truncates toward zero,
  // so for negative non-integer values we subtract one to land on the
  // mathematical floor.
  final truncated = value.toBigInt();
  final truncatedAsDecimal = Decimal.fromBigInt(truncated);
  final isNegativeWithFrac =
      value.compareTo(Decimal.zero) < 0 && truncatedAsDecimal != value;
  final floor = isNegativeWithFrac ? truncated - BigInt.one : truncated;
  final frac = value - Decimal.fromBigInt(floor); // in [0, 1)

  final compareHalf = frac.compareTo(_half);
  if (compareHalf < 0) {
    return floor.toInt();
  }
  if (compareHalf > 0) {
    return (floor + BigInt.one).toInt();
  }
  // Exactly .5 — round to even.
  if (floor.isEven) {
    return floor.toInt();
  }
  return (floor + BigInt.one).toInt();
}

/// Round [value] half-to-even to the given number of fractional digits.
///
/// `scale = 0` is equivalent to [roundHalfToEven] returning the value as a
/// Decimal rather than an int. `scale = 1` produces values like `78.4` /
/// `78.5`; the .05 boundary resolves to-even on the tenths digit:
/// `78.45` → `78.4` (4 is even), `78.55` → `78.6` (6 is even).
///
/// Returns a `Decimal` so the caller can hand it directly to `intl`'s
/// `NumberFormat` without a half-up double round-trip changing the answer.
Decimal roundHalfToEvenScaled(Decimal value, int scale) {
  if (scale < 0) {
    throw ArgumentError.value(scale, 'scale', 'must be non-negative');
  }
  if (scale == 0) {
    return Decimal.fromInt(roundHalfToEven(value));
  }
  // Shift the decimal point right by `scale` digits, round half-to-even to
  // an int, then shift back. Pure Decimal — no IEEE-754.
  final shift = Decimal.fromBigInt(BigInt.from(10).pow(scale));
  final shifted = value * shift;
  final roundedInt = roundHalfToEven(shifted);
  return (Decimal.fromInt(roundedInt) / shift)
      .toDecimal(scaleOnInfinitePrecision: scale);
}
