import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
/// **cm** renders a single stepper — a centered `bodyStrongNumeric`
/// value flanked by tap-only `-` / `+` buttons. Visually matches
/// `WeightStepper`'s kg/lb mode; the centered chrome is a styled
/// `TextField` so the user can type a value directly. The displayed
/// value is the canonical cm rounded half-to-even to the nearest
/// integer cm (architect §5.6); +/- bumps by 1 cm and emits canonical
/// cm on every commit.
///
/// **ftIn** renders two integer sub-steppers side-by-side — feet (3..8
/// soft clamp; buttons disable at edges) and inches (0..11) — using
/// the same chrome. Each sub-field is its own integer-only
/// `TextField`. The +/- buttons on the inches field carry / borrow
/// across the feet field: `11 in + 1 = 1 ft 0 in` and
/// `0 in − 1 = (feet − 1) ft 11 in`. State for the two integers lives
/// in `_HeightStepperState`;
/// `onChanged(parseFeetInchesToCm(feet, inches))` fires on every
/// commit.
///
/// **Clamps.** [minCm] / [maxCm] gate the cm-mode `+`/`-` buttons so
/// the displayed value never goes out of range. Typed values that fall
/// outside the clamps are pulled to the nearest bound before commit
/// (the revert path mirrors what the +/- buttons already do). The
/// ftIn mode uses the soft `3..8 ft` × `0..11 in` integer clamps
/// directly — converting [minCm] / [maxCm] through 2.54 would produce
/// non-intuitive button disable states on the feet side (e.g.
/// `min = 80 cm` would translate to `2.6 ft` which doesn't align with
/// the soft `3 ft` floor). PM-punted ergonomics; the ftIn integer
/// floors are the right shape here.
///
/// **Keyboard input.** Locale-tolerant — accepts both `.` and `,` as
/// the decimal separator in cm mode (mirrors `parseHeightToCm`); ftIn
/// sub-fields are integer-only. Empty input on blur reverts to the
/// last canonical value; unparseable input also reverts. No error UI
/// for v1 — the revert is the feedback.
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

  /// Controllers for the keyboard input seam. The cm-mode field uses
  /// [_cmCtrl]; ftIn mode uses [_feetCtrl] + [_inchesCtrl]. Each has a
  /// matching `FocusNode` so the commit-on-blur listener can fire.
  late final TextEditingController _cmCtrl;
  late final FocusNode _cmFocus;
  late final TextEditingController _feetCtrl;
  late final FocusNode _feetFocus;
  late final TextEditingController _inchesCtrl;
  late final FocusNode _inchesFocus;

  @override
  void initState() {
    super.initState();
    _syncFtInFromCm(widget.value);
    _cmCtrl = TextEditingController(text: _seedCmText());
    _cmFocus = FocusNode();
    _cmFocus.addListener(_handleCmFocusChange);
    _feetCtrl = TextEditingController(text: '$_feet');
    _feetFocus = FocusNode();
    _feetFocus.addListener(_handleFeetFocusChange);
    _inchesCtrl = TextEditingController(text: '$_inches');
    _inchesFocus = FocusNode();
    _inchesFocus.addListener(_handleInchesFocusChange);
  }

  @override
  void didUpdateWidget(covariant HeightStepper old) {
    super.didUpdateWidget(old);
    // Re-sync whenever the canonical value OR the unit override
    // changes — toggling cm ↔ ftIn via the override should re-format
    // the visible glyph even though the canonical cm is unchanged.
    final unitChanged = widget.unitOverride != old.unitOverride;
    if (widget.value != old.value || unitChanged) {
      _syncFtInFromCm(widget.value);
      // Mirror the new canonical value into whichever controller is
      // currently not being edited. Skipping focused controllers
      // avoids caret thrash mid-keystroke.
      if (!_cmFocus.hasFocus) {
        final t = _seedCmText();
        if (_cmCtrl.text != t) _cmCtrl.text = t;
      }
      if (!_feetFocus.hasFocus) {
        final t = '$_feet';
        if (_feetCtrl.text != t) _feetCtrl.text = t;
      }
      if (!_inchesFocus.hasFocus) {
        final t = '$_inches';
        if (_inchesCtrl.text != t) _inchesCtrl.text = t;
      }
    }
  }

  @override
  void dispose() {
    _cmFocus.removeListener(_handleCmFocusChange);
    _feetFocus.removeListener(_handleFeetFocusChange);
    _inchesFocus.removeListener(_handleInchesFocusChange);
    _cmCtrl.dispose();
    _cmFocus.dispose();
    _feetCtrl.dispose();
    _feetFocus.dispose();
    _inchesCtrl.dispose();
    _inchesFocus.dispose();
    super.dispose();
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

  /// Seed text for the cm-mode `TextField`: the canonical cm rounded
  /// to the nearest integer.
  String _seedCmText() {
    final rounded = roundHalfToEvenScaled(widget.value, 0);
    return '${rounded.toBigInt()}';
  }

  void _handleCmFocusChange() {
    if (_cmFocus.hasFocus) return;
    _commitCmText();
  }

  void _handleFeetFocusChange() {
    if (_feetFocus.hasFocus) return;
    _commitFtInSubField(isFeet: true);
  }

  void _handleInchesFocusChange() {
    if (_inchesFocus.hasFocus) return;
    _commitFtInSubField(isFeet: false);
  }

  /// Parse the cm `TextField`, clamp to bounds, and commit. On parse
  /// failure or empty input, revert the controller to the last
  /// canonical value.
  void _commitCmText() {
    final raw = _cmCtrl.text.trim();
    void revert() {
      _cmCtrl.text = _seedCmText();
    }
    if (raw.isEmpty) {
      revert();
      return;
    }
    Decimal parsed;
    try {
      parsed = parseHeightToCm(raw, HeightUnit.cm);
    } on FormatException {
      revert();
      return;
    }
    final minCm = widget.minCm ?? _defaultMinCm;
    final maxCm = widget.maxCm ?? _defaultMaxCm;
    if (parsed < minCm) parsed = minCm;
    if (parsed > maxCm) parsed = maxCm;
    // Round to integer cm before emitting so the canonical cm the
    // parent receives matches the on-screen integer.
    final canonical = roundHalfToEvenScaled(parsed, 0);
    if (canonical != widget.value) {
      widget.onChanged(canonical);
    }
    // Always re-seed to drop leading zeros, `.5` fragments, etc.
    _cmCtrl.text = '${canonical.toBigInt()}';
  }

  void _commitFtInSubField({required bool isFeet}) {
    final ctrl = isFeet ? _feetCtrl : _inchesCtrl;
    final raw = ctrl.text.trim();
    void revert() {
      ctrl.text = isFeet ? '$_feet' : '$_inches';
    }
    if (raw.isEmpty) {
      revert();
      return;
    }
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed < 0) {
      revert();
      return;
    }
    int nextFeet = _feet;
    int nextInches = _inches;
    if (isFeet) {
      // Clamp to the soft 3..8 ft range so the typed value matches the
      // button gate behaviour.
      nextFeet = parsed;
      if (nextFeet < _minFeet) nextFeet = _minFeet;
      if (nextFeet > _maxFeet) nextFeet = _maxFeet;
    } else {
      // Inches clamp at 0..11 (anything 12+ snaps to 11 — we don't
      // carry on commit; the +/- buttons own the carry seam).
      nextInches = parsed > _maxInches ? _maxInches : parsed;
    }
    if (nextFeet == _feet && nextInches == _inches) {
      ctrl.text = isFeet ? '$_feet' : '$_inches';
      return;
    }
    setState(() {
      _feet = nextFeet;
      _inches = nextInches;
    });
    ctrl.text = isFeet ? '$_feet' : '$_inches';
    widget.onChanged(parseFeetInchesToCm(_feet, _inches));
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
      final newText = '${next.toBigInt()}';
      if (_cmCtrl.text != newText) _cmCtrl.text = newText;
      widget.onChanged(next);
    }

    // Pull the integer count via toBigInt — the rounded value is an
    // exact integer cm so this is lossless.
    final cmInt = displayCm.toBigInt();
    return _TapStepper(
      controller: _cmCtrl,
      focusNode: _cmFocus,
      unitSuffix: 'cm',
      allowDecimal: true,
      onSubmitted: (_) => _commitCmText(),
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
            controller: _feetCtrl,
            focusNode: _feetFocus,
            unitSuffix: 'ft',
            allowDecimal: false,
            onSubmitted: (_) => _commitFtInSubField(isFeet: true),
            onIncrement: feetAtCeiling
                ? null
                : () {
                    setState(() => _feet += 1);
                    _feetCtrl.text = '$_feet';
                    widget.onChanged(parseFeetInchesToCm(_feet, _inches));
                  },
            onDecrement: feetAtFloor
                ? null
                : () {
                    setState(() => _feet -= 1);
                    _feetCtrl.text = '$_feet';
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
            controller: _inchesCtrl,
            focusNode: _inchesFocus,
            unitSuffix: 'in',
            allowDecimal: false,
            onSubmitted: (_) => _commitFtInSubField(isFeet: false),
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
    _feetCtrl.text = '$_feet';
    _inchesCtrl.text = '$_inches';
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
    _feetCtrl.text = '$_feet';
    _inchesCtrl.text = '$_inches';
    widget.onChanged(parseFeetInchesToCm(_feet, _inches));
  }
}

