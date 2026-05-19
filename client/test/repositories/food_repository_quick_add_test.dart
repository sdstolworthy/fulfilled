// Quick-add synthetic food filter — must NOT surface in "My foods".
//
// The synthetic `food_quick_add` row is seeded with `source ==
// FoodSource.user` so the existing log-write path resolves it on
// `LogRepository.create`. But it is not a user-authored food; surfacing
// it in `customFoods()` / `customCount()` would lie about the user's
// catalog. `FoodRepository` filters it by id; this test guards the
// contract.

import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/repositories/food_repository.dart';

import '_harness.dart';

void main() {
  late FoodRepository repo;

  setUp(() {
    resetRepositoriesForTest();
    // The quick-add filter is a fixture-store invariant — exercise
    // the in-memory seed path explicitly.
    repo = FoodRepository(buildTestApiClient(), useFixtures: true);
  });

  tearDown(teardownRepositoriesForTest);

  test('customFoods() does not include the synthetic Quick-add row', () async {
    final foods = await repo.customFoods();
    expect(foods, isNotEmpty,
        reason: 'seed includes user-authored foods alongside Quick-add',);
    expect(
      foods.any((f) => f.id == 'food_quick_add'),
      isFalse,
      reason: 'food_quick_add must be filtered out of My foods',
    );
    expect(
      foods.any((f) => f.name == 'Quick add'),
      isFalse,
      reason: 'belt + braces: name check too',
    );
  });

  test('customCount() does not count the synthetic Quick-add row', () async {
    final foods = await repo.customFoods();
    final count = await repo.customCount();
    expect(count, equals(foods.length),
        reason: 'count mirrors the filtered list exactly',);
  });

  test('lookup() still resolves food_quick_add by id', () async {
    // The filter only applies to user-facing surfaces. The catalog
    // lookup must still find the synthetic row so `LogRepository.create`
    // can resolve `foodId == food_quick_add`.
    final food = repo.lookup('food_quick_add');
    expect(food, isNotNull);
    expect(food!.name, equals('Quick add'));
    // The "kcal" serving is the default.
    expect(food.servings.length, equals(1));
    expect(food.servings.first.id, equals('sv_kcal'));
    expect(food.servings.first.isDefault, isTrue);
  });
}
