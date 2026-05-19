import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/calories/estimate.dart';
import '../../../domain/enums.dart';
import '../../../domain/goal.dart';
import '../../../domain/user.dart';
import '../../../form_factor/form_factor.dart';
import '../../../providers/goal_providers.dart';
import '../../../providers/profile_providers.dart';
import '../../../providers/repository_providers.dart';
import '../../../providers/weight_providers.dart';
import '../../../theme/context_extensions.dart';
import '../../../widgets/empty_state.dart';
import '../../../widgets/primary_button.dart';
import '../../profile/widgets/activity_level_picker.dart';
import '../../profile/widgets/birth_date_picker.dart';
import '../../profile/widgets/current_weight_sheet.dart';
import '../../profile/widgets/height_stepper_sheet.dart';
import '../../profile/widgets/sex_picker.dart';
import 'goal_editor_body.dart';

/// Opens the "Edit current goal" flow. Same T-14 split as
/// [openNewGoal] — full-screen route on compact, dialog on expanded.
///
/// The Save handler calls `GoalRepository.update(...)` which mutates
/// the active goal in place. It does *not* supersede the active row
/// (that's `create()`'s contract) — the user expects "edit goal" to
/// change the existing goal, not start a new one.
Future<void> openEditGoal(BuildContext context, {required Goal active}) async {
  final isCompact = FormFactor.of(context).isCompact;
  if (isCompact) {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => EditGoalScreen(active: active),
        fullscreenDialog: true,
      ),
    );
  } else {
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => EditGoalDialog(active: active),
    );
  }
}

class EditGoalScreen extends StatelessWidget {
  const EditGoalScreen({required this.active, super.key});
  final Goal active;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.bg,
      appBar: AppBar(
        backgroundColor: context.colors.bg,
        elevation: 0,
        leading: IconButton(
          tooltip: 'Cancel',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text('Edit goal', style: context.text.title),
        centerTitle: false,
      ),
      body: SafeArea(
        child: _EditGoalForm(active: active),
      ),
    );
  }
}

class EditGoalDialog extends StatelessWidget {
  const EditGoalDialog({required this.active, super.key});
  final Goal active;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Dialog(
      backgroundColor: context.colors.bg,
      insetPadding: EdgeInsets.symmetric(
        horizontal: tokens.space.x6,
        vertical: tokens.space.x6,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(tokens.radius.r4),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: EdgeInsets.all(tokens.space.x5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text('Edit goal', style: context.text.title),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
              SizedBox(height: tokens.space.x2),
              Flexible(child: _EditGoalForm(active: active)),
            ],
          ),
        ),
      ),
    );
  }
}

class _EditGoalForm extends ConsumerStatefulWidget {
  const _EditGoalForm({required this.active});
  final Goal active;

  @override
  ConsumerState<_EditGoalForm> createState() => _EditGoalFormState();
}

class _EditGoalFormState extends ConsumerState<_EditGoalForm> {
  late GoalDirection _direction;
  late Decimal _rate;
  Decimal? _targetWeightKg;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _direction = widget.active.direction;
    // `weeklyRateKg` is signed on the goal; the editor's slider works in
    // unsigned magnitude (direction encodes the sign). Take the absolute
    // value so a stored lose-rate of `-0.5` prefills the slider at `0.5`.
    final stored = widget.active.rateKgPerWeek ?? Decimal.zero;
    _rate = stored < Decimal.zero ? -stored : stored;
    _targetWeightKg = widget.active.targetWeightKg;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    // T-010: the editor now consumes `estimateCalories` (the same seam
    // onboarding uses) so a rate of "0.5 kg/week lose" produces the same
    // daily kcal the wizard would have computed for the same inputs.
    // Profile inputs are pulled from `meProvider`.
    final meAsync = ref.watch(meProvider);
    final currentKg = ref.watch(currentWeightKgProvider).valueOrNull;
    // Active weight unit drives the rate-slider scale on
    // [GoalEditorBody]. Resolved here per the §4.4 passive-view rule
    // so the leaf stays Riverpod-free.
    final unit = ref.watch(weightUnitProvider);

    return meAsync.when(
      loading: () => SingleChildScrollView(
        padding: EdgeInsets.symmetric(
          horizontal: tokens.space.x5,
          vertical: tokens.space.x4,
        ),
        // While the profile loads, render the editor with a `null` preview
        // so the rate slider / direction picker are interactive but the
        // kcal target shows a [Skeleton] (T-08). The Save button stays
        // disabled — we can't compute the target without the profile.
        child: GoalEditorBody(
          direction: _direction,
          rateKgPerWeek: _rate,
          previewKcal: null,
          unit: unit,
          targetWeightKg: _targetWeightForSection(currentKg: null),
          onTargetWeightChange: (v) => setState(() => _targetWeightKg = v),
          onDirectionChange: (d) => setState(() => _direction = d),
          onRateChange: (r) => setState(() => _rate = r),
          saveLabel: 'Save changes',
          onSave: null,
        ),
      ),
      error: (err, _) => _ProfileError(
        message: err.toString(),
        onRetry: () => ref.invalidate(meProvider),
      ),
      data: (user) {
        // Profile-incomplete branch — see the new-goal sibling for
        // the rationale. The picker each row opens invalidates
        // `meProvider`; once the list is empty the editor returns.
        if (missingGoalPrereqFields(user, currentWeightKg: currentKg)
            .isNotEmpty) {
          return SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: tokens.space.x5,
              vertical: tokens.space.x4,
            ),
            child: GoalProfilePrereqs(
              user: user,
              currentKg: currentKg,
              onPickSex: () => showSexPicker(
                context,
                initial: user.sex,
                onSave: (picked) async {
                  await ref
                      .read(profileRepositoryProvider)
                      .update(UserPatch(sex: picked));
                  ref.invalidate(meProvider);
                },
              ),
              onPickBirthDate: () => showBirthDatePicker(
                context,
                ref,
                initial: user.birthDate,
              ),
              onPickHeight: () => showHeightStepperSheet(
                context,
                initial: user.heightCm,
              ),
              // See the new-goal sibling for why `initial` is null
              // on the current-weight picker — the sheet derives its
              // seed from the weight feed, not from the user record.
              onPickWeight: () =>
                  showCurrentWeightSheet(context, initial: null),
              onPickActivity: () => showActivityLevelPicker(
                context,
                initial: user.activityLevel,
                onSave: (picked) async {
                  await ref
                      .read(profileRepositoryProvider)
                      .update(UserPatch(activityLevel: picked));
                  ref.invalidate(meProvider);
                },
              ),
            ),
          );
        }
        final estimate = _estimateFor(user, currentKg);

