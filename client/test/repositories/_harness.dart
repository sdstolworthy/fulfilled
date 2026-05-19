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

/// Construct an `ApiClient` for repo tests. The `Dio` instance is
/// real; tests that need to assert on the wire swap its
/// `httpClientAdapter` for a `FakeDioAdapter`. The base URL is a
/// non-routable sentinel — tests that don't override the adapter
/// either don't issue network calls (mock-only flows) or fail fast
/// with a `DioException`.
ApiClient buildTestApiClient() => ApiClient(
      Dio(BaseOptions(baseUrl: 'https://test.example/api/v1')),
      baseUrl: 'https://test.example/api/v1',
    );

/// Construct a [FoodRepository] that talks to the live (mocked) Dio
/// surface. Used by repo unit tests that install a [FakeDioAdapter]
/// and assert on the wire shape. Skips the fixture-mode short-circuit
/// so the Dio path actually runs.
FoodRepository buildLiveFoodRepository(ApiClient api) =>
    FoodRepository(api, useFixtures: false);

/// Construct a [LogRepository] in live (mocked-Dio) mode. The food +
/// goal repos are also wired up live so end-to-end flows that consult
/// them (e.g. `LogRepository.create` looking up the seed food) reach
/// the same adapter.
LogRepository buildLiveLogRepository(ApiClient api) => LogRepository(
      api: api,
      foodRepository: FoodRepository(api, useFixtures: false),
      useFixtures: false,
    );

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
