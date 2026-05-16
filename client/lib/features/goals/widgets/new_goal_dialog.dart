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
    final initial = t?.rateKgPerWeek ?? Decimal.parse('0.5');
    _rate = initial;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    // Derive the previewed kcal from the existing active goal (the
    // "template") if available, treating its kcal-target as a snapshot
    // and shifting it by the rate delta at ~1100 kcal/(kg·day). When
    // there's no template (first goal), fall back to a 2000 kcal
    // maintenance baseline — the day-screen / weight screen still work
    // because the new row gets `dailyCalorieTarget`.
    final baseline = _baselineKcal(widget.template);
    final previewKcal = _derivedKcalTarget(
      baselineKcal: baseline.maintenance,
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
        saveLabel: _saving ? 'Saving…' : 'Save goal',
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
      final signedRate = _signedRate(_direction, _rate);
      final today = DateTime.now();
      final startsOn = DateTime(today.year, today.month, today.day);
      final preview = _derivedKcalTarget(
        baselineKcal: _baselineKcal(widget.template).maintenance,
        direction: _direction,
        rateKgPerWeek: _rate,
      );
      await repo.create(
        GoalCreate(
          startsOn: startsOn,
          weeklyRateKg: signedRate,
          dailyCalorieTarget: preview,
          startWeightKg: widget.template?.startWeightKg,
          targetWeightKg: widget.template?.targetWeightKg,
          // Macro grams default — proportional to the new kcal at the
          // 25/50/25 split used by the active card. Repository takes
          // them verbatim.
          proteinTargetG: _macroGrams(preview, share: 0.25, kcalPerG: 4),
          carbsTargetG: _macroGrams(preview, share: 0.50, kcalPerG: 4),
          fatTargetG: _macroGrams(preview, share: 0.25, kcalPerG: 9),
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

/// Shared default-maintenance kcal when there's no active template.
const int _kDefaultMaintenanceKcal = 2000;

/// Slope of the kcal/day vs kg/week trade — 7700 kcal ≈ 1 kg, /7 ≈ 1100.
const int _kKcalPerKgWeekPerDay = 1100;

/// Returns the maintenance-kcal baseline implied by an existing goal
/// (subtracts the goal's own rate-delta) plus the goal's current kcal.
({int maintenance, int current}) _baselineKcal(Goal? template) {
  if (template == null) {
    return (maintenance: _kDefaultMaintenanceKcal, current: _kDefaultMaintenanceKcal);
  }
  final current = template.dailyCalorieTarget ?? _kDefaultMaintenanceKcal;
  final rate = template.weeklyRateKg ?? Decimal.zero;
  // maintenance = current - rate * 1100 (signed math; lose-rate is negative).
  final delta = (rate * Decimal.fromInt(_kKcalPerKgWeekPerDay))
      .round(scale: 0)
      .toBigInt()
      .toInt();
  return (maintenance: current - delta, current: current);
}

/// Compute the resulting daily kcal target for a given direction + rate
/// around the provided maintenance baseline. Floored at 1200 (safety) and
/// rounded to a 10-kcal step so the slider feels stable.
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
  // Use Decimal arithmetic — no doubles in the value chain (T-17).
  final shareDec = Decimal.parse(share.toString());
  final perG = Decimal.fromInt(kcalPerG);
  final kcalDec = Decimal.fromInt(kcal);
  final grams = (kcalDec * shareDec / perG).toDecimal(scaleOnInfinitePrecision: 2);
  return grams.round(scale: 0);
}

