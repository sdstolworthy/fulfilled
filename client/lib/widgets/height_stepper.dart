import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/_rounding.dart';
import '../domain/enums.dart';
import '../domain/units/length.dart';
import '../providers/profile_providers.dart';
import '../theme/context_extensions.dart';
// Re-import only via the public seam: no `2.54` constant, no `* 12`
// in this file. `decomposeCmToFeetInches` and `parseFeetInchesToCm`
// own every length arithmetic step. Acceptance §grep-2.54 (QL-103).

/// `HeightUnit`-aware height picker (QL-103).
///
/// The internal model is **always canonical `Decimal cm`** ([value] /
/// [onChanged]). The widget reads [HeightUnit] from
/// [heightUnitProvider] (or from [unitOverride] when the caller wants
/// to drive it from an onboarding-local provider, the architect-blessed
/// escape hatch).
///
/// **cm** renders a single display-only stepper — a centered
/// `bodyStrongNumeric` value flanked by tap-only `-` / `+` buttons.
/// Visually matches `WeightStepper`'s kg/lb mode and the height stepper
/// on onboarding step 2 (no `TextField` chrome, no smaller field-style
/// font). The displayed value is the canonical cm rounded half-to-even
/// to the nearest integer cm (architect §5.6); +/- bumps by 1 cm and
/// emits canonical cm on every commit.
///
/// **ftIn** renders two integer sub-steppers side-by-side — feet (3..8
/// soft clamp; buttons disable at edges) and inches (0..11) — using
/// the same display-only chrome. The +/- buttons on the inches field
/// carry / borrow across the feet field: `11 in + 1 = 1 ft 0 in` and
/// `0 in − 1 = (feet − 1) ft 11 in`. State for the two integers lives
/// in `_HeightStepperState`;
/// `onChanged(parseFeetInchesToCm(feet, inches))` fires on every
/// commit.
///
/// **Clamps.** [minCm] / [maxCm] gate the cm-mode `+`/`-` buttons so
/// the displayed value never goes out of range. The ftIn mode uses the
/// soft `3..8 ft` × `0..11 in` integer clamps directly — converting
/// [minCm] / [maxCm] through 2.54 would produce non-intuitive button
/// disable states on the feet side (e.g. `min = 80 cm` would
/// translate to `2.6 ft` which doesn't align with the soft `3 ft`
/// floor). PM-punted ergonomics; the ftIn integer floors are the right
/// shape here.
///
/// **Tenants honored:** T-01 (no hex — composes existing primitives),
/// T-07 (numeric input always has a stepper), T-17 (Decimal in /
/// formatted out), T-20 (Semantics labels include the rendered value
/// with its long-form unit), T-23 (lifted widget, package-imported).
class HeightStepper extends ConsumerStatefulWidget {
  const HeightStepper({
    required this.value,
    required this.onChanged,
    this.unitOverride,
    this.minCm,
    this.maxCm,
    this.hasError = false,
    this.placeholder,
    this.semanticsLabel,
    super.key,
  });

  /// Canonical body height in centimetres.
  final Decimal value;

  /// Called with the new canonical cm on every commit.
  final ValueChanged<Decimal> onChanged;

  /// Optional unit override. When null, the widget reads
  /// [heightUnitProvider]. Onboarding pre-User passes the
  /// onboarding-local provider's value here.
  final HeightUnit? unitOverride;

  /// Optional inclusive floor in canonical cm. Defaults to `80 cm`
  /// for cm-mode (PM-ruled adult range). Unused in ftIn mode — that
  /// shape uses the `3 ft` soft integer floor instead.
  final Decimal? minCm;

  /// Optional inclusive ceiling in canonical cm. Defaults to `250 cm`
  /// for cm-mode. Unused in ftIn mode — that shape uses the `8 ft`
  /// soft integer ceiling instead.
  final Decimal? maxCm;

  /// Colors the border red when true. For ftIn the flag colors both
  /// sub-fields.
  final bool hasError;

  /// Retained for source-compat with callers from the form-field era;
  /// the display-only chrome has no hint slot, so this is currently a
  /// no-op. Kept on the constructor so existing call sites don't break
  /// when QL-104 swaps the inline cm-only stepper for this widget.
  final String? placeholder;

  /// Optional Semantics wrapper label. For ftIn the wrapper
  /// Semantics-labels each sub-field with this prefix.
  final String? semanticsLabel;

  @override
  ConsumerState<HeightStepper> createState() => _HeightStepperState();
}

