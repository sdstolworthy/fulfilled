
import 'package:flutter/material.dart';

/// A `Text` wrapper that pins tabular-figures on and composes a
/// number-with-unit semantics label in one place.
///
/// **T-02**: every rendered number flows through this widget (or the
/// `*Numeric` styles in `AppText`). Tabular figures are applied at the
/// leaf — never globally — so headlines and body copy keep their
/// proportional metrics while digits stay column-aligned.
///
/// **T-20**: the rendered string is `value` (digits only — no unit), but
/// the announced semantics label is `"$value $unit"`. This is the
/// load-bearing decision the architect named: the visual surface stays
/// compact ("145"), and the screen reader hears the full phrase ("145
/// kilocalories"). `unit` is **required** — the compiler is the audit.
/// If a follow-up call site tries to omit a unit, it won't compile, and
/// that is the entire point.
///
/// Callers pass *already-formatted* strings (`formatKcal`, `formatGrams`,
/// `formatSodiumMg`). This widget does not format — formatting is owned
/// by `lib/domain/units/`.
///
/// Migration: B7 / T-022 owns the sweep from inline `Text(formatKcal(...))`
/// to `NumberText(value: formatKcal(...), unit: 'kilocalories')`. This
/// ticket only creates the widget.
class NumberText extends StatelessWidget {
  const NumberText({
    required this.value,
    required this.unit,
    this.style,
    this.textAlign,
    super.key,
  });

  /// The pre-formatted numeric string. Examples: `"145"`, `"22.4"`,
  /// `"1,240"`. Pass it through `formatKcal` / `formatGrams` /
  /// `formatSodiumMg` first — `NumberText` does not format.
  final String value;

  /// The spoken unit for the Semantics announcement. Examples:
  /// `"kilocalories"`, `"grams"`, `"milligrams"`, `"kilograms"`. Required
  /// so the compiler enforces the T-20 contract.
  final String unit;

  /// Optional text style. Tabular figures are applied on top of
  /// whatever style is passed in (or `DefaultTextStyle` if null), so a
  /// caller can hand in `context.text.hero` and still get column-aligned
  /// digits.
  final TextStyle? style;

  /// Optional text alignment. Defaults to the ambient direction.
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final base = style ?? DefaultTextStyle.of(context).style;
    final tabular = base.copyWith(
      fontFeatures: <FontFeature>[
        ...?base.fontFeatures,
        const FontFeature.tabularFigures(),
      ],
    );
    return Semantics(
      label: '$value $unit',
      excludeSemantics: true,
      child: Text(value, style: tabular, textAlign: textAlign),
    );
  }
}
