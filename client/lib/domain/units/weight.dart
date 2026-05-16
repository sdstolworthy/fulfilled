import 'package:decimal/decimal.dart';
import 'package:intl/intl.dart';

import '../_rounding.dart';
import '../enums.dart';

/// Body-weight formatters + parsers. The single seam that knows about
/// kg / lb / st arithmetic — every other file calls `formatWeight` or
/// `parseWeightToKg` against a `WeightUnit` and renders the resulting
/// string.
///
/// **Float safety (T-17).** Every multiplication happens in `Decimal`
/// space. The only `.toDouble()` is inside `_formatKg` / `_formatLb`
/// at the `NumberFormat.format(...)` boundary, after rounding to one
/// decimal place — at that point the value is representable exactly in
/// IEEE-754 and the round-trip is safe.
///
/// **Rounding (PM §10 #9).** Half-to-even on the tenths digit for
/// kg / lb; half-to-even to the nearest integer pound for the stone
/// composite (the carry from `13 st 13.6 lb → 14 st 0 lb` happens
/// because we round to integer pounds *first*, then divmod by 14).
///
/// **Locale-aware separators.** `intl`'s `NumberFormat.decimalPatternDigits`
/// renders `70.5` in en-US and `70,5` in de-DE. The stone composite is
/// integer-only so the separator never appears.

/// Exact international avoirdupois pound — 1 lb = 0.45359237 kg.
final Decimal _kgPerLb = Decimal.parse('0.45359237');

/// Reciprocal of `_kgPerLb`. Picked to the precision the ticket
/// constrains — `2.2046226218`. The trailing digits do not change any
/// rounded display at the resolutions we care about (kg→lb half-to-even
/// at 1 decimal, kg→lb half-to-even at integer pounds).
final Decimal _lbPerKg = Decimal.parse('2.2046226218');

/// Format a weight stored canonically in `kg` for display in `unit`.
///
/// - `WeightUnit.kg` → `"79.4"`-shaped (no suffix; caller appends).
/// - `WeightUnit.lb` → `"175.0"`-shaped (no suffix; caller appends).
/// - `WeightUnit.st` → composite `"12 st 7 lb"` — units inline.
///   `"12 st"` when the pound remainder is zero (drops the ` 0 lb`).
///
/// kg and lb branches are locale-aware via `intl`. The stone branch is
/// integer-only so locale separators never come into play.
///
/// **Number only, no unit suffix** for kg / lb so the caller can
/// diverge the `Semantics` label from the visible glyph (T-20). The
/// stone case is the exception: composite IS the rendered string
/// including the "st" and "lb" units inline. See [formatWeightWithUnit]
/// when the caller wants a one-shot "number + suffix" string.
String formatWeight(Decimal kg, WeightUnit unit, {String? locale}) {
  switch (unit) {
    case WeightUnit.kg:
      return _formatKg(kg, locale: locale);
    case WeightUnit.lb:
      return _formatLb(kg, locale: locale);
    case WeightUnit.st:
      return _formatStone(kg);
  }
}

/// `formatWeight` + the appropriate visible suffix, in one string.
/// Useful for callers that don't render the unit separately.
///
/// - kg / lb: `"79.4 kg"` / `"175.0 lb"`
/// - st: `"12 st 7 lb"` — the composite already inlines its units, so
///   no extra suffix is appended.
String formatWeightWithUnit(Decimal kg, WeightUnit unit, {String? locale}) {
  final number = formatWeight(kg, unit, locale: locale);
  if (unit == WeightUnit.st) return number;
  return '$number ${unit.shortLabel}';
}

/// kg → one decimal, locale-aware separator.
String _formatKg(Decimal kg, {String? locale}) {
  final formatter = NumberFormat.decimalPatternDigits(
    locale: locale,
    decimalDigits: 1,
  );
  // Round to one decimal place half-to-even using Decimal arithmetic,
  // then hand the resulting double to intl for separator placement. We
  // never let a wire Decimal touch the double constructor — only the
  // already-rounded value, where the round trip is safe.
  final rounded = roundHalfToEvenScaled(kg, 1);
  return formatter.format(rounded.toDouble());
}

/// kg → lb, one decimal, locale-aware separator.
String _formatLb(Decimal kg, {String? locale}) {
  final formatter = NumberFormat.decimalPatternDigits(
    locale: locale,
    decimalDigits: 1,
  );
  final lb = kg * _lbPerKg;
  final rounded = roundHalfToEvenScaled(lb, 1);
  return formatter.format(rounded.toDouble());
}

