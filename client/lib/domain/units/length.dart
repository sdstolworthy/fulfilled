import 'package:decimal/decimal.dart';
import 'package:intl/intl.dart';

import '../_rounding.dart';
import '../enums.dart';

/// Body-height formatters + parsers. The single seam that knows about
/// cm / ft+in arithmetic — every other file calls `formatHeight` or
/// `parseHeightToCm` against a [HeightUnit] and renders the resulting
/// string. Mirror of `weight.dart` so a dev who has read the weight
/// seam reads length in 30 seconds (architect §5.4).
///
/// **Float safety (T-17).** Every multiplication happens in `Decimal`
/// space. The only `.toDouble()` is inside `_formatCm` at the
/// `NumberFormat.format(...)` boundary, after rounding to integer cm.
/// The ftIn branch is integer-only — no float ever appears.
///
/// **Rounding (PM §10 #9).** Half-to-even, via `_rounding.dart`. For
/// cm: round to the nearest integer cm. For the ftIn composite: round
/// `cm × _inPerCm` to integer inches *first*, then divmod by 12, so
/// the carry from `5 ft 11.6 in → 6 ft 0 lb` happens cleanly. The
/// analog of the stone composite's `13 st 13.6 lb → 14 st` carry.
///
/// **Locale-aware separators.** `intl`'s `NumberFormat.decimalPatternDigits`
/// renders integer thousands separators per locale. The ftIn composite
/// is integer-only and uses ASCII spaces, so locale never affects it.

/// Exact international inch — 1 in = 2.54 cm.
final Decimal _cmPerIn = Decimal.parse('2.54');

/// Reciprocal of [_cmPerIn] — 1 cm = 0.393700787 in. Nine digits cover
/// the half-to-even-at-integer-inches resolution we care about; deeper
/// digits do not change any rounded display.
final Decimal _inPerCm = Decimal.parse('0.393700787');

/// Format a height stored canonically in `cm` for display in `unit`.
///
/// - [HeightUnit.cm] → `"175"`-shaped integer (no suffix; caller
///   appends — see [formatHeightWithUnit]).
/// - [HeightUnit.ftIn] → composite `"5 ft 9 in"`. Units inline.
///   Drops the trailing ` 0 in` when the inch remainder is zero, so
///   152.4 cm renders as `"5 ft"`, not `"5 ft 0 in"`. The 182 cm
///   carry edge renders as `"6 ft"` — the round-then-divmod algorithm
///   carries 72 inches to feet rather than leaving `5 ft 12 in`.
///
/// The cm branch is locale-aware via `intl`. The ftIn branch is
/// integer-only so locale separators never come into play.
///
/// **Number only, no unit suffix** for cm so the caller can diverge
/// the [Semantics] label from the visible glyph (T-20). The ftIn case
/// is the exception: composite IS the rendered string including the
/// `ft` and `in` units inline. See [formatHeightWithUnit] when the
/// caller wants a one-shot "number + suffix" string.
String formatHeight(Decimal cm, HeightUnit unit, {String? locale}) {
  switch (unit) {
    case HeightUnit.cm:
      return _formatCm(cm, locale: locale);
    case HeightUnit.ftIn:
      return _formatFtIn(cm);
  }
}

/// [formatHeight] + the appropriate visible suffix, in one string.
/// Useful for callers that don't render the unit separately.
///
/// - cm:   `"175 cm"`
/// - ftIn: `"5 ft 9 in"` — the composite already inlines its units, so
///   no extra suffix is appended.
String formatHeightWithUnit(Decimal cm, HeightUnit unit, {String? locale}) {
  final number = formatHeight(cm, unit, locale: locale);
  if (unit == HeightUnit.ftIn) return number;
  return '$number cm';
}

/// cm → integer, locale-aware thousands separator. The cm display unit
/// IS the canonical unit, so no conversion seam — just round to integer
/// and hand to `intl`.
String _formatCm(Decimal cm, {String? locale}) {
  final formatter = NumberFormat.decimalPatternDigits(
    locale: locale,
    decimalDigits: 0,
  );
  final rounded = roundHalfToEvenScaled(cm, 0);
  // The rounded integer is representable exactly in IEEE-754 (it fits
  // well inside 2^53), so the `.toDouble()` round-trip is safe.
  return formatter.format(rounded.toDouble());
}

/// cm → `"5 ft 9 in"` composite (PM ruled this format explicitly —
/// imperial bathroom-scale convention, not decimal feet).
///
/// Algorithm (architect §5.4, mirror of `_formatStone` in `weight.dart`):
///   1. in_total = cm × _inPerCm
///   2. in_rounded = roundHalfToEven(in_total)  // integer in
///   3. feet = in_rounded ~/ 12
///   4. remainder = in_rounded − feet × 12
///   5. render `'$feet ft $remainder in'`
/// Edge case: remainder == 0 → render `'$feet ft'` (drops ` 0 in`).
/// Carry edge: 182 cm × 0.393700787 ≈ 71.65 → rounds to integer 72 in
/// → `6 ft 0 in` → `6 ft`. Not `5 ft 12 in`.
String _formatFtIn(Decimal cm) {
  final inTotal = cm * _inPerCm;
  final inInt = roundHalfToEven(inTotal);
  final feet = inInt ~/ 12;
  final remainder = inInt - feet * 12;
  if (remainder == 0) return '$feet ft';
  return '$feet ft $remainder in';
}

