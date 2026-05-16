// Test harness for repository unit tests. Constructs a `Dio`-backed
// `ApiClient` (the repositories keep the reference for the eventual real
// API; the mock methods never actually call it) and resets the shared
// in-memory state on each test boot so tests don't leak across files.

import 'package:dio/dio.dart';
import 'package:fulfilled/data/api_client.dart';
import 'package:fulfilled/repositories/_mock_latency.dart';
import 'package:fulfilled/repositories/food_repository.dart';
import 'package:fulfilled/repositories/goal_repository.dart';
import 'package:fulfilled/repositories/log_repository.dart';
import 'package:fulfilled/repositories/profile_repository.dart';
import 'package:fulfilled/repositories/weight_repository.dart';
import 'package:fulfilled/repositories/_fixtures.dart';

ApiClient buildTestApiClient() => ApiClient(Dio());

/// Reset every repository's in-memory state to the seed and shrink the
/// mock latency to (effectively) zero so the awaits inside the mocks
/// don't slow the suite. Call in `setUp`.
void resetRepositoriesForTest() {
  FoodRepository.resetForTesting();
  GoalRepository.resetForTesting();
  WeightRepository.resetForTesting();
  LogRepository.resetForTesting();
  ProfileRepository.resetForTesting();
  setMockClockForTesting(null);
  setMockLatencyForTesting();
}

void teardownRepositoriesForTest() {
  clearMockLatencyForTesting();
  setMockClockForTesting(null);
}