/// kg → `"12 st 7 lb"` composite (PM ruled this format explicitly —
/// bathroom-scale convention, not decimal stones).
///
/// Algorithm (architect §3.5 / §3.7):
///   1. lb_total = kg × _lbPerKg
///   2. lb_rounded = roundHalfToEven(lb_total)   // integer lb
///   3. stones = lb_rounded ~/ 14
///   4. remainder = lb_rounded − stones × 14
///   5. render `'$stones st $remainder lb'`
/// Edge case: remainder == 0 → render `'$stones st'` (drops ` 0 lb`).
/// Carry edge: `13 st 13.6 lb` rounds to integer 196 lb before the
/// divmod, so it becomes `14 st`, not `13 st 14 lb`.
String _formatStone(Decimal kg) {
  final lbTotal = kg * _lbPerKg;
  final lbInt = roundHalfToEven(lbTotal);
  final stones = lbInt ~/ 14;
  final remainder = lbInt - stones * 14;
  if (remainder == 0) return '$stones st';
  return '$stones st $remainder lb';
}

/// Parse a raw text input into canonical kg. Inverse of [formatWeight].
///
/// - `kg`: parses the raw as a decimal kg. Locale separator-tolerant
///   (accepts `"70.5"` and `"70,5"` — the comma is normalised to a dot
///   before `Decimal.parse`). PM punted the locale-decimal-separator
///   decision to the architect; the architect's bias is "tolerate
///   both".
/// - `lb`: parses the raw as a decimal lb (comma-tolerant for the
///   same reason), then multiplies by `_kgPerLb`.
/// - `st`: parses the raw as one of:
///     - `"12"`            → 12 st 0 lb
///     - `"12 7"`          → 12 st 7 lb
///     - `"12 st 7 lb"`    → 12 st 7 lb (the spelled-out form, for
///       symmetry with [formatWeight]'s output)
///   The composite stone input is constructed by the `WeightStepper`
///   from two integer sub-fields (LU-007); this string overload exists
///   for test ergonomics and round-trip symmetry.
///
/// Throws `FormatException` on unparseable input. Callers wrap and
/// surface inline error (T-11).
Decimal parseWeightToKg(String input, WeightUnit unit) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('Empty weight input');
  }
  switch (unit) {
    case WeightUnit.kg:
      return _parseDecimalTolerant(trimmed);
    case WeightUnit.lb:
      final lb = _parseDecimalTolerant(trimmed);
      return lb * _kgPerLb;
    case WeightUnit.st:
      return _parseStoneString(trimmed);
  }
}

/// Typed overload — convert an integer (stones, pounds) pair to kg.
/// `WeightStepper` (LU-007) calls this directly with the two
/// sub-field values so the widget never has to build a composite
/// string.
///
/// Negative inputs throw — body weight is always non-negative.
Decimal parseStoneToKg(int stones, int pounds) {
  if (stones < 0 || pounds < 0) {
    throw ArgumentError.value(
      '($stones, $pounds)',
      'stones, pounds',
      'must be non-negative',
    );
  }
  final totalLb = Decimal.fromInt(stones * 14 + pounds);
  return totalLb * _kgPerLb;
}

/// Locale-tolerant decimal parse. Replaces a single `,` with `.` so
/// `"70,5"` (de-DE shape) and `"70.5"` (en-US shape) both parse to
/// `Decimal.parse('70.5')`. Throws `FormatException` on anything else.
Decimal _parseDecimalTolerant(String raw) {
  final normalised = raw.replaceAll(',', '.');
  try {
    return Decimal.parse(normalised);
  } on FormatException {
    rethrow;
  }
}

/// Parse a stone composite string. See [parseWeightToKg] for the
/// accepted shapes.
Decimal _parseStoneString(String raw) {
  // Strip the spelled-out unit tokens so `"12 st 7 lb"` collapses to
  // `"12 7"`. Keep digits, sign, decimal point, and whitespace
  // separators; everything else (letters) goes.
  final cleaned = raw
      .replaceAll(RegExp(r'[a-zA-Z]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (cleaned.isEmpty) {
    throw FormatException('Unparseable stone weight: "$raw"');
  }
  final parts = cleaned.split(' ');
  if (parts.length == 1) {
    final stones = int.tryParse(parts[0]);
    if (stones == null) {
      throw FormatException('Unparseable stone weight: "$raw"');
    }
    return parseStoneToKg(stones, 0);
  }
  if (parts.length == 2) {
    final stones = int.tryParse(parts[0]);
    final pounds = int.tryParse(parts[1]);
    if (stones == null || pounds == null) {
      throw FormatException('Unparseable stone weight: "$raw"');
    }
    return parseStoneToKg(stones, pounds);
  }
  throw FormatException('Unparseable stone weight: "$raw"');
}
