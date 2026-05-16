import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/repositories/food_repository.dart';
import 'package:fulfilled/repositories/profile_repository.dart';
import 'package:fulfilled/repositories/weight_repository.dart';

import '_harness.dart';

void main() {
  late ProfileRepository repo;

  setUp(() {
    resetRepositoriesForTest();
    final api = buildTestApiClient();
    repo = ProfileRepository(
      api: api,
      weightRepository: WeightRepository(api),
      foodRepository: FoodRepository(api),
    );
  });

  tearDown(teardownRepositoriesForTest);

  test('me().displayName == "Sam Reyes"', () async {
    final user = await repo.me();
    expect(user.displayName, equals('Sam Reyes'));
  });

  test('me() fills derived currentWeightKg from the latest weight entry',
      () async {
    final user = await repo.me();
    expect(user.currentWeightKg, isNotNull);
  });

  test('me() fills customFoodCount from the food catalog', () async {
    final user = await repo.me();
    // Seed has 4 user-source foods.
    expect(user.customFoodCount, greaterThanOrEqualTo(1));
  });
}
