import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:fulfilled/widgets/activity_option.dart';
import 'package:fulfilled/widgets/height_stepper.dart';
import 'package:fulfilled/widgets/weight_stepper.dart';

import '../../../domain/enums.dart';
import '../../../providers/draft_providers.dart';
import '../../../theme/context_extensions.dart';
import 'segmented_select.dart';

/// "About you" step (2 of 3). Sex segmented control, birth-date picker,
/// height + weight 2-col, activity-level option list. Every field
/// mutates the `onboardingDraftProvider` notifier directly so the screen
/// root re-reads the draft for navigation decisions without prop-drilling.
///
/// T-17: height and weight are `Decimal` end-to-end. The QL-104 sweep
/// deleted the inline `_NumberStepper` + `_formatHeightCm` helper —
/// height now delegates display + stepping to the lifted
/// [HeightStepper] (QL-103) which renders cm OR ft+in based on
/// [onboardingHeightUnitProvider]. Weight delegates display + stepping
/// to the lifted [WeightStepper] (LU-007), which renders the active
/// unit's number + suffix from canonical kg.
///
/// QL-104: above the height + weight row sits a single `Units` label
/// with two stacked `SegmentedSelect`s — one for weight (kg/lb/st), one
/// for height (cm/ft·in). The picked units come from
/// [onboardingWeightUnitProvider] / [onboardingHeightUnitProvider] —
/// locale defaults on first build, user-chosen the moment a segment is
/// tapped. Both land on `UserPatch.weightUnit` / `UserPatch.heightUnit`
/// at final submit (onboarding_screen.dart). `OnboardingDraft.empty()`
/// returns null for both unit fields; the QL-107 "Start over"
/// affordance (covered later) resets to that state, which means the
/// locale default takes over until the user explicitly picks.
///
/// T-02: the steppers and the visible cm/kg numbers use tabular figures
/// via `bodyNumeric` so a single-tap up/down doesn't jitter horizontally.
class Step2AboutYou extends ConsumerWidget {
  const Step2AboutYou({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(onboardingDraftProvider);
    final notifier = ref.read(onboardingDraftProvider.notifier);
    final activeWeightUnit = ref.watch(onboardingWeightUnitProvider);
    final activeHeightUnit = ref.watch(onboardingHeightUnitProvider);

    // WeightStepper takes a non-nullable canonical kg. Seed an empty
    // draft with a sensible adult midpoint (70 kg). Tapping +/- in any
    // active unit then writes the canonical kg back through
    // `setCurrentWeightKg`, matching the height column's "tap to seed"
    // affordance.
    final weightSeedKg =
        draft.currentWeightKg ?? Decimal.parse('70');

    // HeightStepper also takes a non-nullable canonical cm; mirror
    // the weight seed pattern with the adult midpoint (170 cm). The
    // stepper writes the new canonical cm back through `setHeightCm`
    // on every commit.
    final heightSeedCm = draft.heightCm ?? Decimal.fromInt(170);

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
        _FieldLabel('Units'),
        SizedBox(height: context.space.x2),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _SubLabel('Weight'),
            SizedBox(height: context.space.x1),
            SegmentedSelect<WeightUnit>(
              key: const Key('onboarding-weight-unit-chooser'),
              options: const <WeightUnit>[
                WeightUnit.kg,
                WeightUnit.lb,
                WeightUnit.st,
              ],
              labelBuilder: _weightUnitLabel,
              selected: activeWeightUnit,
              onChanged: notifier.setWeightUnit,
            ),
            SizedBox(height: context.space.x2),
            _SubLabel('Height'),
            SizedBox(height: context.space.x1),
            SegmentedSelect<HeightUnit>(
              key: const Key('onboarding-height-unit-chooser'),
              options: const <HeightUnit>[
                HeightUnit.cm,
                HeightUnit.ftIn,
              ],
              labelBuilder: _heightUnitLabel,
              selected: activeHeightUnit,
              onChanged: notifier.setHeightUnit,
            ),
          ],
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
                  HeightStepper(
                    key: const Key('onboarding-height-stepper'),
                    value: heightSeedCm,
                    unitOverride: activeHeightUnit,
                    onChanged: notifier.setHeightCm,
                    semanticsLabel: 'Height',
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
                  WeightStepper(
                    key: const Key('onboarding-weight-stepper'),
                    value: weightSeedKg,
                    unitOverride: activeWeightUnit,
                    minKg: _d('30'),
                    onChanged: notifier.setCurrentWeightKg,
                    semanticsLabel: 'Weight',
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

/// Smaller-text variant of [_FieldLabel] — feature-private. The
/// architect (§5.9) ruled the joined Units label introduces sub-labels
/// for Weight / Height; this is the inline shape so the widget tree
/// doesn't sprout a new lifted primitive for two callers.
class _SubLabel extends StatelessWidget {
  const _SubLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: context.text.meta.copyWith(
        color: context.colors.ink2,
        fontWeight: FontWeight.w500,
      ),
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

/// Human label for the weight-unit segmented chooser. Renders the long
/// form (`"Kilograms (kg)"`) so the picker is self-explanatory the
/// first time a user sees it — the architect's call (§3.11).
String _weightUnitLabel(WeightUnit unit) {
  switch (unit) {
    case WeightUnit.kg:
      return 'Kilograms (kg)';
    case WeightUnit.lb:
      return 'Pounds (lb)';
    case WeightUnit.st:
      return 'Stones (st)';
  }
}

/// Human label for the height-unit segmented chooser. Renders the long
/// form (`"Centimeters (cm)"`) so the picker is self-explanatory the
/// first time a user sees it — architect §5.9 verbatim.
String _heightUnitLabel(HeightUnit unit) {
  switch (unit) {
    case HeightUnit.cm:
      return 'Centimeters (cm)';
    case HeightUnit.ftIn:
      return 'Feet & inches';
  }
}
