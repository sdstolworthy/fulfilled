import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
/// Visually matches the height stepper on onboarding step 2; the
/// centered chrome is now a styled `TextField` so the user can type
/// directly with the keyboard while the +/- buttons keep working
/// exactly as before. The displayed value is the canonical kg
/// converted to the active unit and rounded half-to-even to one
/// decimal place (architect §3.5); +/- bumps by `0.1` of the displayed
/// unit and emits canonical kg on every commit.
///
/// **st** renders two integer sub-steppers stacked vertically — stones
/// (no upper clamp, integer) above pounds (0–13) — using the same
/// chrome. (Stacking avoids the thumb obscuring the active sub-field's
/// number on +/- tap that side-by-side suffered.)
/// Each sub-field is its own integer-only `TextField`. The +/- buttons
/// on the pounds field carry / borrow across the stones field:
/// `13 lb + 1 = 1 st 0 lb` and `0 lb − 1 = (stones − 1) st 13 lb`.
/// **Typed** pounds values also carry (FX-005): typing `14` in the
/// pounds field carries to `1 st 0 lb`, `27` to `1 st 13 lb`, etc. —
/// the typed total decomposes as `n // 14 stones + n % 14 lb` and is
/// added to the current stones (mirroring the +/- button math). Typed
/// negatives are unreachable because the sub-field uses
/// `FilteringTextInputFormatter.digitsOnly`. State for the two
/// integers lives in `_WeightStepperState`;
/// `onChanged(parseStoneToKg(stones, pounds))` fires on every commit.
///
/// **Clamps.** [minKg] / [maxKg] are converted to the active unit at
/// build time so the inner stepper's clamp matches the on-screen
/// number. Typed values that fall outside the clamps are pulled to the
/// nearest bound before commit (the revert path mirrors what the +/-
/// buttons already do). For st the v1 implementation skips clamps
/// (PM-punted ergonomics; the composite shape doesn't fit a single
/// bound cleanly).
///
/// **Keyboard input.** Locale-tolerant — accepts both `.` and `,` as
/// the decimal separator (mirrors `parseWeightToKg`). Empty input on
/// blur reverts to the last canonical value; unparseable input also
/// reverts. No error UI for v1 — the revert is the feedback.
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
    this.autofocus = false,
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

  /// QL-107 — autofocus the first input on first paint. In `kg` / `lb`
  /// mode that's the single canonical-unit field; in `st` mode it's
  /// the stones sub-field (pounds follows naturally on commit). The
  /// caller gates appropriateness (form factor / mode); the stepper
  /// just forwards.
  final bool autofocus;

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

  /// Controller for the kg / lb single-field shape. Stone mode uses
  /// [_stonesCtrl] / [_poundsCtrl] instead.
  late final TextEditingController _singleCtrl;
  late final FocusNode _singleFocus;
  late final TextEditingController _stonesCtrl;
  late final FocusNode _stonesFocus;
  late final TextEditingController _poundsCtrl;
  late final FocusNode _poundsFocus;

  @override
  void initState() {
    super.initState();
    _syncStoneFromKg(widget.value);
    _singleCtrl = TextEditingController(text: _seedSingleText());
    _singleFocus = FocusNode();
    _singleFocus.addListener(_handleSingleFocusChange);
    _stonesCtrl = TextEditingController(text: '$_stones');
    _stonesFocus = FocusNode();
    _stonesFocus.addListener(_handleStonesFocusChange);
    _poundsCtrl = TextEditingController(text: '$_pounds');
    _poundsFocus = FocusNode();
    _poundsFocus.addListener(_handlePoundsFocusChange);
  }

  @override
  void didUpdateWidget(covariant WeightStepper old) {
    super.didUpdateWidget(old);
    // Re-sync whenever the canonical value OR the unit override
    // changes — toggling kg ↔ lb via the override should re-format
    // the visible glyph even though the canonical kg is unchanged.
    // The ref.watch-driven unit change for non-override callers is a
    // pre-existing rebuild path and out of scope for the keyboard
    // input fix.
    final unitChanged = widget.unitOverride != old.unitOverride;
    if (widget.value != old.value || unitChanged) {
      _syncStoneFromKg(widget.value);
      // Mirror the new canonical value into whichever controller is
      // currently not being edited. We skip controllers that have
      // focus — that prevents the caret from jumping mid-keystroke
      // when the parent rebuilds with the value we just emitted.
      if (!_singleFocus.hasFocus) {
        final t = _seedSingleText();
        if (_singleCtrl.text != t) _singleCtrl.text = t;
      }
      if (!_stonesFocus.hasFocus) {
        final t = '$_stones';
        if (_stonesCtrl.text != t) _stonesCtrl.text = t;
      }
      if (!_poundsFocus.hasFocus) {
        final t = '$_pounds';
        if (_poundsCtrl.text != t) _poundsCtrl.text = t;
      }
    }
  }

  @override
  void dispose() {
    _singleFocus.removeListener(_handleSingleFocusChange);
    _stonesFocus.removeListener(_handleStonesFocusChange);
    _poundsFocus.removeListener(_handlePoundsFocusChange);
    _singleCtrl.dispose();
    _singleFocus.dispose();
    _stonesCtrl.dispose();
    _stonesFocus.dispose();
    _poundsCtrl.dispose();
    _poundsFocus.dispose();
    super.dispose();
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

  /// Seed text for the single (kg / lb) `TextField`. Mirrors the
  /// `valueLabel` math `_buildSingle` used to inline.
  String _seedSingleText() {
    final WeightUnit unit =
        widget.unitOverride ?? ref.read(weightUnitProvider);
    switch (unit) {
      case WeightUnit.kg:
        return _formatOneDp(roundHalfToEvenScaled(widget.value, 1));
      case WeightUnit.lb:
        return _formatOneDp(roundHalfToEvenScaled(_kgToLb(widget.value), 1));
      case WeightUnit.st:
        return ''; // unused — stone mode uses the two-field shape.
    }
  }

  void _handleSingleFocusChange() {
    if (_singleFocus.hasFocus) return;
    _commitSingleText();
  }

  void _handleStonesFocusChange() {
    if (_stonesFocus.hasFocus) return;
    _commitStoneSubField(isStones: true);
  }

  void _handlePoundsFocusChange() {
    if (_poundsFocus.hasFocus) return;
    _commitStoneSubField(isStones: false);
  }

  /// Parse the single-field TextField, clamp to bounds, and commit.
  /// On parse failure or empty input, revert the controller to the
  /// last canonical value.
  void _commitSingleText() {
    final WeightUnit unit =
        widget.unitOverride ?? ref.read(weightUnitProvider);
    if (unit == WeightUnit.st) return; // wrong shape — guarded by callers.
    final raw = _singleCtrl.text.trim();
    void revert() {
      _singleCtrl.text = _seedSingleText();
    }
    if (raw.isEmpty) {
      revert();
      return;
    }
    Decimal parsedKg;
    try {
      parsedKg = parseWeightToKg(raw, unit);
    } on FormatException {
      revert();
      return;
    }
    if (widget.minKg != null && parsedKg < widget.minKg!) {
      parsedKg = widget.minKg!;
    }
    if (widget.maxKg != null && parsedKg > widget.maxKg!) {
      parsedKg = widget.maxKg!;
    }
    // Round to display resolution before emitting so the canonical
    // kg the parent receives matches the on-screen 1-dp value.
    final canonical = unit == WeightUnit.kg
        ? roundHalfToEvenScaled(parsedKg, 1)
        : _lbToKg(roundHalfToEvenScaled(_kgToLb(parsedKg), 1));
    if (canonical != widget.value) {
      widget.onChanged(canonical);
    }
    // Always re-seed the controller text so trailing whitespace,
    // missing `.0`, or `,` separator collapses to the canonical glyph.
    _singleCtrl.text = unit == WeightUnit.kg
        ? _formatOneDp(roundHalfToEvenScaled(canonical, 1))
        : _formatOneDp(roundHalfToEvenScaled(_kgToLb(canonical), 1));
  }

  void _commitStoneSubField({required bool isStones}) {
    final ctrl = isStones ? _stonesCtrl : _poundsCtrl;
    final raw = ctrl.text.trim();
    void revert() {
      ctrl.text = isStones ? '$_stones' : '$_pounds';
    }
    if (raw.isEmpty) {
      revert();
      return;
    }
    final parsed = int.tryParse(raw);
    // The integer sub-fields use `FilteringTextInputFormatter.digitsOnly`,
    // which strips `-` before the controller sees it — so `parsed < 0`
    // is unreachable in practice. Keep the guard for source-level safety
    // in case the formatter ever changes; the borrow path below would
    // mirror `_decrementPounds` if it ever fired.
    if (parsed == null || parsed < 0) {
      revert();
      return;
    }
    int nextStones = _stones;
    int nextPounds = _pounds;
    if (isStones) {
      nextStones = parsed;
    } else {
      // FX-005: typed pounds >= 14 carry into stones, mirroring
      // `_incrementPounds`. `14 → 1 st 0 lb`, `27 → 1 st 13 lb`, etc.
      // The decomposition is `n // 14 stones + n % 14 lb` — the same
      // shape `_syncStoneFromKg` uses but applied to the typed lb
      // total rather than a kg-derived lb total. Carrying preserves
      // the canonical kg the parent receives (parseStoneToKg(s, p)
      // is linear in lb) so this is purely a UX upgrade over the
      // previous clamp-at-13 behaviour.
      nextStones = _stones + (parsed ~/ 14);
      nextPounds = parsed % 14;
    }
    if (nextStones == _stones && nextPounds == _pounds) {
      // Re-seed text to canonical glyph (drops leading zeros etc).
      ctrl.text = isStones ? '$_stones' : '$_pounds';
      return;
    }
    setState(() {
      _stones = nextStones;
      _pounds = nextPounds;
    });
    // Re-seed BOTH controllers — a carry from the pounds field needs
    // the stones field to repaint with the bumped value even though we
    // committed on the pounds field's blur.
    _stonesCtrl.text = '$_stones';
    _poundsCtrl.text = '$_pounds';
    widget.onChanged(parseStoneToKg(_stones, _pounds));
  }

  @override
  Widget build(BuildContext context) {
    final WeightUnit unit =
        widget.unitOverride ?? ref.watch(weightUnitProvider);
    switch (unit) {
      case WeightUnit.kg:
        return _buildSingle(
          unit: unit,
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
          unit: unit,
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

  /// kg / lb shape — one `_TapStepper` box, `<value> <unit>` centered,
  /// flanked by `-` / `+`. `0.1` step in the displayed unit, half-to-even
  /// round on the way in, canonical kg out on every change.
  Widget _buildSingle({
    required WeightUnit unit,
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
      final newText = _formatOneDp(next);
      if (_singleCtrl.text != newText) _singleCtrl.text = newText;
      widget.onChanged(toCanonicalKg(next));
    }

    return _TapStepper(
      controller: _singleCtrl,
      focusNode: _singleFocus,
      unitSuffix: unitSuffix.toLowerCase(),
      allowDecimal: true,
      onSubmitted: (_) => _commitSingleText(),
      onIncrement: () => bump(step),
      onDecrement: () => bump(Decimal.zero - step),
      hasError: widget.hasError,
      semanticsLabel: widget.semanticsLabel,
      autofocus: widget.autofocus,
    );
  }

  /// Stone shape — two integer `_TapStepper`s stacked vertically. The
  /// pounds field has NO `min` / `max` on the inner stepper — we own
  /// carry/borrow at the bump seam. The stone field clamps at 0 only.
  ///
  /// Stacked (not side-by-side) so the user's thumb doesn't obscure the
  /// number it's editing while tapping `+` / `-`: each sub-field gets
  /// full width, centering its number well clear of the buttons. Mirrors
  /// `HeightStepper`'s ftIn layout for visual consistency (UX bug
  /// report: thumb covered the active sub-field's number on tap).
  Widget _buildStone(BuildContext context) {
    final space = context.space;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _TapStepper(
          controller: _stonesCtrl,
          focusNode: _stonesFocus,
          unitSuffix: 'st',
          allowDecimal: false,
          onSubmitted: (_) => _commitStoneSubField(isStones: true),
          onIncrement: () {
            setState(() => _stones += 1);
            _stonesCtrl.text = '$_stones';
            widget.onChanged(parseStoneToKg(_stones, _pounds));
          },
          onDecrement: () {
            if (_stones <= 0) return;
            setState(() => _stones -= 1);
            _stonesCtrl.text = '$_stones';
            widget.onChanged(parseStoneToKg(_stones, _pounds));
          },
          hasError: widget.hasError,
          semanticsLabel: widget.semanticsLabel == null
              ? 'Stones'
              : '${widget.semanticsLabel} stones',
          // Autofocus the stones sub-field (top / first input).
          autofocus: widget.autofocus,
        ),
        SizedBox(height: space.x2),
        _TapStepper(
          controller: _poundsCtrl,
          focusNode: _poundsFocus,
          unitSuffix: 'lb',
          allowDecimal: false,
          onSubmitted: (_) => _commitStoneSubField(isStones: false),
          onIncrement: _incrementPounds,
          onDecrement: _decrementPounds,
          hasError: widget.hasError,
          semanticsLabel: widget.semanticsLabel == null
              ? 'Pounds'
              : '${widget.semanticsLabel} pounds',
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
    _stonesCtrl.text = '$_stones';
    _poundsCtrl.text = '$_pounds';
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
    _stonesCtrl.text = '$_stones';
    _poundsCtrl.text = '$_pounds';
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
/// `bodyStrongNumeric` centered label (now a styled `TextField` so the
/// user can type), unit suffix rendered as a sibling `Text` to the
/// right of the field, `_TapStepperButton`s on either side. The
/// `TextField` strips its own border / underline / fill so the chrome
/// stays pixel-identical to the previous `Text`-only version when
/// unfocused. `hasError` flips the border / background to the danger
/// tokens — same convention as `QuantityStepper` for consistency at the
/// call sites.
class _TapStepper extends StatelessWidget {
  const _TapStepper({
    required this.controller,
    required this.focusNode,
    required this.unitSuffix,
    required this.allowDecimal,
    required this.onSubmitted,
    required this.onIncrement,
    required this.onDecrement,
    this.hasError = false,
    this.semanticsLabel,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String unitSuffix;
  final bool allowDecimal;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;
  final bool hasError;
  final String? semanticsLabel;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = context.radius;
    final space = context.space;
    final inputFormatters = <TextInputFormatter>[
      // Allow digits and a single locale-tolerant decimal separator
      // (`.` or `,`). Stripping anything else keeps the on-screen glyph
      // close to what `parseWeightToKg` will accept on commit — which
      // already normalises `,` → `.` for us.
      allowDecimal
          ? FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))
          : FilteringTextInputFormatter.digitsOnly,
    ];
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
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  // Constrain the typeable area so the field stays
                  // visually centered with the unit suffix to its
                  // right. Without an `IntrinsicWidth` the `TextField`
                  // expands the whole Center cell and the suffix sits
                  // flush to the `+` button.
                  IntrinsicWidth(
                    child: TextField(
                      controller: controller,
                      focusNode: focusNode,
                      autofocus: autofocus,
                      textAlign: TextAlign.center,
                      keyboardType: TextInputType.numberWithOptions(
                        decimal: allowDecimal,
                      ),
                      inputFormatters: inputFormatters,
                      onSubmitted: onSubmitted,
                      style: context.text.bodyStrongNumeric
                          .copyWith(color: colors.ink),
                      decoration: const InputDecoration.collapsed(
                        hintText: '',
                      ),
                    ),
                  ),
                  SizedBox(width: space.x1),
                  Text(
                    unitSuffix,
                    style: context.text.bodyStrongNumeric
                        .copyWith(color: colors.ink),
                  ),
                ],
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
