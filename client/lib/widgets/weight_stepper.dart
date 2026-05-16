import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/_rounding.dart';
import '../domain/enums.dart';
import '../domain/units/weight.dart';
import '../providers/profile_providers.dart';
import '../theme/context_extensions.dart';

/// `WeightUnit`-aware weight picker (LU-007).
///
/// The internal model is **always canonical `Decimal kg`** (`value` /
/// `onChanged`). The widget reads [WeightUnit] from
/// [weightUnitProvider] (or from [unitOverride] when the caller wants
/// to drive it from an onboarding-local provider, the architect-blessed
/// escape hatch).
///
/// **kg / lb** render a single display-only stepper — a centered
/// `bodyStrongNumeric` value flanked by tap-only `-` / `+` buttons.
/// Visually matches the height stepper on onboarding step 2 (no
/// `TextField` chrome, no smaller field-style font). The displayed
/// value is the canonical kg converted to the active unit and rounded
/// half-to-even to one decimal place (architect §3.5); +/- bumps by
/// `0.1` of the displayed unit and emits canonical kg on every commit.
///
/// **st** renders two integer sub-steppers side-by-side — stones (no
/// upper clamp, integer) and pounds (0–13) — using the same
/// display-only chrome. The +/- buttons on the pounds field carry /
/// borrow across the stones field: `13 lb + 1 = 1 st 0 lb` and
/// `0 lb − 1 = (stones − 1) st 13 lb`. State for the two integers
/// lives in `_WeightStepperState`; `onChanged(parseStoneToKg(stones,
/// pounds))` fires on every commit.
///
/// **Clamps.** [minKg] / [maxKg] are converted to the active unit at
/// build time so the inner stepper's clamp matches the on-screen
/// number. For st the v1 implementation skips clamps (PM-punted
/// ergonomics; the composite shape doesn't fit a single bound cleanly).
///
/// **Tenants honored:** T-01 (no hex — composes existing primitives),
/// T-07 (numeric input always has a stepper), T-17 (Decimal in /
/// formatted out), T-21 (units customer-expected), T-23 (lifted
/// widget, package-imported).
class WeightStepper extends ConsumerStatefulWidget {
  const WeightStepper({
    required this.value,
    required this.onChanged,
    this.unitOverride,
    this.minKg,
    this.maxKg,
    this.hasError = false,
    this.placeholder,
    this.semanticsLabel,
    super.key,
  });

  /// Canonical body weight in kilograms.
  final Decimal value;

  /// Called with the new canonical kg on every commit.
  final ValueChanged<Decimal> onChanged;

  /// Optional unit override. When null, the widget reads
  /// [weightUnitProvider]. Onboarding pre-User passes the
  /// onboarding-local provider's value here.
  final WeightUnit? unitOverride;

  /// Optional inclusive floor in canonical kg.
  final Decimal? minKg;

  /// Optional inclusive ceiling in canonical kg.
  final Decimal? maxKg;

  /// Colors the border red when true. For st the flag colors both
  /// sub-fields.
  final bool hasError;

  /// Retained for source-compat with callers from the form-field era;
  /// the display-only chrome has no hint slot, so this is currently a
  /// no-op. Kept on the constructor so existing call sites don't break.
  final String? placeholder;

  /// Optional Semantics wrapper label. For st the wrapper
  /// Semantics-labels each sub-field with this prefix.
  final String? semanticsLabel;

  @override
  ConsumerState<WeightStepper> createState() => _WeightStepperState();
}

/// Cached 1-lb-in-kg constant. Derived from the public seam so we do
/// not redefine the avoirdupois constant locally (LU-007 Notes /
/// gotchas: "Reuse `_kgPerLb` / `_lbPerKg` from `weight.dart` — do not
/// re-define the constant"). `parseWeightToKg('1', WeightUnit.lb)` is
/// `1 * _kgPerLb` by construction.
final Decimal _kgPerLb = parseWeightToKg('1', WeightUnit.lb);

class _WeightStepperState extends ConsumerState<WeightStepper> {
  /// Stone-mode sub-state. Always reflects the current decomposition of
  /// `widget.value` into integer stones + pounds. Recomputed in
  /// [didUpdateWidget] when the parent passes a new canonical kg
  /// (e.g. the carry path bumps stones; the next rebuild reflects it).
  int _stones = 0;
  int _pounds = 0;

  @override
  void initState() {
    super.initState();
    _syncStoneFromKg(widget.value);
  }

  @override
  void didUpdateWidget(covariant WeightStepper old) {
    super.didUpdateWidget(old);
    if (widget.value != old.value) {
      _syncStoneFromKg(widget.value);
    }
  }

