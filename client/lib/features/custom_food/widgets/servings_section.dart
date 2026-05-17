import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fulfilled/widgets/quantity_stepper.dart';

import '../../../domain/drafts.dart';
import '../../../domain/unit.dart';
import '../../../providers/draft_providers.dart';
import '../../../theme/context_extensions.dart';
import 'labeled_field.dart';

/// Servings editor — per Ask 10 nutrition lives **per serving**. Every
/// row is `{label?, amount, unit, kcal, optional macros, is_default}`.
/// The food row itself carries no top-level nutrition; the standalone
/// `NutritionSection` is gone.
///
/// Each serving renders as a card with:
///   1. Label (optional free-text, e.g. "1 pouch", "small").
///   2. Amount + Unit picker + Kcal (compact row).
///   3. Optional macros (expandable; protein/carbs/fat default-collapsed
///      so the form doesn't feel intimidating at first paint).
///   4. Default toggle + delete affordance.
///
/// Validation per-row: `amount > 0` AND `kcal` non-null. Errors surface
/// as inline "Required" hints under each field when [showErrors] is true.
class ServingsSection extends ConsumerStatefulWidget {
  const ServingsSection({super.key, this.showErrors = false});

  /// Save was attempted; show inline "Required" rows for each missing
  /// per-row field.
  final bool showErrors;

  @override
  ConsumerState<ServingsSection> createState() => _ServingsSectionState();
}

class _ServingsSectionState extends ConsumerState<ServingsSection> {
  /// Which rows have their macros panel expanded. Index-keyed; stale
  /// entries (after a row is removed) are trimmed in [_pruneExpansion].
  final Set<int> _expanded = <int>{};

  void _addServing() {
    ref.read(customFoodDraftProvider.notifier).addServing();
  }

  void _updateAt(int i, DraftServing next) {
    ref.read(customFoodDraftProvider.notifier).updateServingAt(i, next);
  }

  void _removeAt(int i) {
    ref.read(customFoodDraftProvider.notifier).removeServingAt(i);
    _pruneExpansion(removedAt: i);
  }

  void _markDefault(int i) {
    // Atomic single-default flip: clear isDefault on every row, set on
    // the picked one. Keeps the invariant the wire enforces.
    final servings = ref.read(customFoodDraftProvider).servings;
    final next = <DraftServing>[
      for (var k = 0; k < servings.length; k++)
        servings[k].copyWith(isDefault: k == i),
    ];
    ref.read(customFoodDraftProvider.notifier).setServings(next);
  }

  void _toggleExpanded(int i) {
    setState(() {
      if (_expanded.contains(i)) {
        _expanded.remove(i);
      } else {
        _expanded.add(i);
      }
    });
  }

  void _pruneExpansion({required int removedAt}) {
    setState(() {
      // Re-key after removal: indices above `removedAt` slide down by 1.
      final next = <int>{};
      for (final k in _expanded) {
        if (k == removedAt) continue;
        next.add(k > removedAt ? k - 1 : k);
      }
      _expanded
        ..clear()
        ..addAll(next);
    });
  }