/// Default cm-mode bounds — PM §5 height range, mirrored from architect
/// §5.6. Centralised as `Decimal` finals so the cm stepper's clamp
/// matches the on-screen integer without a per-frame conversion.
final Decimal _defaultMinCm = Decimal.fromInt(80);
final Decimal _defaultMaxCm = Decimal.fromInt(250);

/// ftIn-mode soft integer clamps. Feet `3..8` covers the realistic
/// adult range; inches saturate at 11 before carrying to feet.
const int _minFeet = 3;
const int _maxFeet = 8;
const int _maxInches = 11;

class _HeightStepperState extends ConsumerState<HeightStepper> {
  /// ftIn-mode sub-state. Always reflects the current decomposition of
  /// `widget.value` into integer feet + inches. Recomputed in
  /// [didUpdateWidget] when the parent passes a new canonical cm
  /// (e.g. the carry path bumps feet; the next rebuild reflects it).
  int _feet = 0;
  int _inches = 0;

  @override
  void initState() {
    super.initState();
    _syncFtInFromCm(widget.value);
  }

  @override
  void didUpdateWidget(covariant HeightStepper old) {
    super.didUpdateWidget(old);
    if (widget.value != old.value) {
      _syncFtInFromCm(widget.value);
    }
  }

  void _syncFtInFromCm(Decimal cm) {
    // Same algorithm as `_formatFtIn` in `domain/units/length.dart`:
    // round to integer inches first so `5 ft 11.6 in` carries to
    // `6 ft 0 in` instead of leaving the sub-field at 12. The
    // decomposition lives behind the public `decomposeCmToFeetInches`
    // seam so this widget file doesn't multiply by `2.54` or divmod
    // by `12` directly (QL-103 acceptance: no `2.54` / `* 12` / `/ 12`
    // hits outside `length.dart`).
    final decomposed = decomposeCmToFeetInches(cm);
    _feet = decomposed.feet;
    _inches = decomposed.inches;
  }

  @override
  Widget build(BuildContext context) {
    final HeightUnit unit =
        widget.unitOverride ?? ref.watch(heightUnitProvider);
    switch (unit) {
      case HeightUnit.cm:
        return _buildCm();
      case HeightUnit.ftIn:
        return _buildFtIn(context);
    }
  }

  /// cm shape — one `_TapStepper` box, "<value> cm" centered, flanked
  /// by `-` / `+`. Integer step (1 cm), half-to-even round on the way
  /// in, canonical cm out on every change.
  Widget _buildCm() {
    final minCm = widget.minCm ?? _defaultMinCm;
    final maxCm = widget.maxCm ?? _defaultMaxCm;
    // Round the canonical cm to the nearest integer for display. The
    // emitted canonical cm is also the rounded integer — same number
    // the user sees, so the round-trip is stable.
    final displayCm = roundHalfToEvenScaled(widget.value, 0);
    final atFloor = displayCm <= minCm;
    final atCeiling = displayCm >= maxCm;

    void bump(int delta) {
      var next = displayCm + Decimal.fromInt(delta);
      if (next < minCm) next = minCm;
      if (next > maxCm) next = maxCm;
      if (next == displayCm) return;
      widget.onChanged(next);
    }

    // Pull the integer count via toBigInt — the rounded value is an
    // exact integer cm so this is lossless.
    final cmInt = displayCm.toBigInt();
    return _TapStepper(
      valueLabel: '$cmInt cm',
      onIncrement: atCeiling ? null : () => bump(1),
      onDecrement: atFloor ? null : () => bump(-1),
      hasError: widget.hasError,
      semanticsLabel: widget.semanticsLabel ?? '$cmInt centimeters',
    );
  }

