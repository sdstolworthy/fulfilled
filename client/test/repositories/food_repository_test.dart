import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/nutrition.dart';
import 'package:fulfilled/domain/food.dart';
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

  group('customFoods', () {
    test('returns only source == user rows', () async {
      final foods = await repo.customFoods();
      expect(foods, isNotEmpty);
      for (final f in foods) {
        expect(f.source, equals(FoodSource.user),
            reason: 'every row must be user-source');
      }
    });

    test('count matches customCount()', () async {
      final foods = await repo.customFoods();
      final n = await repo.customCount();
      expect(foods.length, equals(n));
    });

    test('a freshly-created custom food appears in customFoods()', () async {
      final before = await repo.customFoods();
      final created = await repo.createCustom(
        FoodCreate(
          name: 'New custom',
          nutrition: NutritionPer100g(energyKcal: Decimal.fromInt(200)),
        ),
      );
      final after = await repo.customFoods();
      expect(after.length, equals(before.length + 1));
      expect(after.any((f) => f.id == created.id), isTrue);
    });

    test('limit + offset slice the result', () async {
      final all = await repo.customFoods();
      // Skip the head, take one — the resulting row's id must match the
      // second item of the unlimited list.
      final sliced = await repo.customFoods(limit: 1, offset: 1);
      expect(sliced.length, equals(1));
      expect(sliced.first.id, equals(all[1].id));
    });

    // FX-002: rows must come back newest-first by `createdAt` so a
    // freshly-saved custom surfaces at the top of My foods.
    test('returns rows sorted by createdAt descending', () async {
      final foods = await repo.customFoods();
      expect(foods.length, greaterThan(1));
      for (var i = 1; i < foods.length; i++) {
        expect(
          foods[i - 1].createdAt.isAfter(foods[i].createdAt) ||
              foods[i - 1].createdAt.isAtSameMomentAs(foods[i].createdAt),
          isTrue,
          reason: 'expected newest-first at index $i — '
              '${foods[i - 1].id}@${foods[i - 1].createdAt} '
              'should be >= ${foods[i].id}@${foods[i].createdAt}',
        );
      }
    });

    test('a freshly-created custom food lands at the head', () async {
      final created = await repo.createCustom(
        FoodCreate(
          name: 'Brand new',
          nutrition: NutritionPer100g(energyKcal: Decimal.fromInt(150)),
        ),
      );
      final after = await repo.customFoods();
      expect(after.first.id, equals(created.id),
          reason: 'newly-created custom must sort to the head');
    });
  });

  group('addServing', () {
    // A freshly-created custom food is the cleanest fixture: it has
    // exactly one serving (the auto-seeded synthetic 100 g) and a
    // stable id we can hand back to addServing.
    Future<Food> seedCustom() async {
      return repo.createCustom(
        FoodCreate(
          name: 'Test food',
          nutrition: NutritionPer100g(
            energyKcal: Decimal.fromInt(200),
            proteinG: Decimal.fromInt(10),
            carbsG: Decimal.fromInt(20),
            fatG: Decimal.fromInt(8),
          ),
        ),
      );
    }

    test('returns a serving with a non-empty id', () async {
      final food = await seedCustom();
      final serving = await repo.addServing(
        food.id,
        ServingCreate(label: '1 cup', grams: Decimal.fromInt(240)),
      );
      expect(serving.id, isNotEmpty);
      expect(serving.name, equals('1 cup'));
      expect(serving.grams, equals(Decimal.fromInt(240)));
      // Default for user-defined rows is non-default + source=user
      // (the synthetic 100 g is the only is_default row).
      expect(serving.isDefault, isFalse);
      expect(serving.source, equals(ServingSource.user));
    });

    test('calling twice appends two servings', () async {
      final food = await seedCustom();
      final beforeLen = food.servings.length;

      await repo.addServing(
        food.id,
        ServingCreate(label: '1 cup', grams: Decimal.fromInt(240)),
      );
      await repo.addServing(
        food.id,
        ServingCreate(label: '1 tbsp', grams: Decimal.fromInt(15)),
      );

      final after = await repo.get(food.id);
      expect(after.servings.length, equals(beforeLen + 2));
      // Insertion order preserved.
      expect(after.servings[beforeLen].name, equals('1 cup'));
      expect(after.servings[beforeLen + 1].name, equals('1 tbsp'));
    });

    test('throws FoodNotFoundError on unknown id', () async {
      expect(
        () => repo.addServing(
          'f_does_not_exist',
          ServingCreate(label: '1 cup', grams: Decimal.fromInt(240)),
        ),
        throwsA(isA<FoodNotFoundError>()),
      );
    });

    test('new serving sortOrder is greater than any existing', () async {
      final food = await seedCustom();
      // Synthetic 100 g lives at sortOrder 0 — the new row should land
      // at 1, then 2, so it sorts beneath the synthetic per T-10.
      final maxPre = food.servings
          .map((s) => s.sortOrder)
          .fold<int>(-1, (a, b) => b > a ? b : a);
      final first = await repo.addServing(
        food.id,
        ServingCreate(label: '1 cup', grams: Decimal.fromInt(240)),
      );
      expect(first.sortOrder, greaterThan(maxPre));

      final second = await repo.addServing(
        food.id,
        ServingCreate(label: '1 tbsp', grams: Decimal.fromInt(15)),
      );
      expect(second.sortOrder, greaterThan(first.sortOrder));
    });
  });
}
