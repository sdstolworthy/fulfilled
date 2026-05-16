import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../theme/context_extensions.dart';
import '../log_entry_sheet.dart' show quantityProvider;

/// The log-entry sheet's `+ value −` quantity input (T-07).
///
/// **Never a bare TextField for a number.** Layout: a pill-shaped row
/// with a minus button, a centered `TextField` accepting decimal input
/// (`numberWithOptions(decimal: true)`), and a plus button. Both
/// buttons and typing commit through the single per-sheet
/// [quantityProvider]; chips elsewhere in the sheet drive the same
/// provider so the value stays mirrored end-to-end.
///
/// Commit policy: text input commits on blur **and** on every parseable
/// keystroke (the preview block needs the live value to update; typing
/// `2.5` should not wait for focus loss before re-rendering the
/// preview). Stepper taps commit immediately.
///
/// The minimum step is `0.5`; the floor is `0.5` so users cannot save a
/// zero-quantity row (zero kcal in the day-summary would be confusing
/// noise). The plus/minus buttons clamp at `0.5`.
class QuantityStepper extends ConsumerStatefulWidget {
  const QuantityStepper({super.key});

  @override
  ConsumerState<QuantityStepper> createState() => _QuantityStepperState();
}

class _QuantityStepperState extends ConsumerState<QuantityStepper> {
  late final TextEditingController _ctrl;
  late final FocusNode _focus;

  /// Tracks whether the in-field text was last touched by the user (so
  /// outside changes — chip taps, stepper buttons — overwrite it) or by
  /// the model (so we don't fight the cursor mid-typing).
  bool _userIsEditing = false;

  static final Decimal _step = Decimal.parse('0.5');
  static final Decimal _floor = Decimal.parse('0.5');

  @override
  void initState() {
    super.initState();
    final initial = ref.read(quantityProvider);
    _ctrl = TextEditingController(text: _format(initial));
    _focus = FocusNode();
    _focus.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (!_focus.hasFocus) {
      _userIsEditing = false;
      // Re-sync display from the model on blur so a partial entry
      // ("1.") settles back to a clean number.
      final current = ref.read(quantityProvider);
      _ctrl.text = _format(current);
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  String _format(Decimal v) {
    // Trim trailing zeros — "1" not "1.00", "1.5" not "1.50". The
    // user-typed value is preserved via `_userIsEditing`.
    final s = v.toString();
    if (!s.contains('.')) return s;
    return s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }

  void _bump(Decimal delta) {
    final current = ref.read(quantityProvider);
    var next = current + delta;
    if (next < _floor) next = _floor;
    ref.read(quantityProvider.notifier).state = next;
  }

  void _onTextChanged(String raw) {
    _userIsEditing = true;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return;
    // Allow a trailing dot mid-typing without rejecting it.
    if (trimmed == '.') return;
    try {
      final parsed = Decimal.parse(trimmed);
      if (parsed < Decimal.zero) return;
      ref.read(quantityProvider.notifier).state = parsed;
    } on FormatException {
      // Filtering input formatter blocks most bad input; a stray '.'
      // can still arrive but is harmless to drop.
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final space = context.space;
    final radius = context.radius;
    final value = ref.watch(quantityProvider);

    // Keep the controller in sync with model changes initiated from
    // outside this widget (chip taps, stepper buttons) — but not while
    // the user is mid-edit, or the cursor jumps.
    final modelText = _format(value);
    if (!_userIsEditing && _ctrl.text != modelText) {
      _ctrl.value = TextEditingValue(
        text: modelText,
        selection: TextSelection.collapsed(offset: modelText.length),
      );
    }

    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(radius.r2),
        border: Border.all(color: colors.line, width: 1),
      ),
      padding: EdgeInsets.symmetric(horizontal: space.x3),
      child: Row(
        children: <Widget>[
          _RoundButton(
            icon: Icons.remove,
            semantics: 'Decrement quantity',
            onTap: () => _bump(-_step),
          ),
          Expanded(
            child: Center(
              child: TextField(
                key: const Key('log_entry_quantity_field'),
                controller: _ctrl,
                focusNode: _focus,
                textAlign: TextAlign.center,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                onChanged: _onTextChanged,
                onEditingComplete: () {
                  _userIsEditing = false;
                  _focus.unfocus();
                },
                style: context.text.title.copyWith(
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
                decoration: const InputDecoration(
                  isCollapsed: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
          ),
          _RoundButton(
            icon: Icons.add,
            semantics: 'Increment quantity',
            onTap: () => _bump(_step),
          ),
        ],
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.semantics,
    required this.onTap,
  });

  final IconData icon;
  final String semantics;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      button: true,
      label: semantics,
      child: InkResponse(
        radius: 24,
        onTap: onTap,
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: colors.accentSoft,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 18, color: colors.accent),
        ),
      ),
    );
  }
}

/// Quick-multiplier chips (0.5×, 1×, 1.5×, 2×, 3×). Tapping a chip
/// writes the multiplier to [quantityProvider]; the chip whose value
/// equals the current quantity renders selected.
class QuickMultiplierChips extends ConsumerWidget {
  const QuickMultiplierChips({super.key});

  static final List<Decimal> _values = <Decimal>[
    Decimal.parse('0.5'),
    Decimal.one,
    Decimal.parse('1.5'),
    Decimal.fromInt(2),
    Decimal.fromInt(3),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(quantityProvider);
    final space = context.space;
    return Row(
      children: <Widget>[
        for (var i = 0; i < _values.length; i++) ...<Widget>[
          if (i > 0) SizedBox(width: space.x1 + 2),
          Expanded(
            child: _Chip(
              value: _values[i],
              selected: _values[i] == current,
              onTap: () =>
                  ref.read(quantityProvider.notifier).state = _values[i],
            ),
          ),
        ],
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.value,
    required this.selected,
    required this.onTap,
  });

  final Decimal value;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = context.radius;
    final space = context.space;
    final label = '${_displayValue(value)}×';
    return Semantics(
      button: true,
      selected: selected,
      label: '$label multiplier',
      child: InkResponse(
        onTap: onTap,
        radius: 28,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: space.x2 + 2,
            vertical: space.x1 + 2,
          ),
          decoration: BoxDecoration(
            color: selected ? colors.accent : colors.surface,
            border: Border.all(
              color: selected ? colors.accent : colors.line,
            ),
            borderRadius: BorderRadius.circular(radius.r1),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: context.text.meta.copyWith(
              fontWeight: FontWeight.w500,
              color: selected ? colors.surface : colors.ink2,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }

  String _displayValue(Decimal v) {
    final s = v.toString();
    if (!s.contains('.')) return s;
    return s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }
}
