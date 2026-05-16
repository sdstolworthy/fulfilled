import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/enums.dart';
import '../../../domain/units/energy.dart';
import '../../../domain/units/macros.dart';
import '../../../providers/draft_providers.dart';
import '../../../theme/context_extensions.dart';
import '../calories_estimate.dart';
import 'goal_option.dart';

/// "Set a goal" step (3 of 3). Direction picker + rate slider + a
/// `LogPreviewBlock`-shaped daily-target preview. Calorie target is
/// derived **client-side** from the draft via [estimateCalories].
///
/// The preview block visual mirrors the inventory's `LogPreviewBlock` —
/// accent-soft tinted card with the kcal hero on the left and macro
/// chips below. We do not import the foundation widget here because the
/// onboarding context wants a slightly different label ("Your daily
/// target" vs. "Will log"); when the foundation lands a parameterised
/// version we'll switch.
class Step3Goal extends ConsumerWidget {
  const Step3Goal({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(onboardingDraftProvider);
    final notifier = ref.read(onboardingDraftProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _DirectionList(
          selected: draft.direction,
          onSelect: (d) {
            notifier.setDirection(d);
            // Default to 0.5 kg/week when picking lose/gain and no rate set.
            if (d != GoalDirection.maintain && draft.rateKgPerWeek == null) {
              notifier.setRateKgPerWeek(Decimal.parse('0.5'));
            }
          },
        ),
        if (draft.direction != null &&
            draft.direction != GoalDirection.maintain) ...<Widget>[
          SizedBox(height: context.space.x3),
          _RateCard(
            direction: draft.direction!,
            rate: draft.rateKgPerWeek ?? Decimal.parse('0.5'),
            onChanged: notifier.setRateKgPerWeek,
          ),
        ],
        SizedBox(height: context.space.x3),
        _TargetPreview(
          estimate: estimateCalories(
            sex: draft.sex,
            birthDate: draft.birthDate,
            heightCm: draft.heightCm,
            weightKg: draft.currentWeightKg,
            activityLevel: draft.activityLevel,
            direction: draft.direction,
            rateKgPerWeek: draft.rateKgPerWeek,
          ),
        ),
      ],
    );
  }
}

class _DirectionList extends StatelessWidget {
  const _DirectionList({required this.selected, required this.onSelect});

  final GoalDirection? selected;
  final ValueChanged<GoalDirection> onSelect;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        GoalOption(
          icon: Icons.keyboard_arrow_up_rounded,
          title: 'Gain weight',
          subtitle: 'Build muscle slowly',
          selected: selected == GoalDirection.gain,
          onTap: () => onSelect(GoalDirection.gain),
        ),
        SizedBox(height: context.space.x2 + 2),
        GoalOption(
          icon: Icons.remove_rounded,
          title: 'Maintain',
          subtitle: 'Stay where you are',
          selected: selected == GoalDirection.maintain,
          onTap: () => onSelect(GoalDirection.maintain),
        ),
        SizedBox(height: context.space.x2 + 2),
        GoalOption(
          icon: Icons.keyboard_arrow_down_rounded,
          title: 'Lose weight',
          subtitle: 'Sustainable cut · recommended',
          selected: selected == GoalDirection.lose,
          onTap: () => onSelect(GoalDirection.lose),
        ),
      ],
    );
  }
}

class _RateCard extends StatelessWidget {
  const _RateCard({
    required this.direction,
    required this.rate,
    required this.onChanged,
  });

  final GoalDirection direction;
  final Decimal rate;
  final ValueChanged<Decimal?> onChanged;

  static const List<double> _stops = <double>[0.25, 0.5, 0.75, 1.0];

