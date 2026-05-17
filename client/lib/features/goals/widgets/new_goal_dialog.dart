import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/calories/estimate.dart';
import '../../../domain/enums.dart';
import '../../../domain/goal.dart';
import '../../../domain/user.dart';
import '../../../form_factor/form_factor.dart';
import '../../../providers/goal_providers.dart';
import '../../../providers/log_providers.dart';
import '../../../providers/profile_providers.dart';
import '../../../providers/repository_providers.dart';
import '../../../theme/context_extensions.dart';
import '../../../widgets/empty_state.dart';
import '../../../widgets/primary_button.dart';
import 'goal_editor_body.dart';

/// Opens the "New goal" flow per T-14:
///
/// - **compact**: full-screen route via `Navigator.push(MaterialPageRoute)`
///   — addressable in the navigator stack, browser-back-able, survives
///   reload through the navigator's restoration.
/// - **expanded**: modal dialog (`showDialog`) — quick interaction that
///   doesn't survive reload, which is the correct semantic for a "make
///   this thing real" editor sitting on top of the goals screen.
///
/// The router itself does not host a `goals.new` builder for this widget
/// (the route is reserved for the foundation pass / mobile deep links);
/// the dialog opens locally inside the shell.
Future<void> openNewGoal(BuildContext context, {Goal? template}) async {
  final isCompact = FormFactor.of(context).isCompact;
  if (isCompact) {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => NewGoalScreen(template: template),
        fullscreenDialog: true,
      ),
    );
  } else {
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => NewGoalDialog(template: template),
    );
  }
}

/// Full-screen variant for compact. Hosted by `MaterialPageRoute` so it
/// participates in the navigator stack and respects system back.
class NewGoalScreen extends StatelessWidget {
  const NewGoalScreen({this.template, super.key});

  /// Optional active-goal template — Edit Current pre-fills from this.
  /// For brand-new goals it's null and the editor uses sensible defaults.
  final Goal? template;

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
        title: Text('New goal', style: context.text.title),
        centerTitle: false,
      ),
      body: SafeArea(
        child: _NewGoalForm(template: template),
      ),
    );
  }
}

