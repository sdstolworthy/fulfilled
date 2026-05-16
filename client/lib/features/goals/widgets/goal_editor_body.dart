import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../../../domain/decimal_format.dart';
import '../../../domain/enums.dart';
import '../../../domain/units/energy.dart';
import '../../../theme/context_extensions.dart';
import '../../../widgets/number_text.dart';
import '../../../widgets/skeleton.dart';

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
    super.key,
  });

  final GoalDirection direction;

  /// Unsigned kg/week. Direction encodes the sign.
  final Decimal rateKgPerWeek;

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
        _SectionLabel(text: 'Direction'),
        SizedBox(height: tokens.space.x2),
        _DirectionSegmented(
          value: direction,
          onChanged: onDirectionChange,
        ),
        SizedBox(height: tokens.space.x5),
        _SectionLabel(text: 'Weekly rate'),
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

class _RateSlider extends StatelessWidget {
  const _RateSlider({
    required this.value,
    required this.enabled,
    required this.onChanged,
  });
  final Decimal value;
  final bool enabled;
  final ValueChanged<Decimal> onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final asDouble = value.toDouble().clamp(0.0, 1.0);
    // Rate display: two fraction digits, half-to-even — PM §10 #9 via
    // `formatRate`. The slider's underlying value is a `Decimal` so we
    // route through the helper rather than `double.toStringAsFixed` (which
    // rounds half-away-from-zero and disagrees with the rest of the app).
    final rateLabel = formatRate(value);
    final label = enabled ? '$rateLabel kg / week' : 'No weekly change';

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
          max: 1.0,
          divisions: 20,
          value: asDouble,
          activeColor: context.colors.accent,
          inactiveColor: context.colors.line,
          label: '$rateLabel kg/wk',
          onChanged: enabled
              ? (v) => onChanged(
                    Decimal.parse(v.toStringAsFixed(2)),
                  )
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
              '1.0 kg/wk',
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
