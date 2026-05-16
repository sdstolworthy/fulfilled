import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/draft_providers.dart';
import '../../../theme/context_extensions.dart';
import 'labeled_field.dart';
import 'quantity_stepper.dart';

/// "Nutrition per 100 g" section. Calories (full-width with stepper
/// buttons) + P/C/F row + Fiber/Sugar/Sodium row.
///
/// Client-required (architecture §9 gotcha): kcal, protein, carbs, fat.
/// Fiber, sugar, sodium are optional. Sodium is captured in **mg** per
/// T-21 / PM Display Units Principle — the screen converts to g before
/// the POST.
class NutritionSection extends ConsumerWidget {
  const NutritionSection({super.key, this.showErrors = false});

  /// Save was attempted. Drives the inline "Required" rows under each
  /// missing numeric field. Inline-only — no dialogs (T-11).
  final bool showErrors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(customFoodDraftProvider);
    final notifier = ref.read(customFoodDraftProvider.notifier);
    final space = context.space;
    final zero = Decimal.zero;

    String? errOrNull(Object? v) =>
        showErrors && v == null ? 'Required' : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Nutrition per 100 g'.toUpperCase(),
          style: context.text.eyebrow.copyWith(color: context.colors.ink3),
        ),
        SizedBox(height: space.x3),

        // Calories — full-width, with stepper buttons.
        LabeledField(
          label: 'Calories',
          errorText: errOrNull(draft.energyKcal),
          child: QuantityStepper(
            value: draft.energyKcal,
            onChanged: notifier.setEnergyKcal,
            unitSuffix: 'kcal',
            hasError: errOrNull(draft.energyKcal) != null,
            semanticsLabel: 'Calories per 100 g',
            placeholder: '0',
            min: zero,
          ),
        ),
        SizedBox(height: space.x3),

        // Protein / Carbs / Fat — 3-col row, no per-field stepper buttons
        // (no room in the mock). Still uses QuantityStepper so T-07 is
        // honored at the input layer.
        _Row3(
          children: <Widget>[
            LabeledField(
              label: 'Protein',
              errorText: errOrNull(draft.proteinG),
              child: QuantityStepper(
                value: draft.proteinG,
                onChanged: notifier.setProteinG,
                unitSuffix: 'g',
                hasError: errOrNull(draft.proteinG) != null,
                semanticsLabel: 'Protein grams',
                placeholder: '0',
                min: zero,
                showStepperButtons: false,
              ),
            ),
            LabeledField(
              label: 'Carbs',
              errorText: errOrNull(draft.carbsG),
              child: QuantityStepper(
                value: draft.carbsG,
                onChanged: notifier.setCarbsG,
                unitSuffix: 'g',
                hasError: errOrNull(draft.carbsG) != null,
                semanticsLabel: 'Carbs grams',
                placeholder: '0',
                min: zero,
                showStepperButtons: false,
              ),
            ),
            LabeledField(
              label: 'Fat',
              errorText: errOrNull(draft.fatG),
              child: QuantityStepper(
                value: draft.fatG,
                onChanged: notifier.setFatG,
                unitSuffix: 'g',
                hasError: errOrNull(draft.fatG) != null,
                semanticsLabel: 'Fat grams',
                placeholder: '0',
                min: zero,
                showStepperButtons: false,
              ),
            ),
          ],
        ),
        SizedBox(height: space.x3),

        // Fiber / Sugar / Sodium — none required. Sodium is mg (T-21).
        _Row3(
          children: <Widget>[
            LabeledField(
              label: 'Fiber',
              child: QuantityStepper(
                value: draft.fiberG,
                onChanged: notifier.setFiberG,
                unitSuffix: 'g',
                semanticsLabel: 'Fiber grams',
                placeholder: '0',
                min: zero,
                showStepperButtons: false,
              ),
            ),
            LabeledField(
              label: 'Sugar',
              child: QuantityStepper(
                value: draft.sugarG,
                onChanged: notifier.setSugarG,
                unitSuffix: 'g',
                semanticsLabel: 'Sugar grams',
                placeholder: '0',
                min: zero,
                showStepperButtons: false,
              ),
            ),
            LabeledField(
              label: 'Sodium',
              child: QuantityStepper(
                value: draft.sodiumMg,
                onChanged: notifier.setSodiumMg,
                unitSuffix: 'mg',
                semanticsLabel: 'Sodium milligrams',
                placeholder: '0',
                min: zero,
                showStepperButtons: false,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Row3 extends StatelessWidget {
  const _Row3({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final gap = context.space.x2 + 2; // 10 px per mock.
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
