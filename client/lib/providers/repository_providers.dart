import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api_client.dart';
import '../data/outbox/log_outbox_notifier.dart';
import '../form_factor/form_factor.dart';
import '../repositories/food_repository.dart';
import '../repositories/goal_repository.dart';
import '../repositories/log_repository.dart';
import '../repositories/profile_repository.dart';
import '../repositories/weight_repository.dart';

/// Five repository providers — one per domain. Screen agents read these
/// to invalidate caches after a mutation (e.g. after `POST /log` the
/// log-entry sheet does `ref.invalidate(daySummaryProvider(date))`).
///
/// Repositories are constructed once and live for the app's lifetime —
/// state is in-memory and shared. The eventual real-API agent wires up
/// the same provider names so screen code does not change between
/// "mock" and "live" modes.

final foodRepositoryProvider = Provider<FoodRepository>((ref) {
  final api = ref.watch(apiClientProvider);
  return FoodRepository(api);
});

final goalRepositoryProvider = Provider<GoalRepository>((ref) {
  final api = ref.watch(apiClientProvider);
  return GoalRepository(api);
});

final weightRepositoryProvider = Provider<WeightRepository>((ref) {
  final api = ref.watch(apiClientProvider);
  return WeightRepository(api);
});

/// Form-factor lookup at the provider layer.
///
/// The repository layer needs to know whether we're on a compact form
/// factor at construction time so `logRepositoryProvider` can wire in
/// the offline outbox (T-22 / LU-001's `isPendingSync` predicate needs
/// the outbox handle on compact only — medium/expanded surface errors
/// inline, no queueing).
///
/// `FormFactor.of(context)` reads `MediaQuery`, which providers don't
/// have. So we approximate it at boot from `defaultTargetPlatform`:
/// iOS / Android default to compact, everything else defaults to
/// medium. Screens still call `FormFactor.of(context)` for **layout**;
/// this provider is for "is the outbox the right write path"
/// decisions, which are stable per-platform in v1 (the user can't
/// resize their phone). Tests and the eventual responsive desktop
/// shell override this provider directly.
final formFactorOverrideProvider = Provider<FormFactor>((ref) {
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
      return FormFactor.compact;
    case TargetPlatform.fuchsia:
    case TargetPlatform.linux:
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
      return FormFactor.medium;
  }
});

final logRepositoryProvider = Provider<LogRepository>((ref) {
  final api = ref.watch(apiClientProvider);
  final foods = ref.watch(foodRepositoryProvider);
  final goals = ref.watch(goalRepositoryProvider);
  final ff = ref.watch(formFactorOverrideProvider);
  // T-22: compact wires the outbox so `isPendingSync` can project
  // pending/failed rows back to the day-view. Medium/expanded surface
  // errors inline (architecture §5) and never queue, so they pass
  // `outbox: null` — the predicate then always returns false.
  final outbox = ff.isCompact ? ref.watch(logOutboxProvider.notifier) : null;
  return LogRepository(
    api: api,
    foodRepository: foods,
    goalRepository: goals,
    outbox: outbox,
  );
});

final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  final api = ref.watch(apiClientProvider);
  final weights = ref.watch(weightRepositoryProvider);
  final foods = ref.watch(foodRepositoryProvider);
  return ProfileRepository(
    api: api,
    weightRepository: weights,
    foodRepository: foods,
  );
});
