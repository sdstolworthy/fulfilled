import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/enums.dart';
import '../../domain/goal.dart';
import '../../domain/locale_defaults.dart';
import '../../domain/user.dart';
import '../../providers/draft_providers.dart';
import '../../providers/profile_providers.dart';
import '../../providers/repository_providers.dart';
import '../../routing/routes.dart';
import '../../theme/context_extensions.dart';
import '../../domain/calories/estimate.dart';
import 'widgets/onboarding_step_shell.dart';
import 'widgets/step_1_welcome.dart';
import 'widgets/step_2_about_you.dart';
import 'widgets/step_3_goal.dart';

/// Three-step onboarding flow (screen 09).
///
/// Routing surface: `/onboarding/:step` (1, 2, or 3). Outside the
/// `ShellRoute` — no nav chrome. The router clamps `:step` defensively
/// because nothing else does.
///
/// Form-factor (T-15): the **screen root** is the single place that
/// branches on breakpoint. On `expanded` the column is constrained to
/// 520 px max-width centered, per architecture §9 ("at `expanded`
/// constrain the form column to 520 px max-width centered" — explicitly
/// NOT a 3-up tour). On `compact`/`medium` the body fills the screen.
///
/// Step navigation: 1 → 2 → 3 → commit. Step buttons call `setStep` and
/// `context.go(...)` so the URL stays addressable (T-14 — onboarding is
/// a route per route table). On Finish from step 3, the screen does a
/// `PATCH /me` then `POST /goals`, resets the draft, and `context.go`s
/// to `Routes.todayPath`.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({required this.step, super.key});

  /// 1-indexed step from the route. Caller (the router) clamps before
  /// passing; we re-clamp here for defence in depth.
  final int step;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  bool _submitting = false;
  String? _submitError;

  int get _step {
    final s = widget.step;
    if (s < 1) return 1;
    if (s > 3) return 3;
    return s;
  }

  void _go(int next) {
    final clamped = next < 1 ? 1 : (next > 3 ? 3 : next);
    ref.read(onboardingDraftProvider.notifier).goToStep(clamped);
    context.goNamed(
      Routes.onboardingName,
      pathParameters: <String, String>{'step': '$clamped'},
    );
  }

  /// QL-108 — "Start over" handler. Pops a confirmation `AlertDialog`
  /// so the user doesn't accidentally wipe their draft; on confirm
  /// resets the `onboardingDraftProvider` and routes to
  /// `/onboarding/1`. The dialog matches Material's stock shape; copy
  /// matches the PM spec ("Discard your responses and start over?").
  ///
  /// We `Navigator.pop(dialogCtx, true/false)` rather than reading
  /// state from the dialog body so the confirm/cancel handlers don't
  /// need any wired state of their own. The outer `await` resolves to
  /// `null` if the dialog is dismissed via the scrim (treated as a
  /// cancel).
  Future<void> _onStartOver() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Start over?'),
        content: const Text('Discard your responses and start over?'),
        actions: <Widget>[
          TextButton(
            key: const Key('start-over-cancel'),
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('start-over-confirm'),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('Yes'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    ref.read(onboardingDraftProvider.notifier).reset();
    if (!mounted) return;
    context.go('/onboarding/1');
  }

  Future<void> _finish() async {
    if (_submitting) return;
    final draft = ref.read(onboardingDraftProvider);

    // Defensive: step 3 button is enabled by the shell unconditionally; the
    // commit fences on completeness here so a half-filled draft fails fast.
    if (!draft.isStep2Complete || !draft.isStep3Complete) {
      setState(() {
        _submitError = 'Please finish steps 2 and 3 before continuing.';
      });
      return;
    }

    setState(() {
      _submitting = true;
      _submitError = null;
    });

    try {
      final profile = ref.read(profileRepositoryProvider);
      final goals = ref.read(goalRepositoryProvider);

      // PATCH /me with the profile bits.
      //
      // LU-008: include the chosen weight display unit so the server
      // persists it on `User.weight_unit`. QL-104 mirrors the same line
      // for height — both axes ride out of onboarding on a single
      // PATCH. Fall back to the locale defaults when the user never
      // tapped a segment (matches `onboardingWeightUnitProvider` /
      // `onboardingHeightUnitProvider`'s fallback).
      //
      // T-24 Case 2 — the onboarding finish routes forward to
      // `Routes.todayPath` (architect §3.4 row 09). Not pop-to-source:
      // the source is the welcome screen, the destination is today.
      final defaults = defaultUnitsForLocale();
      await profile.update(UserPatch(
        sex: draft.sex,
        birthDate: draft.birthDate,
        heightCm: draft.heightCm,
        activityLevel: draft.activityLevel,
        weightUnit: draft.weightUnit ?? defaults.weightUnit,
        heightUnit: draft.heightUnit ?? defaults.heightUnit,
      ),);

      // Compute the daily target client-side per architecture §9 — the
      // server stores the resulting int. T-09 is preserved because the
      // post-onboarding day-summary fetch will re-read the goal's
      // `dailyCalorieTarget` from this same POST response.
      final estimate = estimateCalories(
        sex: draft.sex,
        birthDate: draft.birthDate,
        heightCm: draft.heightCm,
        weightKg: draft.currentWeightKg,
        activityLevel: draft.activityLevel,
        direction: draft.direction,
        rateKgPerWeek: draft.rateKgPerWeek,
      );

      final signedRate = switch (draft.direction!) {
        GoalDirection.lose =>
          (draft.rateKgPerWeek ?? Decimal.zero) * Decimal.fromInt(-1),
        GoalDirection.gain => draft.rateKgPerWeek ?? Decimal.zero,
        GoalDirection.maintain => Decimal.zero,
      };

      final now = DateTime.now();
      await goals.create(GoalCreate(
        startsOn: DateTime(now.year, now.month, now.day),
        startWeightKg: draft.currentWeightKg,
        targetWeightKg: draft.targetWeightKg,
        weeklyRateKg: signedRate,
        dailyCalorieTarget: estimate?.dailyTargetKcal,
        proteinTargetG:
            estimate == null ? null : Decimal.fromInt(estimate.proteinG),
        carbsTargetG:
            estimate == null ? null : Decimal.fromInt(estimate.carbsG),
        fatTargetG:
            estimate == null ? null : Decimal.fromInt(estimate.fatG),
      ),);

      ref.invalidate(meProvider);
      ref.read(onboardingDraftProvider.notifier).reset();

      if (!mounted) return;
      context.go(Routes.todayPath);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitError = 'Could not save your profile. Please try again.';
      });
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final shell = _buildStepShell();

    final width = MediaQuery.sizeOf(context).width;
    // T-15: form-factor branch at root only. Expanded constrains the form
    // column to 520 px centered; compact/medium fill the screen.
    final body = width >= 1024
        ? Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: shell,
            ),
          )
        : shell;

    return Scaffold(
      backgroundColor: context.colors.bg,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            body,
            if (_submitError != null) _ErrorBanner(message: _submitError!),
          ],
        ),
      ),
    );
  }

  Widget _buildStepShell() {
    switch (_step) {
      case 1:
        return OnboardingStepShell(
          step: 1,
          total: 3,
          title: '',
          subtitle: null,
          showEyebrow: false,
          showProgress: false,
          body: const Step1Welcome(),
          primaryLabel: 'Get started',
          onPrimary: () => _go(2),
          onStartOver: _onStartOver,
        );
      case 2:
        return OnboardingStepShell(
          step: 2,
          total: 3,
          title: 'About you',
          subtitle:
              'We use this to estimate your daily calorie needs. You can change it anytime.',
          onBack: () => _go(1),
          body: const Step2AboutYou(),
          primaryLabel: 'Continue',
          onPrimary: () => _go(3),
          onStartOver: _onStartOver,
        );
      case 3:
      default:
        return OnboardingStepShell(
          step: 3,
          total: 3,
          title: 'Set a goal',
          subtitle:
              "Pick a direction. You'll get a daily calorie target you can edit later.",
          onBack: () => _go(2),
          body: const Step3Goal(),
          primaryLabel: _submitting ? 'Saving…' : 'Start logging',
          onPrimary: _finish,
          onStartOver: _onStartOver,
        );
    }
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        top: false,
        child: Container(
          margin: EdgeInsets.fromLTRB(
            context.space.x4,
            0,
            context.space.x4,
            context.space.x4,
          ),
          padding: EdgeInsets.all(context.space.x3),
          decoration: BoxDecoration(
            color: context.colors.dangerSoft,
            borderRadius: BorderRadius.circular(context.radius.r2),
            border: Border.all(color: context.colors.danger),
          ),
          child: Text(
            message,
            style: context.text.meta.copyWith(color: context.colors.danger),
          ),
        ),
      ),
    );
  }
}