        return SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: tokens.space.x5,
            vertical: tokens.space.x4,
          ),
          child: GoalEditorBody(
            direction: _direction,
            rateKgPerWeek: _rate,
            previewKcal: estimate?.dailyTargetKcal,
            unit: unit,
            targetWeightKg: _targetWeightForSection(currentKg: currentKg),
            onTargetWeightChange: (v) => setState(() => _targetWeightKg = v),
            onDirectionChange: (d) => setState(() => _direction = d),
            onRateChange: (r) => setState(() => _rate = r),
            saveLabel: _saving ? 'Saving…' : 'Save changes',
            onSave: (_saving || estimate == null) ? null : () => _save(estimate),
          ),
        );
      },
    );
  }

  /// Mirrors `_NewGoalFormState._targetWeightForSection`. Maintain
  /// hides the input; lose / gain seed from the user's edits, the
  /// active goal's stored value, or the current weight as a last
  /// resort. See the new-goal sibling for the rationale.
  Decimal? _targetWeightForSection({required Decimal? currentKg}) {
    if (_direction == GoalDirection.maintain) return null;
    return _targetWeightKg ?? widget.active.targetWeightKg ?? currentKg;
  }

  /// Build the [CalorieEstimate] for the current form state + user
  /// profile. Returns `null` when the profile is missing a required
  /// field, matching [estimateCalories]'s contract.
  CalorieEstimate? _estimateFor(User user, Decimal? currentKg) {
    return estimateCalories(
      sex: user.sex,
      birthDate: user.birthDate,
      heightCm: user.heightCm,
      weightKg: currentKg,
      activityLevel: user.activityLevel,
      direction: _direction,
      rateKgPerWeek: _rate,
    );
  }

  Future<void> _save(CalorieEstimate estimate) async {
    setState(() => _saving = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final repo = ref.read(goalRepositoryProvider);
      final signedRate = _signedRate(_direction, _rate);

      // In-place edit. Preserve every field except the user's edits
      // (direction-derived signed rate, the recomputed kcal target via
      // `estimateCalories`, and the macro split that follows from it).
      // `update()` stamps `updatedAt` and preserves `createdAt`.
      //
      // Macros come straight off the same `CalorieEstimate` so the split
      // matches onboarding's. They round to integer grams (half-to-even)
      // inside [estimateCalories]; we coerce to `Decimal` for the wire.
      final Decimal? targetForWire = _direction == GoalDirection.maintain
          ? null
          : _targetWeightKg;

      await repo.update(
        widget.active.copyWith(
          weeklyRateKg: signedRate,
          dailyCalorieTarget: estimate.dailyTargetKcal,
          targetWeightKg: targetForWire,
          proteinTargetG: Decimal.fromInt(estimate.proteinG),
          carbsTargetG: Decimal.fromInt(estimate.carbsG),
          fatTargetG: Decimal.fromInt(estimate.fatG),
        ),
      );
      // See the new-goal sibling for why `daySummaryProvider` is
      // intentionally not invalidated here.
      ref.invalidate(activeGoalProvider);
      ref.invalidate(goalsProvider);
      if (mounted) unawaited(navigator.maybePop());
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        messenger?.showSnackBar(
          SnackBar(content: Text('Couldn\'t save changes: $e')),
        );
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Encode direction as the sign on the `weeklyRateKg` field — the wire
/// representation that `Goal.copyWith` expects.
Decimal _signedRate(GoalDirection d, Decimal magnitude) {
  switch (d) {
    case GoalDirection.lose:
      return -magnitude;
    case GoalDirection.gain:
      return magnitude;
    case GoalDirection.maintain:
      return Decimal.zero;
  }
}

/// Inline error surface when `meProvider` fails. Mirrors the Profile
/// screen's `_ProfileError` — same copy, same Retry affordance — so the
/// editor's failure-mode language matches the rest of the app.
class _ProfileError extends StatelessWidget {
  const _ProfileError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: EmptyState(
        icon: Icons.cloud_off,
        title: "Couldn't load profile",
        body: 'We need your sex, age, height, weight, and activity level '
            'to recompute your kcal target. Tap retry.',
        action: SizedBox(
          width: 200,
          child: PrimaryButton(
            key: const ValueKey('goals.edit.retry_profile'),
            label: 'Retry',
            onPressed: onRetry,
          ),
        ),
      ),
    );
  }
}