  @override
  Widget build(BuildContext context) {
    final sign = direction == GoalDirection.lose ? '−' : '+';
    final value = rate.toDouble();
    return Container(
      padding: EdgeInsets.all(context.space.x4),
      decoration: BoxDecoration(
        color: context.colors.surface,
        borderRadius: BorderRadius.circular(context.radius.r3),
        border: Border.all(color: context.colors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'RATE',
            style: context.text.eyebrow.copyWith(color: context.colors.ink3),
          ),
          SizedBox(height: context.space.x2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              Text(
                '$sign${value.toStringAsFixed(value == value.roundToDouble() ? 1 : 2)}',
                style: context.text.heroNumeric.copyWith(
                  fontSize: 24,
                ),
              ),
              SizedBox(width: context.space.x1),
              Text(
                'kg / week',
                style: context.text.meta,
              ),
            ],
          ),
          SizedBox(height: context.space.x3),
          SliderTheme(
            data: SliderThemeData(
              activeTrackColor: context.colors.accent,
              inactiveTrackColor: context.colors.line2,
              thumbColor: context.colors.surface,
              overlayColor: context.colors.accentSoft,
              trackHeight: 6,
              thumbShape:
                  const RoundSliderThumbShape(enabledThumbRadius: 11),
              overlayShape:
                  const RoundSliderOverlayShape(overlayRadius: 18),
            ),
            child: Slider(
              value: value < 0.25 ? 0.25 : (value > 1.0 ? 1.0 : value),
              min: 0.25,
              max: 1.0,
              divisions: 3,
              onChanged: (v) => onChanged(Decimal.parse(v.toStringAsFixed(2))),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              for (final stop in _stops)
                Text(
                  '$sign${stop.toStringAsFixed(2)}',
                  style: context.text.meta.copyWith(
                    fontSize: 10,
                    color: context.colors.ink3,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TargetPreview extends StatelessWidget {
  const _TargetPreview({required this.estimate});

  final CalorieEstimate? estimate;

  @override
  Widget build(BuildContext context) {
    final hasEstimate = estimate != null;
    return Container(
      padding: EdgeInsets.all(context.space.x4),
      decoration: BoxDecoration(
        color: context.colors.accentSoft,
        borderRadius: BorderRadius.circular(context.radius.r2),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'YOUR DAILY TARGET',
                  style: context.text.eyebrow.copyWith(
                    color: context.colors.accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: context.space.x1),
                _TargetKcalText(estimate: estimate),
                if (hasEstimate) ...<Widget>[
                  SizedBox(height: context.space.x1),
                  _MacroChipsRow(estimate: estimate!),
                ],
              ],
            ),
          ),
          if (hasEstimate)
            Icon(
              Icons.check_rounded,
              size: 28,
              color: context.colors.accent,
            ),
        ],
      ),
    );
  }
}

class _TargetKcalText extends StatelessWidget {
  const _TargetKcalText({required this.estimate});

  final CalorieEstimate? estimate;

  @override
  Widget build(BuildContext context) {
    if (estimate == null) {
      return Text(
        'Fill in step 2 to see your target',
        style: context.text.body.copyWith(color: context.colors.accent),
      );
    }
    final kcal = formatKcal(Decimal.fromInt(estimate!.dailyTargetKcal));
    return RichText(
      text: TextSpan(
        style: context.text.heroNumeric.copyWith(
          color: context.colors.accent,
          fontSize: 22,
        ),
        children: <InlineSpan>[
          TextSpan(text: kcal),
          TextSpan(
            text: ' kcal',
            style: context.text.body.copyWith(
              color: context.colors.accent,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _MacroChipsRow extends StatelessWidget {
  const _MacroChipsRow({required this.estimate});

  final CalorieEstimate estimate;

  @override
  Widget build(BuildContext context) {
    final p = formatGrams(Decimal.fromInt(estimate.proteinG));
    final c = formatGrams(Decimal.fromInt(estimate.carbsG));
    final f = formatGrams(Decimal.fromInt(estimate.fatG));
    return Wrap(
      spacing: context.space.x3 + 2,
      children: <Widget>[
        _MacroChip(label: 'P', value: '$p g'),
        _MacroChip(label: 'C', value: '$c g'),
        _MacroChip(label: 'F', value: '$f g'),
      ],
    );
  }
}

class _MacroChip extends StatelessWidget {
  const _MacroChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return RichText(
      text: TextSpan(
        style: context.text.meta.copyWith(
          color: context.colors.accent,
          fontSize: 11,
        ),
        children: <InlineSpan>[
          TextSpan(text: '$label '),
          TextSpan(
            text: value,
            style: context.text.bodyStrongNumeric.copyWith(
              color: context.colors.ink,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}
