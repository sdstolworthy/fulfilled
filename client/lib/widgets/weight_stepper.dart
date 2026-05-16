import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/_rounding.dart';
import '../domain/enums.dart';
import '../domain/units/weight.dart';
import '../providers/profile_providers.dart';
import '../theme/context_extensions.dart';
import 'quantity_stepper.dart';

/// `WeightUnit`-aware wrapper around the lifted [QuantityStepper] (LU-007).
///
/// The internal model is **always canonical `Decimal kg`** (`value` /
/// `onChanged`). The widget reads [WeightUnit] from
/// [weightUnitProvider] (or from [unitOverride] when the caller wants
/// to drive it from an onboarding-local provider, the architect-blessed
/// escape hatch).
///
/// **kg / lb** render a single [QuantityStepper] with a unit suffix.
/// The displayed value is the canonical kg converted to the active
/// unit and rounded half-to-even to one decimal place (architect §3.5);
/// emits convert back to kg before calling [onChanged].
///
/// **st** renders two integer sub-steppers — stones (no upper clamp,
/// integer) and pounds (0–13). The +/- buttons on the pounds field
/// carry / borrow across the stones field: `13 lb + 1 = 1 st 0 lb` and
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
/// formatted out), T-23 (lifted widget, package-imported).
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

  /// Forwarded to the inner [QuantityStepper] for the kg / lb cases.
  /// For st the flag colors both sub-fields.
  final bool hasError;

  /// Forwarded to the inner [QuantityStepper] (kg / lb only).
  final String? placeholder;

  /// Forwarded to the inner [QuantityStepper]'s Semantics wrapper. For
  /// st the wrapper Semantics-labels the row.
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
          toCanonicalKg: (lb) => lb,
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

  Widget _buildSingle({
    required Decimal displayValue,
    required Decimal step,
    required String unitSuffix,
    required Decimal? minDisplay,
    required Decimal? maxDisplay,
    required Decimal Function(Decimal display) toCanonicalKg,
  }) {
    return QuantityStepper(
      value: displayValue,
      step: step,
      min: minDisplay,
      max: maxDisplay,
      unitSuffix: unitSuffix,
      hasError: widget.hasError,
      placeholder: widget.placeholder,
      semanticsLabel: widget.semanticsLabel,
      onChanged: (next) {
        // The wrapper's `onChanged` is non-nullable kg; the inner
        // stepper can emit null when the user clears the field. We
        // treat a clear as "no change" and swallow it — the
        // surrounding form (sheet / onboarding step) owns null-state
        // semantics, not the widget.
        if (next == null) return;
        widget.onChanged(toCanonicalKg(next));
      },
    );
  }

  Widget _buildStone(BuildContext context) {
    final space = context.space;
    // Two integer-mode steppers side by side. The pounds field has
    // NO `min` / `max` on the inner stepper — we own carry/borrow at
    // the onChanged seam. The stone field clamps at 0 only.
    //
    // Stone-row ergonomics on iPhone SE (390 wide) is the architect's
    // risk 5 — the LU-007 spec named the fallback ("hide +/− on the
    // pounds sub-field"). v1 ships with both sets of buttons; LU-010
    // can downgrade if the screen-fit acceptance fails.
    return Row(
      children: <Widget>[
        Expanded(
          child: QuantityStepper(
            value: Decimal.fromInt(_stones),
            step: Decimal.one,
            min: Decimal.zero,
            allowDecimal: false,
            unitSuffix: 'st',
            hasError: widget.hasError,
            semanticsLabel: widget.semanticsLabel == null
                ? 'Stones'
                : '${widget.semanticsLabel} stones',
            onChanged: (next) {
              if (next == null) return;
              final nextStones = next.toBigInt().toInt();
              if (nextStones < 0) return;
              setState(() => _stones = nextStones);
              widget.onChanged(parseStoneToKg(_stones, _pounds));
            },
          ),
        ),
        SizedBox(width: space.x3),
        Expanded(
          child: QuantityStepper(
            value: Decimal.fromInt(_pounds),
            step: Decimal.one,
            allowDecimal: false,
            unitSuffix: 'lb',
            hasError: widget.hasError,
            semanticsLabel: widget.semanticsLabel == null
                ? 'Pounds'
                : '${widget.semanticsLabel} pounds',
            onChanged: _onPoundsChanged,
          ),
        ),
      ],
    );
  }

  /// Handle the inner pounds stepper's commit — apply carry / borrow
  /// before propagating to [WeightStepper.onChanged].
  ///
  /// Carry: `pounds > 13` (the +/- button stepped past the top of the
  /// 0–13 band, or the user typed a higher value) → `stones += next ~/
  /// 14; pounds = next % 14`.
  /// Borrow: `pounds < 0` (only reachable via the `-` button at
  /// `pounds == 0`) → if `stones > 0`, `stones -= 1; pounds = 13`;
  /// otherwise floor at `0 st 0 lb`.
  void _onPoundsChanged(Decimal? next) {
    if (next == null) return;
    final nextPounds = next.toBigInt().toInt();
    if (nextPounds > 13) {
      final carry = nextPounds ~/ 14;
      final remainder = nextPounds - carry * 14;
      setState(() {
        _stones += carry;
        _pounds = remainder;
      });
    } else if (nextPounds < 0) {
      if (_stones > 0) {
        setState(() {
          _stones -= 1;
          _pounds = 13;
        });
      } else {
        setState(() => _pounds = 0);
      }
    } else {
      setState(() => _pounds = nextPounds);
    }
    widget.onChanged(parseStoneToKg(_stones, _pounds));
  }
}
