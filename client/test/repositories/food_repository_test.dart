import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/repositories/food_repository.dart';

import '_harness.dart';

void main() {
  late FoodRepository repo;

  setUp(() {
    resetRepositoriesForTest();
    repo = FoodRepository(buildTestApiClient());
  });

  tearDown(teardownRepositoriesForTest);

  test('recent() returns at least one seeded food', () async {
    final recent = await repo.recent();
    expect(recent, isNotEmpty);
  });

  test('search("yog") matches "Greek yogurt"', () async {
    final hits = await repo.search('yog');
    expect(hits, isNotEmpty);
    expect(
      hits.any((f) => f.name.toLowerCase().contains('greek yogurt')),
      isTrue,
      reason: 'expected Greek yogurt in search results for "yog"',
    );
  });

  test('byBarcode(known) resolves to the seeded Greek yogurt', () async {
    // From _fixtures.dart: Greek yogurt's barcode.
    final food = await repo.byBarcode('8410076473203');
    expect(food.name, equals('Greek yogurt, plain'));
  });

  test('byBarcode(unknown) throws FoodNotFoundError', () async {
    expect(
      () => repo.byBarcode('0000000000000'),
      throwsA(isA<FoodNotFoundError>()),
    );
  });
}
