import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/enums.dart';
import '../../../domain/goal.dart';
import '../../../form_factor/form_factor.dart';
import '../../../providers/goal_providers.dart';
import '../../../providers/log_providers.dart';
import '../../../providers/repository_providers.dart';
import '../../../theme/context_extensions.dart';
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
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _direction = widget.active.direction;
    _rate = widget.active.rateKgPerWeek ?? Decimal.zero;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final baseline = _baselineKcalFromGoal(widget.active);
    final previewKcal = _derivedKcalTarget(
      baselineKcal: baseline,
      direction: _direction,
      rateKgPerWeek: _rate,
    );

    return SingleChildScrollView(
      padding: EdgeInsets.symmetric(
        horizontal: tokens.space.x5,
        vertical: tokens.space.x4,
      ),
      child: GoalEditorBody(
        direction: _direction,
        rateKgPerWeek: _rate,
        previewKcal: previewKcal,
        onDirectionChange: (d) => setState(() => _direction = d),
        onRateChange: (r) => setState(() => _rate = r),
        saveLabel: _saving ? 'Saving…' : 'Save changes',
        onSave: _saving ? null : _save,
      ),
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final repo = ref.read(goalRepositoryProvider);
      final baseline = _baselineKcalFromGoal(widget.active);
      final preview = _derivedKcalTarget(
        baselineKcal: baseline,
        direction: _direction,
        rateKgPerWeek: _rate,
      );
      final today = DateTime.now();
      final startsOn = DateTime(today.year, today.month, today.day);
      final signedRate = _signedRate(_direction, _rate);

      // In-place edit. Preserve every field except the user's edits
      // (direction-derived signed rate, the recomputed kcal target, and
      // the macro split that follows from it). `update()` stamps
      // `updatedAt` and preserves `createdAt`.
      //
      // TODO(arch): rewire to estimateCalories once meProvider is
      // threaded through. See dev_tickets.md T-010.
      await repo.update(
        widget.active.copyWith(
          weeklyRateKg: signedRate,
          dailyCalorieTarget: preview,
          proteinTargetG: _macroGrams(preview, share: 0.25, kcalPerG: 4),
          carbsTargetG: _macroGrams(preview, share: 0.50, kcalPerG: 4),
          fatTargetG: _macroGrams(preview, share: 0.25, kcalPerG: 9),
        ),
      );
      ref.invalidate(activeGoalProvider);
      ref.invalidate(goalsProvider);
      ref.invalidate(daySummaryProvider(startsOn));
      if (mounted) navigator.maybePop();
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
// Shared math — kept identical to new_goal_dialog's helpers. Kept inline
// here too rather than re-exporting from new_goal_dialog because both
// files own a single mutation point that mirrors the same formula; if
// the foundation pass lifts this into `domain/calories`, both call sites
// flip together.
// ---------------------------------------------------------------------------

const int _kKcalPerKgWeekPerDay = 1100;

int _baselineKcalFromGoal(Goal g) {
  final current = g.dailyCalorieTarget ?? 2000;
  final rate = g.weeklyRateKg ?? Decimal.zero;
  final delta = (rate * Decimal.fromInt(_kKcalPerKgWeekPerDay))
      .round(scale: 0)
      .toBigInt()
      .toInt();
  return current - delta;
}

int _derivedKcalTarget({
  required int baselineKcal,
  required GoalDirection direction,
  required Decimal rateKgPerWeek,
}) {
  if (direction == GoalDirection.maintain) {
    return _round10(baselineKcal);
  }
  final perDay =
      (rateKgPerWeek * Decimal.fromInt(_kKcalPerKgWeekPerDay))
          .round(scale: 0)
          .toBigInt()
          .toInt();
  final raw = direction == GoalDirection.lose
      ? baselineKcal - perDay
      : baselineKcal + perDay;
  final clamped = raw < 1200 ? 1200 : raw;
  return _round10(clamped);
}

int _round10(int v) => (v / 10).round() * 10;

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

Decimal _macroGrams(int kcal, {required double share, required int kcalPerG}) {
  final shareDec = Decimal.parse(share.toString());
  final perG = Decimal.fromInt(kcalPerG);
  final kcalDec = Decimal.fromInt(kcal);
  final grams =
      (kcalDec * shareDec / perG).toDecimal(scaleOnInfinitePrecision: 2);
  return grams.round(scale: 0);
}
