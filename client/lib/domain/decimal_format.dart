/// Decimal display helpers that are *not* tied to a specific unit.
///
/// **Inventory (PM §10 #9, dev_tickets T-011 acceptance):**
/// - `formatKcal` lives in `domain/units/energy.dart` — integer kcal,
///   half-to-even, thousands separator from locale.
/// - `formatGrams` lives in `domain/units/macros.dart` — integer at
///   `>=10 g`, one decimal at `<10 g`, half-to-even on both regimes.
/// - `formatSodiumMg` lives in `domain/units/sodium.dart` — integer mg,
///   half-to-even, thousands separator from locale.
/// - `formatWeightKg` lives in `domain/units/weight.dart` — one decimal
///   always, half-to-even on the tenths digit.
/// - `formatQuantity` (this file) — serving multiplier display. One
///   fraction digit on commit (half-to-even), trailing zeros and a bare
///   trailing decimal point are trimmed so `1.0` reads as `1`.
/// - `formatRate` (this file) — kg/week display in the goal editor.
///   Two fraction digits always (half-to-even). Caller appends `" kg/week"`.
///
/// **Why a separate file from `units/`.** `units/units.dart` re-exports
/// the unit-tagged formatters (kcal / g / mg / kg). `formatQuantity` and
/// `formatRate` are unit-agnostic display rules — a quantity is a
/// multiplier (no unit), a rate's unit (`kg/week`) belongs to the call
/// site so non-English locales can localize the suffix later. Keeping
/// them here avoids polluting the unit-tagged barrel.
library;

import 'package:decimal/decimal.dart';

import '_rounding.dart';

/// Format a serving multiplier for committed display.
///
/// Rules (PM §10 #9):
/// - One fraction digit, **half-to-even**.
/// - Trailing zero (and the bare decimal point) is trimmed so the
///   quick-multiplier chips render as the user expects:
///   `0.5 → "0.5"`, `1 → "1"`, `1.5 → "1.5"`, `2 → "2"`, `3 → "3"`.
/// - Trimming pattern matches `widgets/quantity_stepper.dart`'s
///   `_format` helper — same regex-strip approach.
///
/// In-progress text input ("up to two fraction digits while typing")
/// stays in the stepper widget; this helper is for committed display.
String formatQuantity(Decimal value) {
  final rounded = roundHalfToEvenScaled(value, 1);
  final s = rounded.toString();
  if (!s.contains('.')) return s;
  return s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}

/// Format a kg/week rate for display.
///
/// Two fraction digits always (PM §10 #9), **half-to-even**. Returns just
/// the number; the call site appends `" kg/week"` (so localized variants
/// of the unit suffix can live alongside the localized number).
///
/// Examples (en_US):
///   - `0.5  → "0.50"`
///   - `0.25 → "0.25"`
///   - `1    → "1.00"`
String formatRate(Decimal value) {
  final rounded = roundHalfToEvenScaled(value, 2);
  // We do not run this through `intl` — the rate slider is a tight
  // numeric label flanked by `kg/week`, and the existing surrounding
  // copy is en-US only (PM Risk 4, no locale toggle until v2). When
  // i18n lands, route through `NumberFormat.decimalPatternDigits(
  // decimalDigits: 2)` here.
  final s = rounded.toString();
  // `Decimal.toString()` drops trailing zeros — pad back to two digits.
  final dot = s.indexOf('.');
  if (dot < 0) return '$s.00';
  final fraction = s.length - dot - 1;
  if (fraction == 2) return s;
  if (fraction == 1) return '${s}0';
  // fraction > 2 cannot occur after roundHalfToEvenScaled(value, 2);
  // belt-and-braces: truncate.
  return s.substring(0, dot + 3);
}