/// Parse a raw text input into canonical cm. Inverse of [formatHeight].
///
/// - [HeightUnit.cm]: parses the raw as a decimal cm. Locale separator
///   tolerant (accepts `"175"`, `"175.5"`, `"175,5"` — the comma is
///   normalised to a dot before `Decimal.parse`).
/// - [HeightUnit.ftIn]: accepts several shapes:
///   - `"5"`            → 5 ft 0 in
///   - `"5 9"`          → 5 ft 9 in
///   - `"5 ft 9 in"`    → 5 ft 9 in (the spelled-out form, for symmetry
///     with [formatHeight]'s output)
///   The composite ftIn input is constructed by the `HeightStepper`
///   from two integer sub-fields; this string overload exists for test
///   ergonomics and round-trip symmetry. Conversion runs through
///   [parseFeetInchesToCm], which throws `ArgumentError` on negative
///   inputs or inches >= 12.
///
/// Throws `FormatException` on unparseable input. Callers wrap and
/// surface inline error (T-11).
Decimal parseHeightToCm(String input, HeightUnit unit) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('Empty height input');
  }
  switch (unit) {
    case HeightUnit.cm:
      return _parseDecimalTolerant(trimmed);
    case HeightUnit.ftIn:
      return _parseFtInString(trimmed);
  }
}

/// Typed overload — convert an integer (feet, inches) pair to cm.
/// `HeightStepper` calls this directly with the two sub-field values
/// so the widget never has to build a composite string.
///
/// Negative inputs throw — body height is always non-negative. Inches
/// >= 12 also throw; the composite shape carries to feet before
/// hitting 12, so a callsite passing 12 has a bug to surface.
Decimal parseFeetInchesToCm(int feet, int inches) {
  if (feet < 0 || inches < 0 || inches >= 12) {
    throw ArgumentError.value(
      '($feet, $inches)',
      'feet, inches',
      'feet >= 0, 0 <= inches < 12',
    );
  }
  // `feet * 12 + inches` is an exact integer count of inches; multiply
  // by the avoirdupois inch (2.54 cm) and round half-to-even to the
  // nearest integer cm so the result lines up with canonical cm
  // storage. Pure Decimal — no IEEE-754.
  final totalIn = Decimal.fromInt(feet * 12 + inches);
  return roundHalfToEvenScaled(totalIn * _cmPerIn, 0);
}

/// Decompose a canonical cm into an integer (feet, inches) pair.
/// Inverse of [parseFeetInchesToCm] — `HeightStepper` calls this on
/// seed / `didUpdateWidget` so the widget never has to multiply by
/// `2.54` or divide by `12` directly. Same round-then-divmod algorithm
/// as `_formatFtIn`, so the widget's sub-field state stays in lockstep
/// with what the formatter would have rendered.
///
/// Returns a record `(feet, inches)`. Negative cm clamps to `(0, 0)`
/// (body height is non-negative; the clamp is belt-and-braces for the
/// `didUpdateWidget` reseed path).
({int feet, int inches}) decomposeCmToFeetInches(Decimal cm) {
  final inTotal = cm * _inPerCm;
  final inInt = roundHalfToEven(inTotal);
  if (inInt <= 0) return (feet: 0, inches: 0);
  final feet = inInt ~/ 12;
  final inches = inInt - feet * 12;
  return (feet: feet, inches: inches);
}

/// Locale-tolerant decimal parse. Replaces a single `,` with `.` so
/// `"175,5"` (de-DE shape) and `"175.5"` (en-US shape) both parse to
/// `Decimal.parse('175.5')`. Throws `FormatException` on anything else.
Decimal _parseDecimalTolerant(String raw) {
  final normalised = raw.replaceAll(',', '.');
  try {
    return Decimal.parse(normalised);
  } on FormatException {
    rethrow;
  }
}

/// Parse a feet+inches composite string. See [parseHeightToCm] for the
/// accepted shapes.
Decimal _parseFtInString(String raw) {
  // Strip the spelled-out unit tokens so `"5 ft 9 in"` collapses to
  // `"5 9"`. Keep digits and whitespace separators; everything else
  // (letters, symbols) goes.
  final cleaned = raw
      .replaceAll(RegExp(r'[a-zA-Z]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (cleaned.isEmpty) {
    throw FormatException('Unparseable feet+inches height: "$raw"');
  }
  final parts = cleaned.split(' ');
  if (parts.length == 1) {
    final feet = int.tryParse(parts[0]);
    if (feet == null) {
      throw FormatException('Unparseable feet+inches height: "$raw"');
    }
    return parseFeetInchesToCm(feet, 0);
  }
  if (parts.length == 2) {
    final feet = int.tryParse(parts[0]);
    final inches = int.tryParse(parts[1]);
    if (feet == null || inches == null) {
      throw FormatException('Unparseable feet+inches height: "$raw"');
    }
    return parseFeetInchesToCm(feet, inches);
  }
  throw FormatException('Unparseable feet+inches height: "$raw"');
}