/// Dialog variant for expanded/medium.
class NewGoalDialog extends StatelessWidget {
  const NewGoalDialog({this.template, super.key});
  final Goal? template;

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
                    child: Text('New goal', style: context.text.title),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
              SizedBox(height: tokens.space.x2),
              Flexible(child: _NewGoalForm(template: template)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Form body — shared between full-screen and dialog hosts. Wraps the
/// reusable `GoalEditorBody` and handles the Save → repository call +
/// provider invalidation.
class _NewGoalForm extends ConsumerStatefulWidget {
  const _NewGoalForm({this.template});
  final Goal? template;

  @override
  ConsumerState<_NewGoalForm> createState() => _NewGoalFormState();
}

class _NewGoalFormState extends ConsumerState<_NewGoalForm> {
  late GoalDirection _direction;
  late Decimal _rate; // unsigned kg/week
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final t = widget.template;
    _direction = t?.direction ?? GoalDirection.lose;
    // `Goal.rateKgPerWeek` is signed (lose ⇒ negative); the editor's
    // slider speaks magnitude only. Take the absolute value so a stored
    // lose-rate of `-0.5` pre-fills the slider at `0.5`.
    final stored = t?.rateKgPerWeek ?? Decimal.parse('0.5');
    _rate = stored < Decimal.zero ? -stored : stored;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    // FX-003 (LU-010 follow-up): the new-goal flow now consumes
    // `estimateCalories` (the same Mifflin-St Jeor + macro-split seam
    // onboarding and the edit-goal sheet use) instead of the legacy
    // ±1100 kcal/(kg·week) shift around a 2000 kcal baseline. The
    // formula is identical to edit-goal's; only the seed inputs differ
    // (a brand-new goal starts at lose / 0.5 kg/wk).
    final meAsync = ref.watch(meProvider);

    return meAsync.when(
      loading: () => SingleChildScrollView(
        padding: EdgeInsets.symmetric(
          horizontal: tokens.space.x5,
          vertical: tokens.space.x4,
        ),
        // Profile-loading affordance: render the editor chrome with a
        // `null` preview so the rate slider / direction picker stay
        // interactive while the kcal hero shows a [Skeleton] (T-08).
        // Save is disabled — the target depends on the profile.
        child: GoalEditorBody(
          direction: _direction,
          rateKgPerWeek: _rate,
          previewKcal: null,
          onDirectionChange: (d) => setState(() => _direction = d),
          onRateChange: (r) => setState(() => _rate = r),
          saveLabel: _saving ? 'Saving…' : 'Save goal',
          onSave: null,
        ),
      ),
      error: (err, _) => _ProfileError(
        message: err.toString(),
        onRetry: () => ref.invalidate(meProvider),
      ),
      data: (user) {
        final estimate = _estimateFor(user);

        return SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: tokens.space.x5,
            vertical: tokens.space.x4,
          ),
          child: GoalEditorBody(
            direction: _direction,
            rateKgPerWeek: _rate,
            // A `null` estimate means the profile is loaded but missing
            // one or more required fields (sex / birthDate / heightCm /
            // currentWeightKg / activityLevel). Render the skeleton and
            // disable save — the user has to complete their profile first.
            previewKcal: estimate?.dailyTargetKcal,
            onDirectionChange: (d) => setState(() => _direction = d),
            onRateChange: (r) => setState(() => _rate = r),
            saveLabel: _saving ? 'Saving…' : 'Save goal',
            onSave: (_saving || estimate == null) ? null : () => _save(estimate),
          ),
        );
      },
    );
  }

  /// Build the [CalorieEstimate] for the current form state + user
  /// profile. Returns `null` when the profile is missing a required
  /// field, matching [estimateCalories]'s contract.
  CalorieEstimate? _estimateFor(User user) {
    return estimateCalories(
      sex: user.sex,
      birthDate: user.birthDate,
      heightCm: user.heightCm,
      weightKg: user.currentWeightKg,
      activityLevel: user.activityLevel,
      direction: _direction,
      rateKgPerWeek: _rate,
    );
  }

  /// T-24 Case 1 — pop-to-source.
  ///
  /// `/goals` is the source — the user opened New goal from the Goals
  /// screen and wants the just-saved goal to render in the active card
  /// + history list underneath. `navigator.maybePop()` drops the route
  /// (compact) or dialog (expanded); `activeGoalProvider` /
  /// `goalsProvider` invalidation drives the parent re-read (T-18).
  Future<void> _save(CalorieEstimate estimate) async {
    setState(() => _saving = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final repo = ref.read(goalRepositoryProvider);
      final today = DateTime.now();
      final startsOn = DateTime(today.year, today.month, today.day);
      final signedRate = _signedRate(_direction, _rate);

      // Macros come straight off the same `CalorieEstimate` so the
      // split (P 25% / C 50% / F 25% on energy) matches onboarding and
      // the edit-goal sheet. `estimateCalories` rounds to integer grams
      // half-to-even; we coerce to `Decimal` for the wire.
      await repo.create(
        GoalCreate(
          startsOn: startsOn,
          weeklyRateKg: signedRate,
          dailyCalorieTarget: estimate.dailyTargetKcal,
          startWeightKg: widget.template?.startWeightKg,
          targetWeightKg: widget.template?.targetWeightKg,
          proteinTargetG: Decimal.fromInt(estimate.proteinG),
          carbsTargetG: Decimal.fromInt(estimate.carbsG),
          fatTargetG: Decimal.fromInt(estimate.fatG),
        ),
      );
      // T-18: invalidate only what changed.
      ref.invalidate(activeGoalProvider);
      ref.invalidate(goalsProvider);
      ref.invalidate(daySummaryProvider(startsOn));
      if (mounted) navigator.maybePop();
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        messenger?.showSnackBar(
          SnackBar(content: Text('Couldn\'t save goal: $e')),
        );
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Encode direction as the sign on the `weeklyRateKg` field — the wire
/// representation that `GoalCreate` expects.
///
/// Kept file-private (mirrors the same helper in `edit_goal_sheet.dart`).
/// The two helpers stay duplicated rather than extracted because both
/// files are short and the seam is one line; promoting it would invent
/// a goals-internal utility module for negligible savings.
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

/// Inline error surface when `meProvider` fails. Mirrors the edit-goal
/// sheet's `_ProfileError` — same copy, same Retry affordance — so the
/// editor's failure-mode language matches across new / edit flows.
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
            'to compute your kcal target. Tap retry.',
        action: SizedBox(
          width: 200,
          child: PrimaryButton(
            key: const ValueKey('goals.new.retry_profile'),
            label: 'Retry',
            onPressed: onRetry,
          ),
        ),
      ),
    );
  }
}
