import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/goal.dart';
import 'repository_providers.dart';

/// Goal-domain providers. Screen 07's hero card binds to
/// [activeGoalProvider]; the history list binds to [goalsProvider].
///
/// **No-active-goal handling.** [activeGoalProvider] throws
/// [GoalNotFoundError] (from `goal_repository.dart`) when the caller has
/// no goal covering today. Screens that consume it should catch the
/// error in the `AsyncValue.when` `error` arm and render a "Set a goal"
/// affordance instead of bubbling. The day summary path swallows the
/// same error internally and renders the "Set a goal" affordance on
/// screen 01 via `DaySummary.kcalTarget == null`.

/// Currently-active goal. Throws `GoalNotFoundError` when the user has
/// never created a goal — see file docstring.
final activeGoalProvider = FutureProvider<Goal>((ref) {
  final repo = ref.watch(goalRepositoryProvider);
  return repo.active();
});

/// Every goal the user owns, newest started first. Screen 07's history
/// list filters this client-side.
final goalsProvider = FutureProvider<List<Goal>>((ref) {
  final repo = ref.watch(goalRepositoryProvider);
  return repo.all();
});
