import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/drafts.dart';
import '../../../providers/draft_providers.dart';
import '../../../theme/context_extensions.dart';
import 'labeled_field.dart';
import 'quantity_stepper.dart';

/// Editor variant of `ServingList`. The read-only `ServingList` belongs
/// to `features/food_detail/`; this widget is the write surface.
///
/// Rules per arch §9 and PM:
/// - Do NOT render the 100 g system serving — it is auto-seeded
///   server-side, never user-managed (T-10 / arch gotcha).
/// - Add / edit / delete user-defined servings.
/// - Each numeric input goes through `QuantityStepper` (T-07).
///
/// Empty-state copy ("No servings — defaults to 100 g") tells the user
/// what they'll get on save with zero rows.
class ServingsSection extends ConsumerStatefulWidget {
  const ServingsSection({super.key});

  @override
  ConsumerState<ServingsSection> createState() => _ServingsSectionState();
}

class _ServingsSectionState extends ConsumerState<ServingsSection> {
  void _addServing() {
    final notifier = ref.read(customFoodDraftProvider.notifier);
    final current = ref.read(customFoodDraftProvider).userServings;
    notifier.setServings(<DraftServing>[
      ...current,
      DraftServing(label: '', grams: Decimal.zero),
    ]);
  }

  void _updateAt(int i, DraftServing next) {
    final notifier = ref.read(customFoodDraftProvider.notifier);
    final current = ref.read(customFoodDraftProvider).userServings;
    final copy = <DraftServing>[...current];
    copy[i] = next;
    notifier.setServings(copy);
  }

  void _removeAt(int i) {
    final notifier = ref.read(customFoodDraftProvider.notifier);
    final current = ref.read(customFoodDraftProvider).userServings;
    final copy = <DraftServing>[...current]..removeAt(i);
    notifier.setServings(copy);
  }

  @override
  Widget build(BuildContext context) {
    final draft = ref.watch(customFoodDraftProvider);
    final servings = draft.userServings;
    final colors = context.colors;
    final radius = context.radius;
    final space = context.space;

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
                  'No servings yet — your food will default to 100 g.',
                  style: context.text.meta.copyWith(color: colors.ink2),
                ),
              ] else
                for (var i = 0; i < servings.length; i++)
                  _ServingRow(
                    key: ValueKey<int>(i),
                    serving: servings[i],
                    isFirst: i == 0,
                    onChanged: (s) => _updateAt(i, s),
                    onRemove: () => _removeAt(i),
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
        Text(
          'Custom servings',
          style: context.text.bodyStrong,
        ),
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
    required this.serving,
    required this.isFirst,
    required this.onChanged,
    required this.onRemove,
  });

  final DraftServing serving;
  final bool isFirst;
  final ValueChanged<DraftServing> onChanged;
  final VoidCallback onRemove;

  @override
  State<_ServingRow> createState() => _ServingRowState();
}

class _ServingRowState extends State<_ServingRow> {
  late final TextEditingController _labelCtrl;
  late final FocusNode _labelFocus;

  @override
  void initState() {
    super.initState();
    _labelCtrl = TextEditingController(text: widget.serving.label);
    _labelFocus = FocusNode();
  }

  @override
  void didUpdateWidget(covariant _ServingRow old) {
    super.didUpdateWidget(old);
    if (!_labelFocus.hasFocus && _labelCtrl.text != widget.serving.label) {
      _labelCtrl.text = widget.serving.label;
    }
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _labelFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = context.radius;
    final space = context.space;

    return Container(
      padding: EdgeInsets.symmetric(vertical: space.x2 + 2),
      decoration: BoxDecoration(
        border: Border(
          top: widget.isFirst
              ? BorderSide.none
              : BorderSide(color: colors.line2, width: 1),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: LabeledField(
              label: 'Label',
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
                  onChanged: (v) => widget.onChanged(DraftServing(
                    label: v,
                    grams: widget.serving.grams,
                  )),
                  style: context.text.body,
                  decoration: InputDecoration(
                    isCollapsed: true,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    hintText: '1 cup, ½ square…',
                    hintStyle: context.text.body.copyWith(color: colors.ink3),
                  ),
                ),
              ),
            ),
          ),
          SizedBox(width: space.x2 + 2),
          SizedBox(
            width: 110,
            child: LabeledField(
              label: 'Grams',
              child: QuantityStepper(
                value: widget.serving.grams == Decimal.zero
                    ? null
                    : widget.serving.grams,
                onChanged: (g) => widget.onChanged(DraftServing(
                  label: widget.serving.label,
                  grams: g ?? Decimal.zero,
                )),
                unitSuffix: 'g',
                placeholder: '0',
                showStepperButtons: false,
                semanticsLabel: 'Serving grams',
                min: Decimal.zero,
              ),
            ),
          ),
          SizedBox(width: space.x2),
          Padding(
            padding: EdgeInsets.only(top: space.x4),
            child: Semantics(
              button: true,
              label: 'Remove serving',
              child: InkResponse(
                onTap: widget.onRemove,
                radius: 18,
                child: Icon(Icons.close, size: 18, color: colors.ink3),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
