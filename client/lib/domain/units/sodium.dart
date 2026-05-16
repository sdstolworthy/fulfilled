import 'package:decimal/decimal.dart';
import 'package:intl/intl.dart';

/// Sodium-specific conversions and formatters.
///
/// **Why a dedicated file:** the wire is split — `NutritionPer100g.sodium_g`
/// is grams, `LogEntry.sodium_mg` is milligrams (OFF convention vs.
/// per-entry). The customer expects milligrams everywhere on screen. Per
/// PM Risk 4, the OpenAPI shape does not change; the client converts.
///
/// Use [gramsToMilligrams] at the repository boundary, then pass the
/// resulting `Decimal` to [formatSodiumMg] at the leaf widget. Do not
/// re-convert downstream.

/// Multiply by 1000 with arbitrary precision. The conversion is exact for
/// `Decimal` — never use `double` here (T-17).
Decimal gramsToMilligrams(Decimal grams) {
  return grams * Decimal.fromInt(1000);
}

/// Format a sodium value already in milligrams as a display string.
///
/// Rules:
/// - Integer milligrams (round half-up). Sodium granularity finer than 1 mg
///   is noise on a nutrition label.
/// - Thousands separator from the current locale (`intl`'s
///   [NumberFormat.decimalPattern]). En-US renders `1,250`; FR renders
///   `1 250`; we follow `intl`.
/// - No unit suffix — the leaf widget appends ` mg` for a11y/T-20 and so
///   the number aligns under a label.
///
/// Callers that need the suffix inline can do `'${formatSodiumMg(v)} mg'`.
String formatSodiumMg(Decimal milligrams, {String? locale}) {
  final rounded = milligrams.round(scale: 0).toBigInt();
  final formatter = NumberFormat.decimalPattern(locale);
  return formatter.format(rounded.toInt());
}