  /// ftIn shape — two integer `_TapStepper`s side by side. The inches
  /// field has NO `min` / `max` on the inner stepper — we own
  /// carry/borrow at the bump seam. The feet field clamps at
  /// `[_minFeet, _maxFeet]`.
  Widget _buildFtIn(BuildContext context) {
    final space = context.space;
    final feetAtFloor = _feet <= _minFeet;
    final feetAtCeiling = _feet >= _maxFeet;
    // Inches `+` at the absolute ceiling (feet at max AND inches at
    // 11) is a no-op — there's no `9 ft` slot to carry into.
    final inchesAtCeiling = feetAtCeiling && _inches >= _maxInches;
    // Inches `-` at the absolute floor (feet at min AND inches at 0)
    // is a no-op — no `2 ft 11 in` slot to borrow from.
    final inchesAtFloor = feetAtFloor && _inches <= 0;
    return Row(
      children: <Widget>[
        Expanded(
          child: _TapStepper(
            valueLabel: '$_feet ft',
            onIncrement: feetAtCeiling
                ? null
                : () {
                    setState(() => _feet += 1);
                    widget.onChanged(parseFeetInchesToCm(_feet, _inches));
                  },
            onDecrement: feetAtFloor
                ? null
                : () {
                    setState(() => _feet -= 1);
                    widget.onChanged(parseFeetInchesToCm(_feet, _inches));
                  },
            hasError: widget.hasError,
            semanticsLabel: widget.semanticsLabel == null
                ? '$_feet feet'
                : '${widget.semanticsLabel} $_feet feet',
          ),
        ),
        SizedBox(width: space.x3),
        Expanded(
          child: _TapStepper(
            valueLabel: '$_inches in',
            onIncrement: inchesAtCeiling ? null : _incrementInches,
            onDecrement: inchesAtFloor ? null : _decrementInches,
            hasError: widget.hasError,
            semanticsLabel: widget.semanticsLabel == null
                ? '$_inches inches'
                : '${widget.semanticsLabel} $_inches inches',
          ),
        ),
      ],
    );
  }

  /// Inches `+` — carry to feet when stepping past 11.
  /// `11 + 1 = 12` → `feet += 1; inches = 0`. If feet is already at
  /// [_maxFeet] the bump is gated upstream in [_buildFtIn].
  void _incrementInches() {
    final next = _inches + 1;
    if (next > _maxInches) {
      setState(() {
        _feet += 1;
        _inches = 0;
      });
    } else {
      setState(() => _inches = next);
    }
    widget.onChanged(parseFeetInchesToCm(_feet, _inches));
  }

  /// Inches `-` — borrow from feet when stepping past 0.
  /// `0 − 1` with `feet > _minFeet` → `feet -= 1; inches = 11`.
  /// Otherwise floor at `_minFeet ft 0 in` (no change emitted) — the
  /// disabled-button gate in [_buildFtIn] short-circuits the tap, but
  /// keep this defensive branch in case a caller drives the bump
  /// programmatically.
  void _decrementInches() {
    if (_inches > 0) {
      setState(() => _inches -= 1);
    } else if (_feet > _minFeet) {
      setState(() {
        _feet -= 1;
        _inches = _maxInches;
      });
    } else {
      return; // already at floor — no commit.
    }
    widget.onChanged(parseFeetInchesToCm(_feet, _inches));
  }
}

/// Display-only stepper — sibling of `WeightStepper`'s inline
/// `_TapStepper` (see `weight_stepper.dart:310–408`). Re-inlined here
/// rather than lifted to a shared `lib/widgets/tap_stepper.dart`
/// primitive; architect §5.6 explicitly defers that lift to v1.1, and
/// the weight stepper already named the convergence as future work.
///
/// Shape: 48-px tall `Container`, 1-px line border, `radius.r2`,
/// `bodyStrongNumeric` centered label, `_TapStepperButton`s on either
/// side. No `TextField`, no field-style chrome. `hasError` flips the
/// border / background to the danger tokens — same convention as
/// `QuantityStepper` and `WeightStepper` for consistency at the call
/// sites.
///
/// Passing `null` for [onIncrement] or [onDecrement] disables that
/// side of the stepper — used by the clamp gates (cm at min/max, feet
/// at 3/8, the absolute ftIn floor/ceiling).
class _TapStepper extends StatelessWidget {
  const _TapStepper({
    required this.valueLabel,
    required this.onIncrement,
    required this.onDecrement,
    this.hasError = false,
    this.semanticsLabel,
  });

  final String valueLabel;
  final VoidCallback? onIncrement;
  final VoidCallback? onDecrement;
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

/// Sibling of `WeightStepper`'s `_TapStepperButton`. Adds an explicit
/// `Decrement` / `Increment` Semantics label on top of the visual
/// tooltip so the existing widget tests can target buttons by semantics
/// label (the same convention `WeightStepper` and `QuantityStepper`
/// use). A `null` `onTap` disables the underlying [InkWell] — Flutter
/// renders the disabled state automatically.
class _TapStepperButton extends StatelessWidget {
  const _TapStepperButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
    required this.semantics,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String tooltip;
  final String semantics;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = context.radius;
    return Semantics(
      button: true,
      enabled: onTap != null,
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
