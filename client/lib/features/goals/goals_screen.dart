import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/goal.dart';
import '../../providers/goal_providers.dart';
import '../../repositories/goal_repository.dart';
import '../../theme/context_extensions.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/skeleton.dart';
import 'widgets/edit_goal_sheet.dart';
import 'widgets/goal_active_card.dart';
import 'widgets/goal_history_list.dart';
import 'widgets/new_goal_dialog.dart';

/// Local debug flag — flip to `true` to inspect the error/loading
/// branches against the mock provider, then revert before committing.
/// T-013 — compile-time const so the dead branch is tree-shaken.
const bool _kDebugForceError = false;

/// Screen 07 — Goals.
///
/// Composition matches architecture §9:
/// `top header (title + overflow) → GoalActiveCard → "History" section
/// header → GoalHistoryList`.
///
/// **Shell wrapping.** This route is mounted inside the `ShellRoute`
/// (see `routing/app_router.dart`) which already wraps the child in
/// `AppScaffold`. The scaffold's `title` slot is set by the shell
/// builder; because the shell does not thread per-route titles, the
/// screen also renders its own page header to match the mock (the
/// expanded sidebar variant gets its own top bar from `AppScaffold`
/// regardless).
///
/// **Web transform.** Hero card pulls in to max-width 720; history
/// stacks below. Compact stays full-bleed within the scaffold.
///
/// **No-active-goal handling.** [activeGoalProvider] throws
/// `GoalNotFoundError` when no goal covers today. The `AsyncValue.when`
/// `error` arm distinguishes this from a transport error and renders a
/// "Set your first goal" CTA that opens [openNewGoal] with `template:
/// null`. Anything else is surfaced as an inline error string (T-11).
class GoalsScreen extends ConsumerWidget {
  const GoalsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(activeGoalProvider);
    final all = ref.watch(goalsProvider);

    // T-11 — SnackBar shim on transient errors. Only fires on the
    // transition into the error state, and only for the all-goals
    // provider (the active-goal "GoalNotFoundError" path is an
    // expected empty-state, not a failure to surface).
    ref.listen<AsyncValue<List<Goal>>>(goalsProvider, (prev, next) {
      if (next.hasError && (prev == null || !prev.hasError)) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text("Couldn't load goal history: ${next.error}"),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    });
    ref.listen<AsyncValue<Goal>>(activeGoalProvider, (prev, next) {
      if (next.hasError && (prev == null || !prev.hasError)) {
        if (next.error is GoalNotFoundError) return;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text("Couldn't load goal: ${next.error}"),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    });

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxBodyWidth = constraints.maxWidth >= 1024 ? 720.0 : double.infinity;
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxBodyWidth),
            child: ListView(
              padding: EdgeInsets.symmetric(
                horizontal: context.space.x5,
                vertical: context.space.x4,
              ),
              children: <Widget>[
                _GoalsHeader(active: active),
                SizedBox(height: context.space.x3),
                _HeroArea(active: active),
                SizedBox(height: context.space.x5),
                const _SectionHeader('History'),
                SizedBox(height: context.space.x2 + context.space.x05),
                _HistoryArea(all: all, active: active),
                SizedBox(height: context.space.x6),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _GoalsHeader extends StatelessWidget {
  const _GoalsHeader({required this.active});
  final AsyncValue<Goal> active;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            'Goals',
            style: context.text.pageTitle,
          ),
        ),
        _OverflowButton(active: active),
      ],
    );
  }
}

class _OverflowButton extends StatelessWidget {
  const _OverflowButton({required this.active});
  final AsyncValue<Goal> active;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_OverflowAction>(
      tooltip: 'More',
      icon: Icon(Icons.more_horiz, color: context.colors.ink2),
      itemBuilder: (_) => <PopupMenuEntry<_OverflowAction>>[
        const PopupMenuItem<_OverflowAction>(
          value: _OverflowAction.newGoal,
          child: Text('New goal'),
        ),
        PopupMenuItem<_OverflowAction>(
          value: _OverflowAction.editCurrent,
          enabled: active.valueOrNull != null,
          child: const Text('Edit current'),
        ),
      ],
      onSelected: (a) async {
        switch (a) {
          case _OverflowAction.newGoal:
            await openNewGoal(context, template: active.valueOrNull);
            break;
          case _OverflowAction.editCurrent:
            final g = active.valueOrNull;
            if (g != null) await openEditGoal(context, active: g);
            break;
        }
      },
    );
  }
}

enum _OverflowAction { newGoal, editCurrent }

