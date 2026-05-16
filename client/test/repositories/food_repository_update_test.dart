// Tests for `FoodPatch` + `FoodRepository.updateCustom`.
//
// The mock repository mirrors the planned `PATCH /foods/{id}` —
// sparse patches, immutable `food_id`, replace-only servings (the
// synthetic 100 g system row is preserved across patches per T-10),
// editing-only-user-foods guard. These tests pin the shape so the
// future wire swap (TODO food-edit-wire) is a drop-in.

import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/drafts.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/food.dart';
import 'package:fulfilled/domain/food_patch.dart';
import 'package:fulfilled/domain/nutrition.dart';
import 'package:fulfilled/repositories/food_repository.dart';

import '_harness.dart';

void main() {
  late FoodRepository repo;

  setUp(() {
    resetRepositoriesForTest();
    repo = FoodRepository(buildTestApiClient());
  });

  tearDown(teardownRepositoriesForTest);

  Future<Food> seedCustom({
    String name = 'Test custom',
    String? brand,
    String? barcode,
  }) {
    return repo.createCustom(
      FoodCreate(
        name: name,
        brand: brand,
        barcode: barcode,
        nutrition: NutritionPer100g(
          energyKcal: Decimal.fromInt(200),
          proteinG: Decimal.fromInt(10),
          carbsG: Decimal.fromInt(20),
          fatG: Decimal.fromInt(8),
        ),
      ),
    );
  }

  group('FoodPatch.toJson', () {
    test('empty patch serialises to {}', () {
      expect(const FoodPatch().toJson(), <String, dynamic>{});
      expect(const FoodPatch().isEmpty, isTrue);
    });

    test('omits unset fields, includes set ones', () {
      final patch = FoodPatch(
        name: 'New name',
        nutritionPer100g: NutritionPer100g(energyKcal: Decimal.fromInt(150)),
      );
      final json = patch.toJson();
      expect(json['name'], 'New name');
      expect(json.containsKey('brands'), isFalse);
      expect(json.containsKey('barcode'), isFalse);
      expect(json['nutrition'], isA<Map<String, dynamic>>());
      expect(json['nutrition']['energy_kcal'], '150');
      expect(patch.isEmpty, isFalse);
    });

    test('clearBrand: true with null brand → emits "brands": null', () {
      final json = const FoodPatch(clearBrand: true).toJson();
      expect(json.containsKey('brands'), isTrue);
      expect(json['brands'], isNull);
    });

    test('explicit brand + clearBrand: true → explicit wins', () {
      expect(
        const FoodPatch(brand: 'Acme', clearBrand: true).toJson(),
        <String, dynamic>{'brands': 'Acme'},
      );
    });

    test('clearBarcode: true with null barcode → emits "barcode": null', () {
      final json = const FoodPatch(clearBarcode: true).toJson();
      expect(json.containsKey('barcode'), isTrue);
      expect(json['barcode'], isNull);
    });

    test('servings serialise to label + grams pairs', () {
      final patch = FoodPatch(
        servings: <DraftServing>[
          DraftServing(label: '1 cup', grams: Decimal.fromInt(240)),
          DraftServing(label: '1 tbsp', grams: Decimal.fromInt(15)),
        ],
      );
      final json = patch.toJson();
      expect(json['servings'], isA<List<dynamic>>());
      expect((json['servings'] as List<dynamic>).length, 2);
      expect((json['servings'] as List<dynamic>)[0], <String, dynamic>{
        'label': '1 cup',
        'grams': '240',
      });
    });

    test('never emits a food_id key under any input', () {
      final patches = <FoodPatch>[
        const FoodPatch(),
        const FoodPatch(name: 'x'),
        const FoodPatch(clearBrand: true),
        const FoodPatch(clearBarcode: true),
        FoodPatch(nutritionPer100g: NutritionPer100g(energyKcal: Decimal.one)),
        FoodPatch(servings: <DraftServing>[
          DraftServing(label: '1 cup', grams: Decimal.fromInt(240)),
        ]),
      ];
      for (final p in patches) {
        expect(p.toJson().containsKey('food_id'), isFalse,
            reason: 'food_id leaked in $p');
      }
    });
  });

  group('FoodRepository.updateCustom', () {
    test('success path: name change persists and round-trips through get',
        () async {
      final food = await seedCustom(name: 'Original');
      final updated = await repo.updateCustom(
        food.id,
        const FoodPatch(name: 'Renamed'),
      );
      expect(updated.id, food.id);
      expect(updated.name, 'Renamed');

      final reread = await repo.get(food.id);
      expect(reread.name, 'Renamed');
    });

    test('sparse patch leaves untouched fields alone', () async {
      final food =
          await seedCustom(name: 'Stable name', brand: 'Acme', barcode: '123');
      final updated = await repo.updateCustom(
        food.id,
        FoodPatch(
          nutritionPer100g: NutritionPer100g(
            energyKcal: Decimal.fromInt(500),
            proteinG: Decimal.fromInt(20),
            carbsG: Decimal.fromInt(40),
            fatG: Decimal.fromInt(15),
          ),
        ),
      );
      expect(updated.name, 'Stable name');
      expect(updated.brand, 'Acme');
      expect(updated.barcode, '123');
      expect(updated.nutritionPer100g.energyKcal, Decimal.fromInt(500));
    });

    test('clearBrand: true blanks an existing brand', () async {
      final food = await seedCustom(brand: 'Acme');
      expect(food.brand, 'Acme');
      final updated = await repo.updateCustom(
        food.id,
        const FoodPatch(clearBrand: true),
      );
      expect(updated.brand, isNull);
    });

    test('servings replace: user rows are swapped, synthetic 100 g preserved',
        () async {
      final food = await seedCustom();
      // Seed it with one user serving first via addServing.
      await repo.addServing(
        food.id,
        ServingCreate(label: '1 cup', grams: Decimal.fromInt(240)),
      );
      final before = await repo.get(food.id);
      // 1 synthetic + 1 user = 2.
      expect(before.servings.length, 2);

      final updated = await repo.updateCustom(
        food.id,
        FoodPatch(
          servings: <DraftServing>[
            DraftServing(label: '1 tbsp', grams: Decimal.fromInt(15)),
            DraftServing(label: '½ cup', grams: Decimal.fromInt(120)),
          ],
        ),
      );

      // Still has the synthetic, plus the two new user rows.
      expect(updated.servings.length, 3);
      final systemCount =
          updated.servings.where((s) => s.source == ServingSource.system).length;
      expect(systemCount, 1, reason: 'synthetic 100 g preserved');
      final userLabels = updated.servings
          .where((s) => s.source == ServingSource.user)
          .map((s) => s.name)
          .toList();
      expect(userLabels, equals(<String>['1 tbsp', '½ cup']),
          reason: 'user rows replaced, in given order');
    });

    test('throws FoodNotFoundError on unknown id', () async {
      expect(
        () => repo.updateCustom(
          'f_does_not_exist',
          const FoodPatch(name: 'X'),
        ),
        throwsA(isA<FoodNotFoundError>()),
      );
    });

    test('throws StateError on non-user food', () async {
      // The seed catalog has an OFF Greek yogurt; pick one of those.
      final off = await repo.search('greek yogurt');
      expect(off, isNotEmpty);
      final nonUser = off.firstWhere((f) => f.source != FoodSource.user);

      expect(
        () => repo.updateCustom(nonUser.id, const FoodPatch(name: 'X')),
        throwsA(isA<StateError>()),
      );
    });

    test('throws StateError when a subclass smuggles food_id into toJson',
        () async {
      final food = await seedCustom();
      expect(
        () => repo.updateCustom(food.id, _PatchWithFoodId(foodId: 'f_other')),
        throwsA(isA<StateError>()),
      );
      // And the entry's id is untouched.
      final after = await repo.get(food.id);
      expect(after.id, food.id);
    });

    test('empty patch is a no-op that keeps the food identical', () async {
      final food = await seedCustom();
      final updated = await repo.updateCustom(food.id, const FoodPatch());
      expect(updated.id, food.id);
      expect(updated.name, food.name);
      expect(updated.brand, food.brand);
      expect(updated.nutritionPer100g, food.nutritionPer100g);
      expect(updated.servings.length, food.servings.length);
    });
  });
}

/// Subclass that smuggles a `food_id` into the patch JSON, used to
/// verify the repository's defence-in-depth guard. Production code never
/// constructs one.
class _PatchWithFoodId extends FoodPatch {
  const _PatchWithFoodId({required this.foodId});

  final String foodId;

  @override
  Map<String, dynamic> toJson() {
    final base = super.toJson();
    return <String, dynamic>{...base, 'food_id': foodId};
  }
}
