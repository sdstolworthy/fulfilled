import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/decimal_format.dart';
import '../../../domain/enums.dart';
import '../../../domain/units/energy.dart';
import '../../../domain/units/weight.dart';
import '../../../providers/profile_providers.dart';
import '../../../theme/context_extensions.dart';
import '../../../widgets/number_text.dart';
import '../../../widgets/skeleton.dart';
import '../../../widgets/weight_stepper.dart';

/// Shared form body for the New / Edit goal flows.
///
/// Hosts:
/// - direction segmented control (lose / maintain / gain)
/// - rate slider (kg/week), disabled when direction == maintain
/// - preview block that renders the resulting daily kcal target
/// - a single primary `Save` button
///
/// All state lives on the parent (which owns the save side-effect); this
/// widget is purely visual.
class GoalEditorBody extends StatelessWidget {
  const GoalEditorBody({
    required this.direction,
    required this.rateKgPerWeek,
    required this.previewKcal,
    required this.onDirectionChange,
    required this.onRateChange,
    required this.saveLabel,
    required this.onSave,
    this.targetWeightKg,
    this.onTargetWeightChange,
    super.key,
  });

  final GoalDirection direction;

  /// Unsigned kg/week. Direction encodes the sign.
  final Decimal rateKgPerWeek;

  /// Canonical target weight in kg. Null hides the section entirely
  /// (the parent passes null on `maintain`, where no target makes
  /// sense — "hold steady" is the target by definition).
  final Decimal? targetWeightKg;

  /// Required when [targetWeightKg] is non-null. The stepper emits the
  /// canonical kg on every commit; the parent owns the state.
  final ValueChanged<Decimal>? onTargetWeightChange;

  /// Pre-computed daily kcal target, ready to display via formatKcal.
  ///
  /// `null` signals "loading" — the preview renders a [Skeleton] in place
  /// of the kcal hero. This is the state the edit sheet uses while
  /// `meProvider` is in flight (T-010): the form chrome (direction +
  /// rate) remains interactive while the profile-dependent target loads.
  final int? previewKcal;

  final ValueChanged<GoalDirection> onDirectionChange;
  final ValueChanged<Decimal> onRateChange;

  final String saveLabel;

  /// Null disables the save button (e.g. while a request is in flight).
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const _SectionLabel(text: 'Direction'),
        SizedBox(height: tokens.space.x2),
        _DirectionSegmented(
          value: direction,
          onChanged: onDirectionChange,
        ),
        if (targetWeightKg != null && onTargetWeightChange != null) ...<Widget>[
          SizedBox(height: tokens.space.x5),
          const _SectionLabel(text: 'Target weight'),
          SizedBox(height: tokens.space.x2),
          WeightStepper(
            key: const ValueKey('goals.target_weight'),
            value: targetWeightKg!,
            onChanged: onTargetWeightChange!,
            semanticsLabel: 'Target weight',
          ),
        ],
        SizedBox(height: tokens.space.x5),
        const _SectionLabel(text: 'Weekly rate'),
        SizedBox(height: tokens.space.x2),
        _RateSlider(
          value: rateKgPerWeek,
          enabled: direction != GoalDirection.maintain,
          onChanged: onRateChange,
        ),
        SizedBox(height: tokens.space.x5),
        _PreviewBlock(kcal: previewKcal, direction: direction),
        SizedBox(height: tokens.space.x6),
        SizedBox(
          height: 48,
          child: ElevatedButton(
            key: const ValueKey('goals.save'),
            onPressed: onSave,
            style: ElevatedButton.styleFrom(
              backgroundColor: context.colors.accent,
              foregroundColor: context.colors.surface,
              disabledBackgroundColor: context.colors.accent.withAlpha(120),
              disabledForegroundColor: context.colors.surface,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(tokens.radius.r2),
              ),
              textStyle: context.text.bodyStrong.copyWith(
                color: context.colors.surface,
              ),
            ),
            child: Text(saveLabel),
          ),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: context.text.eyebrow.copyWith(color: context.colors.ink2),
    );
  }
}

class _DirectionSegmented extends StatelessWidget {
  const _DirectionSegmented({required this.value, required this.onChanged});
  final GoalDirection value;
  final ValueChanged<GoalDirection> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<GoalDirection>(
      segments: const <ButtonSegment<GoalDirection>>[
        ButtonSegment<GoalDirection>(
          value: GoalDirection.lose,
          label: Text('Lose'),
          icon: Icon(Icons.arrow_downward_rounded, size: 16),
        ),
        ButtonSegment<GoalDirection>(
          value: GoalDirection.maintain,
          label: Text('Maintain'),
          icon: Icon(Icons.horizontal_rule_rounded, size: 16),
        ),
        ButtonSegment<GoalDirection>(
          value: GoalDirection.gain,
          label: Text('Gain'),
          icon: Icon(Icons.arrow_upward_rounded, size: 16),
        ),
      ],
      selected: <GoalDirection>{value},
      showSelectedIcon: false,
      onSelectionChanged: (s) => onChanged(s.first),
    );
  }
}