  @override
  Widget build(BuildContext context) {
    final draft = ref.watch(customFoodDraftProvider);
    final servings = draft.servings;
    final colors = context.colors;
    final radius = context.radius;
    final space = context.space;

    final missingServingsError =
        widget.showErrors && servings.isEmpty ? 'At least one serving' : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Servings'.toUpperCase(),
          style: context.text.eyebrow.copyWith(color: colors.ink3),
        ),
        SizedBox(height: space.x3),
        Container(
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(radius.r3),
            border: Border.all(color: colors.line, width: 1),
          ),
          padding: EdgeInsets.all(space.x4 - 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _ServingsHeader(onAdd: _addServing),
              if (servings.isEmpty) ...<Widget>[
                SizedBox(height: space.x3),
                Text(
                  missingServingsError ??
                      'Add at least one serving — the food needs '
                          'something to log against.',
                  style: context.text.meta.copyWith(
                    color: missingServingsError != null
                        ? colors.danger
                        : colors.ink2,
                  ),
                ),
              ] else
                for (var i = 0; i < servings.length; i++)
                  _ServingRow(
                    key: ValueKey<int>(i),
                    index: i,
                    serving: servings[i],
                    isFirst: i == 0,
                    isExpanded: _expanded.contains(i),
                    showErrors: widget.showErrors,
                    onChanged: (s) => _updateAt(i, s),
                    onRemove: () => _removeAt(i),
                    onMarkDefault: () => _markDefault(i),
                    onToggleExpanded: () => _toggleExpanded(i),
                  ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ServingsHeader extends StatelessWidget {
  const _ServingsHeader({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final space = context.space;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        Text('Servings', style: context.text.bodyStrong),
        Semantics(
          button: true,
          label: 'Add serving',
          child: InkResponse(
            onTap: onAdd,
            radius: 22,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: space.x1,
                vertical: space.x1,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.add, size: 14, color: colors.accent),
                  SizedBox(width: space.x1),
                  Text(
                    'Add serving',
                    style: context.text.meta.copyWith(
                      color: colors.accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ServingRow extends StatefulWidget {
  const _ServingRow({
    super.key,
    required this.index,
    required this.serving,
    required this.isFirst,
    required this.isExpanded,
    required this.showErrors,
    required this.onChanged,
    required this.onRemove,
    required this.onMarkDefault,
    required this.onToggleExpanded,
  });

  final int index;
  final DraftServing serving;
  final bool isFirst;
  final bool isExpanded;
  final bool showErrors;
  final ValueChanged<DraftServing> onChanged;
  final VoidCallback onRemove;
  final VoidCallback onMarkDefault;
  final VoidCallback onToggleExpanded;

  @override
  State<_ServingRow> createState() => _ServingRowState();
}

class _ServingRowState extends State<_ServingRow> {
  late final TextEditingController _labelCtrl;
  late final FocusNode _labelFocus;

  @override
  void initState() {
    super.initState();
    _labelCtrl = TextEditingController(text: widget.serving.label ?? '');
    _labelFocus = FocusNode();
  }

  @override
  void didUpdateWidget(covariant _ServingRow old) {
    super.didUpdateWidget(old);
    final next = widget.serving.label ?? '';
    if (!_labelFocus.hasFocus && _labelCtrl.text != next) {
      _labelCtrl.text = next;
    }
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _labelFocus.dispose();
    super.dispose();
  }

  String? _errOrNull(Object? v) =>
      widget.showErrors && v == null ? 'Required' : null;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = context.radius;
    final space = context.space;
    final s = widget.serving;

    return Container(
      padding: EdgeInsets.symmetric(vertical: space.x3),
      decoration: BoxDecoration(
        border: Border(
          top: widget.isFirst
              ? BorderSide.none
              : BorderSide(color: colors.line2, width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // ── Label (optional) ──────────────────────────────────────
          LabeledField(
            label: 'Label (optional)',
            child: Container(
              height: 44,
              decoration: BoxDecoration(
                color: colors.bg,
                borderRadius: BorderRadius.circular(radius.r1 + 2),
                border: Border.all(color: colors.line, width: 1),
              ),
              padding: EdgeInsets.symmetric(horizontal: space.x3),
              alignment: Alignment.center,
              child: TextField(
                controller: _labelCtrl,
                focusNode: _labelFocus,
                onChanged: (v) => widget.onChanged(
                  s.copyWith(label: v.isEmpty ? null : v),
                ),
                style: context.text.body,
                decoration: InputDecoration(
                  isCollapsed: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  hintText: '1 cup, ½ square, small…',
                  hintStyle: context.text.body.copyWith(color: colors.ink3),
                ),
              ),
            ),
          ),
          SizedBox(height: space.x2 + 2),
          // ── Amount + Unit + Kcal ─────────────────────────────────
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                flex: 3,
                child: LabeledField(
                  label: 'Amount',
                  errorText: _errOrNull(s.amount),
                  child: QuantityStepper(
                    value: s.amount,
                    onChanged: (v) => widget.onChanged(s.copyWith(amount: v)),
                    unitSuffix: '',
                    placeholder: '0',
                    showStepperButtons: false,
                    semanticsLabel: 'Serving amount',
                    hasError: _errOrNull(s.amount) != null,
                  ),
                ),
              ),
              SizedBox(width: space.x2),
              Expanded(
                flex: 3,
                child: LabeledField(
                  label: 'Unit',
                  child: _UnitDropdown(
                    unit: s.unit,
                    onChanged: (u) => widget.onChanged(s.copyWith(unit: u)),
                  ),
                ),
              ),
              SizedBox(width: space.x2),
              Expanded(
                flex: 4,
                child: LabeledField(
                  label: 'Calories',
                  errorText: _errOrNull(s.kcal),
                  child: QuantityStepper(
                    value: s.kcal,
                    onChanged: (v) => widget.onChanged(s.copyWith(kcal: v)),
                    unitSuffix: 'kcal',
                    placeholder: '0',
                    showStepperButtons: false,
                    semanticsLabel: 'Calories per serving',
                    hasError: _errOrNull(s.kcal) != null,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: space.x2),
          // ── Macros toggle ────────────────────────────────────────
          InkWell(
            onTap: widget.onToggleExpanded,
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: space.x1),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    widget.isExpanded
                        ? Icons.expand_less
                        : Icons.expand_more,
                    size: 16,
                    color: colors.accent,
                  ),
                  SizedBox(width: space.x1),
                  Text(
                    widget.isExpanded ? 'Hide macros' : 'Add macros (optional)',
                    style: context.text.meta.copyWith(
                      color: colors.accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (widget.isExpanded) ...<Widget>[
            SizedBox(height: space.x2),
            _MacroRow(
              children: <Widget>[
                _MacroField(
                  label: 'Protein',
                  unit: 'g',
                  value: s.proteinG,
                  onChanged: (v) => widget.onChanged(s.copyWith(proteinG: v)),
                ),
                _MacroField(
                  label: 'Carbs',
                  unit: 'g',
                  value: s.carbsG,
                  onChanged: (v) => widget.onChanged(s.copyWith(carbsG: v)),
                ),
                _MacroField(
                  label: 'Fat',
                  unit: 'g',
                  value: s.fatG,
                  onChanged: (v) => widget.onChanged(s.copyWith(fatG: v)),
                ),
              ],
            ),
            SizedBox(height: space.x2),
            _MacroRow(
              children: <Widget>[
                _MacroField(
                  label: 'Fiber',
                  unit: 'g',
                  value: s.fiberG,
                  onChanged: (v) => widget.onChanged(s.copyWith(fiberG: v)),
                ),
                _MacroField(
                  label: 'Sugar',
                  unit: 'g',
                  value: s.sugarG,
                  onChanged: (v) => widget.onChanged(s.copyWith(sugarG: v)),
                ),
                _MacroField(
                  label: 'Sodium',
                  unit: 'mg',
                  value: s.sodiumMg,
                  onChanged: (v) => widget.onChanged(s.copyWith(sodiumMg: v)),
                ),
              ],
            ),
            SizedBox(height: space.x2),
            _MacroRow(
              children: <Widget>[
                _MacroField(
                  label: 'Sat. fat',
                  unit: 'g',
                  value: s.saturatedFatG,
                  onChanged: (v) =>
                      widget.onChanged(s.copyWith(saturatedFatG: v)),
                ),
                const SizedBox.shrink(),
                const SizedBox.shrink(),
              ],
            ),
          ],
          SizedBox(height: space.x2),
          // ── Footer: default toggle + remove ──────────────────────
          Row(
            children: <Widget>[
              InkWell(
                onTap: s.isDefault ? null : widget.onMarkDefault,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      s.isDefault
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 16,
                      color: s.isDefault ? colors.accent : colors.ink3,
                    ),
                    SizedBox(width: space.x1),
                    Text(
                      'Default',
                      style: context.text.meta.copyWith(
                        color: s.isDefault ? colors.ink : colors.ink2,
                        fontWeight:
                            s.isDefault ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              Semantics(
                button: true,
                label: 'Remove serving',
                child: InkResponse(
                  onTap: widget.onRemove,
                  radius: 18,
                  child: Icon(Icons.close, size: 18, color: colors.ink3),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Dropdown for picking a [Unit]. Groups units by family with a small
/// caption ("Mass", "Volume", "Count") between groups so the surfaced
/// list reads naturally.
class _UnitDropdown extends StatelessWidget {
  const _UnitDropdown({required this.unit, required this.onChanged});

  final Unit unit;
  final ValueChanged<Unit> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = context.radius;
    final space = context.space;

    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: colors.bg,
        borderRadius: BorderRadius.circular(radius.r1 + 2),
        border: Border.all(color: colors.line, width: 1),
      ),
      padding: EdgeInsets.symmetric(horizontal: space.x2),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<Unit>(
          value: unit,
          isExpanded: true,
          isDense: true,
          icon: Icon(Icons.expand_more, size: 18, color: colors.ink2),
          style: context.text.body.copyWith(color: colors.ink),
          dropdownColor: colors.surface,
          items: <DropdownMenuItem<Unit>>[
            for (final u in Unit.values)
              DropdownMenuItem<Unit>(
                value: u,
                child: Text(u.shortLabel),
              ),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }
}

class _MacroRow extends StatelessWidget {
  const _MacroRow({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final gap = context.space.x2 + 2;
    final widgets = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      widgets.add(Expanded(child: children[i]));
      if (i != children.length - 1) widgets.add(SizedBox(width: gap));
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: widgets,
      ),
    );
  }
}

class _MacroField extends StatelessWidget {
  const _MacroField({
    required this.label,
    required this.unit,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String unit;
  final Decimal? value;
  final ValueChanged<Decimal?> onChanged;

  @override
  Widget build(BuildContext context) {
    return LabeledField(
      label: label,
      child: QuantityStepper(
        value: value,
        onChanged: onChanged,
        unitSuffix: unit,
        placeholder: '—',
        showStepperButtons: false,
        semanticsLabel: '$label $unit',
      ),
    );
  }
}