class _HeroArea extends ConsumerWidget {
  const _HeroArea({required this.active});
  final AsyncValue<Goal> active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (_kDebugForceError) {
      return _HeroErrorBox(
        onRetry: () => ref.invalidate(activeGoalProvider),
      );
    }
    return active.when(
      data: (g) => GoalActiveCard(
        goal: g,
        onEditCurrent: () => openEditGoal(context, active: g),
        onNewGoal: () => openNewGoal(context, template: g),
      ),
      loading: () => const _HeroSkeleton(),
      error: (err, _) {
        if (err is GoalNotFoundError) {
          return const _NoActiveGoalCta();
        }
        return _HeroErrorBox(
          onRetry: () => ref.invalidate(activeGoalProvider),
        );
      },
    );
  }
}

/// Skeleton placeholder while the active goal is loading. T-08: matches
/// the hero's height so the rest of the screen doesn't jump when data
/// lands. Built from the lifted [Skeleton] primitive (T-23).
class _HeroSkeleton extends StatelessWidget {
  const _HeroSkeleton();
  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Skeleton(
      height: 320,
      borderRadius: BorderRadius.circular(tokens.radius.r4),
    );
  }
}

/// Hero error state — replaces the previous bordered danger-soft box
/// with the lifted [EmptyState] composition. The retry CTA
/// re-invalidates `activeGoalProvider`. T-13 — no spinner; T-11 — the
/// SnackBar shim lives on the parent so this stays a persistent inline
/// surface.
class _HeroErrorBox extends StatelessWidget {
  const _HeroErrorBox({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      decoration: BoxDecoration(
        color: context.colors.surface,
        borderRadius: BorderRadius.circular(tokens.radius.r4),
        border: Border.all(color: context.colors.line),
      ),
      child: EmptyState(
        icon: Icons.cloud_off,
        title: "Couldn't load your goal",
        body: 'Pull to refresh or tap retry.',
        action: SizedBox(
          width: 200,
          child: PrimaryButton(
            label: 'Retry',
            onPressed: onRetry,
          ),
        ),
      ),
    );
  }
}

/// First-run CTA — the user has no active goal covering today. Surfaces a
/// single primary action that opens the new-goal flow with no template.
class _NoActiveGoalCta extends StatelessWidget {
  const _NoActiveGoalCta();
  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final colors = context.colors;
    return Container(
      key: const ValueKey('goals.no_active_goal_cta'),
      padding: EdgeInsets.all(tokens.space.x5),
      decoration: BoxDecoration(
        color: colors.accentSoft,
        borderRadius: BorderRadius.circular(tokens.radius.r4),
        border: Border.all(color: colors.accentLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'No active goal',
            style: context.text.title.copyWith(color: colors.ink),
          ),
          SizedBox(height: tokens.space.x1),
          Text(
            'Set a goal to get a daily kcal target and macro split.',
            style: context.text.meta.copyWith(color: colors.ink2),
          ),
          SizedBox(height: tokens.space.x4),
          SizedBox(
            height: 44,
            child: ElevatedButton(
              key: const ValueKey('goals.set_first_goal'),
              onPressed: () => openNewGoal(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: colors.accent,
                foregroundColor: colors.surface,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(tokens.radius.r2),
                ),
              ),
              child: const Text('Set your first goal'),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: context.text.eyebrow.copyWith(color: context.colors.ink3),
    );
  }
}

class _HistoryArea extends ConsumerWidget {
  const _HistoryArea({required this.all, required this.active});
  final AsyncValue<List<Goal>> all;
  final AsyncValue<Goal> active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return all.when(
      data: (goals) => GoalHistoryList(
        goals: goals,
        activeGoalId: active.valueOrNull?.id,
      ),
      loading: () => const _HistorySkeleton(),
      error: (err, _) {
        // T-11 + T-13: inline EmptyState with a retry CTA. The
        // matching SnackBar shim lives on the parent screen so it
        // doesn't double-fire.
        return Container(
          decoration: BoxDecoration(
            color: context.colors.surface,
            borderRadius: BorderRadius.circular(context.radius.r3),
            border: Border.all(color: context.colors.line),
          ),
          child: EmptyState(
            icon: Icons.cloud_off,
            title: "Couldn't load history",
            body: 'Pull to refresh or tap retry.',
            action: SizedBox(
              width: 200,
              child: PrimaryButton(
                label: 'Retry',
                onPressed: () => ref.invalidate(goalsProvider),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Skeleton for the goal-history list. T-08: matches the eventual
/// card-shaped history block height (~180 px) so the screen doesn't
/// jump when data resolves. Lifted [Skeleton] primitive (T-23).
class _HistorySkeleton extends StatelessWidget {
  const _HistorySkeleton();
  @override
  Widget build(BuildContext context) {
    return Skeleton(
      height: 180,
      borderRadius: BorderRadius.circular(context.radius.r3),
    );
  }
}