class _RateSlider extends ConsumerWidget {
  const _RateSlider({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  /// Canonical kg/week, **always**. The slider converts in/out of the
  /// active display unit so the parent's math (and the wire) stay in
  /// kg regardless of what the user sees.
  final Decimal value;
  final bool enabled;
  final ValueChanged<Decimal> onChanged;

  /// Display caps per unit. kg uses the original 0–1.0 kg/wk range
  /// (20 × 0.05 steps); lb and st both render in lb/wk at 0–2.0
  /// (20 × 0.1 steps, ~equivalent granularity). st users see lb here
  /// because weekly weight-change rates in stones are too coarse to
  /// be useful — bathroom-scale convention matches lb.
  static const double _kgMax = 1.0;
  static const double _lbMax = 2.0;
  static const int _divisions = 20;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = context.tokens;
    final unit = ref.watch(weightUnitProvider);
    // st collapses to lb for display — see `_lbMax` doc.
    final displayUnit =
        unit == WeightUnit.kg ? WeightUnit.kg : WeightUnit.lb;
    final maxInUnit =
        displayUnit == WeightUnit.kg ? _kgMax : _lbMax;
    final unitSuffix = displayUnit.shortLabel;

    // Convert canonical kg → display unit.
    final displayValue = displayUnit == WeightUnit.kg
        ? value
        : (value * Decimal.parse('2.2046226218'));
    final asDouble = displayValue.toDouble().clamp(0.0, maxInUnit);

    final rateLabel = formatRate(displayValue);
    final label = enabled
        ? '$rateLabel $unitSuffix / week'
        : 'No weekly change';
    final maxLabel = displayUnit == WeightUnit.kg
        ? '1.0 kg/wk'
        : '2.0 lb/wk';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          label,
          style: context.text.bodyStrong.copyWith(
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
        SizedBox(height: tokens.space.x1),
        Slider(
          key: const ValueKey('goals.rate_slider'),
          min: 0.0,
          max: maxInUnit,
          divisions: _divisions,
          value: asDouble,
          activeColor: context.colors.accent,
          inactiveColor: context.colors.line,
          label: '$rateLabel $unitSuffix/wk',
          onChanged: enabled
              ? (v) {
                  // Emit canonical kg. For kg we round to 2 decimal
                  // places to match the legacy precision; for lb we
                  // round the typed value to 1 decimal place first
                  // (matches the slider step), then convert via the
                  // public `parseWeightToKg` so the conversion stays
                  // in the single seam.
                  if (displayUnit == WeightUnit.kg) {
                    onChanged(Decimal.parse(v.toStringAsFixed(2)));
                  } else {
                    final lbRounded = v.toStringAsFixed(1);
                    onChanged(parseWeightToKg(lbRounded, WeightUnit.lb));
                  }
                }
              : null,
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Text(
              '0',
              style: context.text.meta.copyWith(color: context.colors.ink3),
            ),
            Text(
              maxLabel,
              style: context.text.meta.copyWith(color: context.colors.ink3),
            ),
          ],
        ),
      ],
    );
  }
}

class _PreviewBlock extends StatelessWidget {
  const _PreviewBlock({required this.kcal, required this.direction});

  /// `null` → loading state (renders a [Skeleton] sized to match the
  /// kcal hero so the card height stays stable when the number arrives).
  final int? kcal;
  final GoalDirection direction;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tokens = context.tokens;
    final heroStyle =
        context.text.heroNumeric.copyWith(color: colors.ink);
    // Hero font size is the load-bearing dimension for the skeleton's
    // height; fall back to the style's default if unset (defensive — the
    // theme provides one today).
    final heroHeight = heroStyle.fontSize ?? 28.0;
    return Container(
      key: const ValueKey('goals.preview_kcal'),
      padding: EdgeInsets.all(tokens.space.x4),
      decoration: BoxDecoration(
        color: colors.accentSoft,
        borderRadius: BorderRadius.circular(tokens.radius.r2),
        border: Border.all(color: colors.accentLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'WILL TARGET',
            style: context.text.eyebrow.copyWith(color: colors.accent),
          ),
          SizedBox(height: tokens.space.x05 + tokens.space.x1),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              if (kcal == null)
                // T-08 loading affordance — the kcal value depends on
                // `meProvider`; render a skeleton of the same height as
                // the hero number so the card doesn't jump when the
                // profile resolves. T-010 wires this state.
                Skeleton(
                  key: const ValueKey('goals.preview_kcal_skeleton'),
                  height: heroHeight,
                  width: 96,
                  borderRadius:
                      BorderRadius.circular(tokens.radius.r1),
                )
              else
                // T-20: the kcal number announces with its unit
                // ("2,300 kilocalories"). The visible " kcal / day"
                // caption stays for sighted users; the `NumberText`
                // semantic label is what the screen reader hears for the
                // digit block.
                NumberText(
                  value: formatKcal(Decimal.fromInt(kcal!)),
                  unit: 'kilocalories',
                  style: heroStyle,
                ),
              SizedBox(width: tokens.space.x2),
              Text(
                'kcal / day',
                style: context.text.meta.copyWith(color: colors.ink2),
              ),
            ],
          ),
          SizedBox(height: tokens.space.x1),
          Text(
            _captionFor(direction),
            style: context.text.meta.copyWith(color: colors.ink2),
          ),
        ],
      ),
    );
  }

  static String _captionFor(GoalDirection d) {
    switch (d) {
      case GoalDirection.lose:
        return 'Estimated daily intake for this weekly loss rate.';
      case GoalDirection.gain:
        return 'Estimated daily intake for this weekly gain rate.';
      case GoalDirection.maintain:
        return 'Estimated daily intake to hold steady.';
    }
  }
}
