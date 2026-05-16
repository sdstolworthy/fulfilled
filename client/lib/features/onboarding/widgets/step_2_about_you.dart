import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../domain/drafts.dart';
import '../../../domain/enums.dart';
import '../../../domain/units/weight.dart';
import '../../../providers/draft_providers.dart';
import '../../../theme/context_extensions.dart';
import 'activity_option.dart';
import 'segmented_select.dart';

/// "About you" step (2 of 3). Sex segmented control, birth-date picker,
/// height + weight 2-col, activity-level option list. Every field
/// mutates the `onboardingDraftProvider` notifier directly so the screen
/// root re-reads the draft for navigation decisions without prop-drilling.
///
/// T-17: height and weight are `Decimal` end-to-end. The visible string
/// goes through the units helpers (`formatWeightKg` for weight; we mirror
/// for height since no `formatHeightCm` exists yet — flagged inline).
///
/// T-02: the steppers and the visible cm/kg numbers use tabular figures
/// via `bodyNumeric` so a single-tap up/down doesn't jitter horizontally.
class Step2AboutYou extends ConsumerWidget {
  const Step2AboutYou({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(onboardingDraftProvider);
    final notifier = ref.read(onboardingDraftProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _FieldLabel('Sex'),
        SizedBox(height: context.space.x2),
        SegmentedSelect<Sex>(
          options: const <Sex>[Sex.male, Sex.female, Sex.other],
          labelBuilder: _sexLabel,
          selected: draft.sex,
          onChanged: notifier.setSex,
        ),
        SizedBox(height: context.space.x3),
        _FieldLabel('Birth date'),
        SizedBox(height: context.space.x2),
        _BirthDateField(
          value: draft.birthDate,
          onChanged: notifier.setBirthDate,
        ),
        SizedBox(height: context.space.x3),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _FieldLabel('Height'),
                  SizedBox(height: context.space.x2),
                  _NumberStepper(
                    valueLabel: _formatHeightCm(draft.heightCm),
                    onIncrement: () => notifier.setHeightCm(
                      _stepDecimal(draft.heightCm, _d('1'), min: _d('80')),
                    ),
                    onDecrement: () => notifier.setHeightCm(
                      _stepDecimal(draft.heightCm, _d('-1'), min: _d('80')),
                    ),
                    semanticsLabel:
                        'Height ${_formatHeightCm(draft.heightCm)}',
                  ),
                ],
              ),
            ),
            SizedBox(width: context.space.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _FieldLabel('Weight'),
                  SizedBox(height: context.space.x2),
                  _NumberStepper(
                    valueLabel: _formatWeightKgLabel(draft.currentWeightKg),
                    onIncrement: () => notifier.setCurrentWeightKg(
                      _stepDecimal(draft.currentWeightKg, _d('0.5'),
                          min: _d('30')),
                    ),
                    onDecrement: () => notifier.setCurrentWeightKg(
                      _stepDecimal(draft.currentWeightKg, _d('-0.5'),
                          min: _d('30')),
                    ),
                    semanticsLabel:
                        'Weight ${_formatWeightKgLabel(draft.currentWeightKg)}',
                  ),
                ],
              ),
            ),
          ],
        ),
        SizedBox(height: context.space.x4),
        _FieldLabel('Activity level'),
        SizedBox(height: context.space.x2),
        _ActivityList(
          selected: draft.activityLevel,
          onSelect: notifier.setActivityLevel,
        ),
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: context.text.eyebrow.copyWith(color: context.colors.ink3),
    );
  }
}

class _BirthDateField extends StatelessWidget {
  const _BirthDateField({required this.value, required this.onChanged});

  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;

  @override
  Widget build(BuildContext context) {
    final label = value == null
        ? 'Choose date'
        : DateFormat('MMM d, yyyy').format(value!);
    return InkWell(
      onTap: () async {
        final now = DateTime.now();
        final initial = value ?? DateTime(now.year - 30, now.month, now.day);
        final picked = await showDatePicker(
          context: context,
          initialDate: initial,
          firstDate: DateTime(now.year - 100),
          lastDate: DateTime(now.year - 10, now.month, now.day),
        );
        if (picked != null) onChanged(picked);
      },
      borderRadius: BorderRadius.circular(context.radius.r2),
      child: Container(
        height: 48,
        padding: EdgeInsets.symmetric(horizontal: context.space.x3 + 2),
        decoration: BoxDecoration(
          color: context.colors.surface,
          borderRadius: BorderRadius.circular(context.radius.r2),
          border: Border.all(color: context.colors.line),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                label,
                style: context.text.bodyStrong.copyWith(
                  color: value == null
                      ? context.colors.ink3
                      : context.colors.ink,
                ),
              ),
            ),
            Icon(
              Icons.calendar_today_outlined,
              size: 18,
              color: context.colors.ink2,
            ),
          ],
        ),
      ),
    );
  }
}