/// Display-only stepper — sibling of `WeightStepper`'s inline
/// `_TapStepper` (see `weight_stepper.dart`). Re-inlined here rather
/// than lifted to a shared `lib/widgets/tap_stepper.dart` primitive;
/// architect §5.6 explicitly defers that lift to v1.1, and the weight
/// stepper already named the convergence as future work.
///
/// Shape: 48-px tall `Container`, 1-px line border, `radius.r2`,
/// `bodyStrongNumeric` centered label (now a styled `TextField` so the
/// user can type), unit suffix rendered as a sibling `Text` to the
/// right of the field, `_TapStepperButton`s on either side. The
/// `TextField` strips its own border / underline / fill so the chrome
/// stays pixel-identical to the previous `Text`-only version when
/// unfocused. `hasError` flips the border / background to the danger
/// tokens — same convention as `QuantityStepper` and `WeightStepper`
/// for consistency at the call sites.
///
/// Passing `null` for [onIncrement] or [onDecrement] disables that
/// side of the stepper — used by the clamp gates (cm at min/max, feet
/// at 3/8, the absolute ftIn floor/ceiling).
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
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String unitSuffix;
  final bool allowDecimal;
  final ValueChanged<String> onSubmitted;
  final VoidCallback? onIncrement;
  final VoidCallback? onDecrement;
  final bool hasError;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = context.radius;
    final space = context.space;
    final inputFormatters = <TextInputFormatter>[
      // Allow digits and a single locale-tolerant decimal separator
      // (`.` or `,`). Stripping anything else keeps the on-screen glyph
      // close to what `parseHeightToCm` will accept on commit — which
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
