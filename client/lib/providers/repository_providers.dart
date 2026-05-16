import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api_client.dart';
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

final logRepositoryProvider = Provider<LogRepository>((ref) {
  final api = ref.watch(apiClientProvider);
  final foods = ref.watch(foodRepositoryProvider);
  final goals = ref.watch(goalRepositoryProvider);
  return LogRepository(
    api: api,
    foodRepository: foods,
    goalRepository: goals,
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