class _NumberStepper extends StatelessWidget {
  const _NumberStepper({
    required this.valueLabel,
    required this.onIncrement,
    required this.onDecrement,
    required this.semanticsLabel,
  });

  final String valueLabel;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticsLabel,
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: context.colors.surface,
          borderRadius: BorderRadius.circular(context.radius.r2),
          border: Border.all(color: context.colors.line),
        ),
        child: Row(
          children: <Widget>[
            _StepperButton(
              icon: Icons.remove_rounded,
              onTap: onDecrement,
              tooltip: 'Decrease',
            ),
            Expanded(
              child: Center(
                child: Text(
                  valueLabel,
                  style: context.text.bodyStrongNumeric,
                ),
              ),
            ),
            _StepperButton(
              icon: Icons.add_rounded,
              onTap: onIncrement,
              tooltip: 'Increase',
            ),
          ],
        ),
      ),
    );
  }
}

class _StepperButton extends StatelessWidget {
  const _StepperButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(context.radius.r2),
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, size: 18, color: context.colors.ink2),
        ),
      ),
    );
  }
}

class _ActivityList extends StatelessWidget {
  const _ActivityList({required this.selected, required this.onSelect});

  final ActivityLevel? selected;
  final ValueChanged<ActivityLevel> onSelect;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ActivityOption(
          title: 'Sedentary',
          subtitle: 'Mostly sitting, little exercise',
          selected: selected == ActivityLevel.sedentary,
          onTap: () => onSelect(ActivityLevel.sedentary),
        ),
        SizedBox(height: context.space.x2),
        ActivityOption(
          title: 'Lightly active',
          subtitle: 'Walks, 1–2 workouts / week',
          selected: selected == ActivityLevel.light,
          onTap: () => onSelect(ActivityLevel.light),
        ),
        SizedBox(height: context.space.x2),
        ActivityOption(
          title: 'Moderately active',
          subtitle: '3–5 workouts / week',
          selected: selected == ActivityLevel.moderate,
          onTap: () => onSelect(ActivityLevel.moderate),
        ),
        SizedBox(height: context.space.x2),
        ActivityOption(
          title: 'Very active',
          subtitle: '6+ workouts or physical job',
          selected: selected == ActivityLevel.active ||
              selected == ActivityLevel.veryActive,
          // Mock collapses the top band into "Very active"; the model has
          // both `active` and `veryActive`. Map the tile to `veryActive` —
          // a follow-up may split them when the design adds a 5th row.
          onTap: () => onSelect(ActivityLevel.veryActive),
        ),
      ],
    );
  }
}

// ─── helpers ──────────────────────────────────────────────────────────────

String _sexLabel(Sex sex) {
  switch (sex) {
    case Sex.male:
      return 'Male';
    case Sex.female:
      return 'Female';
    case Sex.other:
      return 'Other';
  }
}

Decimal _d(String s) => Decimal.parse(s);

/// Step a nullable Decimal by [step] (signed); clamp at [min]. Initial
/// values when null fall back to a sensible default per field — caller
/// passes the right `min` so we land in range.
Decimal _stepDecimal(Decimal? current, Decimal step, {required Decimal min}) {
  // No prefill: jump to a reasonable default (server'll be patched on submit).
  final base = current ?? (min + _d('90'));
  final next = base + step;
  return next < min ? min : next;
}

/// Format a height as `"182 cm"`. Lives here for now; flagged to lift into
/// `lib/domain/units/length.dart` when v2 introduces imperial.
String _formatHeightCm(Decimal? value) {
  if (value == null) return '— cm';
  final rounded = value.round(scale: 0).toBigInt().toInt();
  return '$rounded cm';
}

/// Format a weight as `"80.2 kg"` — reuses the foundation `formatWeightKg`
/// so the kg formatter behaviour stays single-sourced (T-21).
String _formatWeightKgLabel(Decimal? value) {
  if (value == null) return '— kg';
  return '${formatWeightKg(value)} kg';
}