  void _syncStoneFromKg(Decimal kg) {
    // Same algorithm as `_formatStone` in `domain/units/weight.dart`:
    // round to integer pounds first so `13 st 13.6 lb` carries to
    // `14 st 0 lb` instead of leaving the sub-field at 14.
    final lbTotal = _kgToLb(kg);
    final lbInt = roundHalfToEven(lbTotal);
    _stones = lbInt ~/ 14;
    _pounds = lbInt - _stones * 14;
    if (_pounds < 0) _pounds = 0;
    if (_stones < 0) _stones = 0;
  }

  /// kg → lb in `Decimal` space. The displayed value is then rounded
  /// to one decimal via [roundHalfToEvenScaled] at the render site so
  /// the stepper shows `175.0`, not `175.0488…`.
  Decimal _kgToLb(Decimal kg) {
    return (kg / _kgPerLb).toDecimal(scaleOnInfinitePrecision: 10);
  }

  /// lb → kg via the public seam — `parseWeightToKg(lb.toString(),
  /// WeightUnit.lb)` performs `lb * _kgPerLb` internally.
  Decimal _lbToKg(Decimal lb) {
    return parseWeightToKg(lb.toString(), WeightUnit.lb);
  }

  /// Format a one-decimal `Decimal` as a fixed `"N.D"` label (always
  /// one digit after the point — `79.0`, not `79`). Mirrors the height
  /// stepper's `bodyStrongNumeric` numeric typography.
  String _formatOneDp(Decimal v) {
    final s = v.toString();
    if (!s.contains('.')) return '$s.0';
    final parts = s.split('.');
    final frac = parts[1];
    if (frac.isEmpty) return '${parts[0]}.0';
    // `roundHalfToEvenScaled(_, 1)` already collapsed to one decimal,
    // but defensively trim if we ever feed something deeper.
    return '${parts[0]}.${frac[0]}';
  }

  @override
  Widget build(BuildContext context) {
    final WeightUnit unit =
        widget.unitOverride ?? ref.watch(weightUnitProvider);
    switch (unit) {
      case WeightUnit.kg:
        return _buildSingle(
          displayValue: roundHalfToEvenScaled(widget.value, 1),
          step: Decimal.parse('0.1'),
          unitSuffix: WeightUnit.kg.shortLabel,
          minDisplay:
              widget.minKg == null ? null : roundHalfToEvenScaled(widget.minKg!, 1),
          maxDisplay:
              widget.maxKg == null ? null : roundHalfToEvenScaled(widget.maxKg!, 1),
          // kg display unit IS canonical: forward straight through.
          toCanonicalKg: (kg) => kg,
        );
      case WeightUnit.lb:
        return _buildSingle(
          displayValue: roundHalfToEvenScaled(_kgToLb(widget.value), 1),
          step: Decimal.parse('0.1'),
          unitSuffix: WeightUnit.lb.shortLabel,
          minDisplay: widget.minKg == null
              ? null
              : roundHalfToEvenScaled(_kgToLb(widget.minKg!), 1),
          maxDisplay: widget.maxKg == null
              ? null
              : roundHalfToEvenScaled(_kgToLb(widget.maxKg!), 1),
          toCanonicalKg: _lbToKg,
        );
      case WeightUnit.st:
        return _buildStone(context);
    }
  }

  /// kg / lb shape — one `_TapStepper` box, "<value> <unit>" centered,
  /// flanked by `-` / `+`. `0.1` step in the displayed unit, half-to-even
  /// round on the way in, canonical kg out on every change.
  Widget _buildSingle({
    required Decimal displayValue,
    required Decimal step,
    required String unitSuffix,
    required Decimal? minDisplay,
    required Decimal? maxDisplay,
    required Decimal Function(Decimal display) toCanonicalKg,
  }) {
    void bump(Decimal delta) {
      var next = displayValue + delta;
      if (minDisplay != null && next < minDisplay) next = minDisplay;
      if (maxDisplay != null && next > maxDisplay) next = maxDisplay;
      // Re-round so a `79.4 + 0.1` that lands on `79.5000000001` (it
      // won't, but be defensive) still renders cleanly the next frame.
      next = roundHalfToEvenScaled(next, 1);
      if (next == displayValue) return;
      widget.onChanged(toCanonicalKg(next));
    }

    return _TapStepper(
      valueLabel: '${_formatOneDp(displayValue)} ${unitSuffix.toLowerCase()}',
      onIncrement: () => bump(step),
      onDecrement: () => bump(Decimal.zero - step),
      hasError: widget.hasError,
      semanticsLabel: widget.semanticsLabel,
    );
  }

