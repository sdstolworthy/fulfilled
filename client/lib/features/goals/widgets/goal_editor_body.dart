import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../../../domain/enums.dart';
import '../../../domain/units/energy.dart';
import '../../../theme/context_extensions.dart';

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
  final int previewKcal;

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
    final label = enabled
        ? '${asDouble.toStringAsFixed(2)} kg / week'
        : 'No weekly change';

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
          label: '${asDouble.toStringAsFixed(2)} kg/wk',
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
  final int kcal;
  final GoalDirection direction;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tokens = context.tokens;
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
              Text(
                formatKcal(Decimal.fromInt(kcal)),
                style: context.text.heroNumeric.copyWith(color: colors.ink),
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
