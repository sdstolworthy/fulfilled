import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/context_extensions.dart';

/// Canonical numeric input with `-` / `+` buttons (T-07 "every numeric
/// input has a stepper, never a bare TextField for a number").
///
/// **Callback-shaped** — the widget is intentionally NOT Riverpod-coupled.
/// Drive it from any source of truth via [value] + [onChanged]. The
/// `log_entry` sheet wraps it in a `Consumer` that bridges its
/// sheet-scoped `quantityProvider`; other call sites (custom-food editor,
/// weight log sheet) pass their own local state straight through.
///
/// Layout: `[-] [field with optional unit suffix] [+]`. Stepper buttons
/// can be hidden via [showStepperButtons] for dense 3-column layouts
/// (the custom-food P/C/F row uses this).
///
/// Number values are `Decimal` end-to-end (T-17). Format and parse via
/// `package:decimal`; never `double.parse`.
class QuantityStepper extends StatefulWidget {
  const QuantityStepper({
    super.key,
    required this.value,
    required this.onChanged,
    this.step,
    this.min,
    this.max,
    this.placeholder,
    this.unitSuffix,
    this.hasError = false,
    this.semanticsLabel,
    this.allowDecimal = true,
    this.showStepperButtons = true,
  });

  /// Current value. `null` means the field is empty — the UI shows
  /// [placeholder] and the stepper buttons assume zero as the base.
  final Decimal? value;

  /// Called when the value changes from typing or button taps. `null` is
  /// emitted when the field is cleared.
  final ValueChanged<Decimal?> onChanged;

  /// Increment / decrement step. Defaults to `Decimal.one`.
  final Decimal? step;

  /// Optional inclusive floor. The plus/minus buttons clamp at this
  /// value; typed values below it are rejected.
  final Decimal? min;

  /// Optional inclusive ceiling. Mirrors [min].
  final Decimal? max;

  /// Hint shown when [value] is `null`.
  final String? placeholder;

  /// Optional trailing unit (e.g. `"g"`, `"kg"`, `"kcal"`, `"mg"`).
  final String? unitSuffix;

  /// When true, renders the field with the error border. The inline help
  /// row (T-11) is rendered by the surrounding `LabeledField`, not here,
  /// so the stepper stays composable.
  final bool hasError;

  /// Optional Semantics label for the wrapped text field.
  final String? semanticsLabel;

  /// When false, only digits are accepted (no decimal point).
  final bool allowDecimal;

  /// Set to false to render just the input with unit suffix — useful for
  /// dense layouts (the 3-column macro rows in custom-food's nutrition
  /// section don't show per-field buttons because there's no room).
  final bool showStepperButtons;

  @override
  State<QuantityStepper> createState() => _QuantityStepperState();
}

class _QuantityStepperState extends State<QuantityStepper> {
  late final TextEditingController _ctrl;
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: _format(widget.value));
    _focus = FocusNode();
  }

  @override
  void didUpdateWidget(covariant QuantityStepper old) {
    super.didUpdateWidget(old);
    // Sync controller when the model changes from outside (e.g. button
    // tap routed through the parent rebuilds with a new value). Skip if
    // the user is mid-edit — that prevents cursor-position thrash.
    if (!_focus.hasFocus) {
      final newText = _format(widget.value);
      if (_ctrl.text != newText) {
        _ctrl.text = newText;
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  String _format(Decimal? v) {
    if (v == null) return '';
    // Trim trailing zeros after the decimal — "14" not "14.00".
    final s = v.toString();
    if (!s.contains('.')) return s;
    return s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }

  Decimal _step() => widget.step ?? Decimal.one;

  void _bump(Decimal delta) {
    final current = widget.value ?? Decimal.zero;
    var next = current + delta;
    if (widget.min != null && next < widget.min!) next = widget.min!;
    if (widget.max != null && next > widget.max!) next = widget.max!;
    widget.onChanged(next);
  }

  void _onTextChanged(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      widget.onChanged(null);
      return;
    }
    // Allow a trailing dot mid-typing without rejecting it.
    if (trimmed == '.') return;
    try {
      final parsed = Decimal.parse(trimmed);
      if (widget.min != null && parsed < widget.min!) return;
      if (widget.max != null && parsed > widget.max!) return;
      widget.onChanged(parsed);
    } on FormatException {
      // The input formatter blocks most bad input; a stray '.' can still
      // land here and is harmless to drop.
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final space = context.space;
    final radius = context.radius;
    final hasError = widget.hasError;

    final inputFormatters = <TextInputFormatter>[
      widget.allowDecimal
          ? FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))
          : FilteringTextInputFormatter.digitsOnly,
    ];

    final field = Container(
      height: 46,
      decoration: BoxDecoration(
        // TODO(T-014/B2): replace this hex with `colors.dangerSoft` when
        // the token sweep lands. Kept as-is here to make the lift a pure
        // refactor (no visual delta vs the pre-lift custom_food widget).
        color: hasError ? const Color(0xFFFFF8F3) : colors.surface,
        borderRadius: BorderRadius.circular(radius.r2),
        border: Border.all(
          color: hasError ? colors.danger : colors.line,
          width: 1,
        ),
      ),
      padding: EdgeInsets.symmetric(horizontal: space.x3),
      alignment: Alignment.center,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Semantics(
              label: widget.semanticsLabel,
              textField: true,
              child: TextField(
                controller: _ctrl,
                focusNode: _focus,
                keyboardType: TextInputType.numberWithOptions(
                  decimal: widget.allowDecimal,
                ),
                inputFormatters: inputFormatters,
                onChanged: _onTextChanged,
                textAlignVertical: TextAlignVertical.center,
                style: context.text.bodyStrong.copyWith(
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
                decoration: InputDecoration(
                  isCollapsed: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  hintText: widget.placeholder ?? '—',
                  hintStyle:
                      context.text.bodyStrong.copyWith(color: colors.ink3),
                ),
              ),
            ),
          ),
          if (widget.unitSuffix != null)
            Padding(
              padding: EdgeInsets.only(left: space.x2),
              child: Text(
                widget.unitSuffix!.toLowerCase(),
                style: context.text.meta.copyWith(color: colors.ink3),
              ),
            ),
        ],
      ),
    );

    if (!widget.showStepperButtons) return field;
    return Row(
      children: <Widget>[
        _StepperBtn(
          icon: Icons.remove,
          onTap: () => _bump(Decimal.zero - _step()),
          semantics: 'Decrement',
        ),
        SizedBox(width: space.x2),
        Expanded(child: field),
        SizedBox(width: space.x2),
        _StepperBtn(
          icon: Icons.add,
          onTap: () => _bump(_step()),
          semantics: 'Increment',
        ),
      ],
    );
  }
}

class _StepperBtn extends StatelessWidget {
  const _StepperBtn({
    required this.icon,
    required this.onTap,
    required this.semantics,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String semantics;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = context.radius;
    return Semantics(
      button: true,
      label: semantics,
      child: InkResponse(
        radius: 24,
        onTap: onTap,
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(radius.r2),
            border: Border.all(color: colors.line, width: 1),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 18, color: colors.ink2),
        ),
      ),
    );
  }
}