  /// Stone shape — two integer `_TapStepper`s side by side. The pounds
  /// field has NO `min` / `max` on the inner stepper — we own
  /// carry/borrow at the bump seam. The stone field clamps at 0 only.
  Widget _buildStone(BuildContext context) {
    final space = context.space;
    return Row(
      children: <Widget>[
        Expanded(
          child: _TapStepper(
            valueLabel: '$_stones st',
            onIncrement: () {
              setState(() => _stones += 1);
              widget.onChanged(parseStoneToKg(_stones, _pounds));
            },
            onDecrement: () {
              if (_stones <= 0) return;
              setState(() => _stones -= 1);
              widget.onChanged(parseStoneToKg(_stones, _pounds));
            },
            hasError: widget.hasError,
            semanticsLabel: widget.semanticsLabel == null
                ? 'Stones'
                : '${widget.semanticsLabel} stones',
          ),
        ),
        SizedBox(width: space.x3),
        Expanded(
          child: _TapStepper(
            valueLabel: '$_pounds lb',
            onIncrement: _incrementPounds,
            onDecrement: _decrementPounds,
            hasError: widget.hasError,
            semanticsLabel: widget.semanticsLabel == null
                ? 'Pounds'
                : '${widget.semanticsLabel} pounds',
          ),
        ),
      ],
    );
  }

  /// Pounds `+` — carry to stones when stepping past 13.
  /// `13 + 1 = 14` → `stones += 1; pounds = 0`.
  void _incrementPounds() {
    final next = _pounds + 1;
    if (next > 13) {
      setState(() {
        _stones += 1;
        _pounds = 0;
      });
    } else {
      setState(() => _pounds = next);
    }
    widget.onChanged(parseStoneToKg(_stones, _pounds));
  }

  /// Pounds `-` — borrow from stones when stepping past 0.
  /// `0 − 1` with `stones > 0` → `stones -= 1; pounds = 13`. Otherwise
  /// floor at `0 st 0 lb` (no change emitted).
  void _decrementPounds() {
    if (_pounds > 0) {
      setState(() => _pounds -= 1);
    } else if (_stones > 0) {
      setState(() {
        _stones -= 1;
        _pounds = 13;
      });
    } else {
      return; // already at floor — no commit.
    }
    widget.onChanged(parseStoneToKg(_stones, _pounds));
  }
}

/// Display-only stepper — mirrors the look of `_NumberStepper` in
/// `features/onboarding/widgets/step_2_about_you.dart` so the weight
/// picker visually matches the height picker. Inlined here rather than
/// lifted to `lib/widgets/` to keep this fix small; a future ticket can
/// converge the two private types into one shared primitive.
///
/// Shape: 48-px tall `Container`, 1-px line border, `radius.r2`,
/// `bodyStrongNumeric` centered label, `_TapStepperButton`s on either
/// side. No `TextField`, no field-style chrome. `hasError` flips the
/// border / background to the danger tokens — same convention as
/// `QuantityStepper` for consistency at the call sites.
class _TapStepper extends StatelessWidget {
  const _TapStepper({
    required this.valueLabel,
    required this.onIncrement,
    required this.onDecrement,
    this.hasError = false,
    this.semanticsLabel,
  });

  final String valueLabel;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;
  final bool hasError;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = context.radius;
    final body = Container(
      height: 48,
      decoration: BoxDecoration(
        color: hasError ? colors.dangerSoft : colors.surface,
        borderRadius: BorderRadius.circular(radius.r2),
        border: Border.all(
          color: hasError ? colors.danger : colors.line,
          width: 1,
        ),
      ),
      child: Row(
        children: <Widget>[
          _TapStepperButton(
            icon: Icons.remove_rounded,
            onTap: onDecrement,
            tooltip: 'Decrease',
            semantics: 'Decrement',
          ),
          Expanded(
            child: Center(
              child: Text(
                valueLabel,
                style: context.text.bodyStrongNumeric,
              ),
            ),
          ),
          _TapStepperButton(
            icon: Icons.add_rounded,
            onTap: onIncrement,
            tooltip: 'Increase',
            semantics: 'Increment',
          ),
        ],
      ),
    );

    if (semanticsLabel == null) return body;
    return Semantics(label: semanticsLabel, container: true, child: body);
  }
}

/// Sibling of `_StepperButton` in step_2_about_you. Adds an explicit
/// `Decrement` / `Increment` Semantics label on top of the visual
/// tooltip so the existing widget tests can target buttons by semantics
/// label (the same convention `QuantityStepper`'s `_StepperBtn` used).
class _TapStepperButton extends StatelessWidget {
  const _TapStepperButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
    required this.semantics,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;
  final String semantics;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = context.radius;
    return Semantics(
      button: true,
      label: semantics,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(radius.r2),
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(icon, size: 18, color: colors.ink2),
          ),
        ),
      ),
    );
  }
}
