// Tests for `FoodPatch` + `FoodRepository.updateCustom`.
//
// The mock repository mirrors the planned `PATCH /foods/{id}` —
// sparse patches, immutable `food_id`, replace-only servings. Per
// Ask 10 nutrition lives on each serving; the food row carries no
// per-100g panel.

import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/drafts.dart';
import 'package:fulfilled/domain/food.dart';
import 'package:fulfilled/domain/food_patch.dart';
import 'package:fulfilled/domain/unit.dart';
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
        servings: <ServingCreate>[
          ServingCreate(
            label: '100 g',
            amount: Decimal.fromInt(100),
            unit: Unit.g,
            kcal: Decimal.fromInt(200),
            proteinG: Decimal.fromInt(10),
            carbsG: Decimal.fromInt(20),
            fatG: Decimal.fromInt(8),
            isDefault: true,
          ),
        ],
      ),
    );
  }

  group('FoodPatch.toJson', () {
    test('empty patch serialises to {}', () {
      expect(const FoodPatch().toJson(), <String, dynamic>{});
      expect(const FoodPatch().isEmpty, isTrue);
    });

    test('omits unset fields, includes set ones', () {
      const patch = FoodPatch(name: 'New name');
      final json = patch.toJson();
      expect(json['name'], 'New name');
      expect(json.containsKey('brands'), isFalse);
      expect(json.containsKey('barcode'), isFalse);
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

    test('servings serialise to amount + unit + kcal triples', () {
      final patch = FoodPatch(
        servings: <DraftServing>[
          DraftServing(
            label: '1 cup',
            amount: Decimal.fromInt(1),
            unit: Unit.cup,
            kcal: Decimal.fromInt(149),
          ),
          DraftServing(
            label: '1 tbsp',
            amount: Decimal.fromInt(1),
            unit: Unit.tbsp,
            kcal: Decimal.fromInt(10),
          ),
        ],
      );
      final json = patch.toJson();
      expect(json['servings'], isA<List<dynamic>>());
      expect((json['servings'] as List<dynamic>).length, 2);
      expect((json['servings'] as List<dynamic>)[0], <String, dynamic>{
        'label': '1 cup',
        'amount': '1',
        'unit': 'cup',
        'kcal': '149',
        'is_default': false,
      });
    });

    test('never emits a food_id key under any input', () {
      final patches = <FoodPatch>[
        const FoodPatch(),
        const FoodPatch(name: 'x'),
        const FoodPatch(clearBrand: true),
        const FoodPatch(clearBarcode: true),
        FoodPatch(servings: <DraftServing>[
          DraftServing(
            label: '1 cup',
            amount: Decimal.fromInt(1),
            unit: Unit.cup,
            kcal: Decimal.fromInt(149),
          ),
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
          servings: <DraftServing>[
            DraftServing(
              label: '100 g',
              amount: Decimal.fromInt(100),
              unit: Unit.g,
              kcal: Decimal.fromInt(500),
              proteinG: Decimal.fromInt(20),
              carbsG: Decimal.fromInt(40),
              fatG: Decimal.fromInt(15),
              isDefault: true,
            ),
          ],
        ),
      );
      expect(updated.name, 'Stable name');
      expect(updated.brand, 'Acme');
      expect(updated.barcode, '123');
      expect(updated.defaultServing.kcal, Decimal.fromInt(500));
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

    test('servings replace: full list swap', () async {
      final food = await seedCustom();
      // Seed it with one extra user serving first via addServing.
      await repo.addServing(
        food.id,
        ServingCreate(
          label: '1 cup',
          amount: Decimal.fromInt(1),
          unit: Unit.cup,
          kcal: Decimal.fromInt(149),
        ),
      );
      final before = await repo.get(food.id);
      expect(before.servings.length, 2);

      final updated = await repo.updateCustom(
        food.id,
        FoodPatch(
          servings: <DraftServing>[
            DraftServing(
              label: '1 tbsp',
              amount: Decimal.fromInt(1),
              unit: Unit.tbsp,
              kcal: Decimal.fromInt(15),
            ),
            DraftServing(
              label: '½ cup',
              amount: Decimal.parse('0.5'),
              unit: Unit.cup,
              kcal: Decimal.fromInt(75),
            ),
          ],
        ),
      );

      // Replace is wholesale.
      expect(updated.servings.length, 2);
      final labels = updated.servings.map((s) => s.name).toList();
      expect(labels, equals(<String>['1 tbsp', '½ cup']),
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

    test('empty patch is a no-op that keeps the food identical', () async {
      final food = await seedCustom();
      final updated = await repo.updateCustom(food.id, const FoodPatch());
      expect(updated.id, food.id);
      expect(updated.name, food.name);
      expect(updated.brand, food.brand);
      expect(updated.defaultServing.kcal, food.defaultServing.kcal);
      expect(updated.servings.length, food.servings.length);
    });

    // FX-002: editing a custom food must preserve the original
    // `createdAt`. If `updateCustom` bumped it to "now" the row would
    // jump to the top of My foods on every save.
    test('preserves the original createdAt', () async {
      final food = await seedCustom();
      final originalCreatedAt = food.createdAt;
      // Sleep-free guarantee: we don't need wall-clock to advance —
      // the assertion is "createdAt unchanged", not "createdAt older".
      final updated = await repo.updateCustom(
        food.id,
        const FoodPatch(name: 'Renamed again'),
      );
      expect(updated.createdAt, equals(originalCreatedAt));
      final reread = await repo.get(food.id);
      expect(reread.createdAt, equals(originalCreatedAt));
    });
  });

  // FX-002: `createCustom` must stamp `createdAt` to "now" so the new
  // row sorts to the head of My foods.
  group('FoodRepository.createCustom', () {
    test('stamps createdAt around DateTime.now()', () async {
      final before = DateTime.now();
      final created = await seedCustom();
      final after = DateTime.now();
      expect(
        !created.createdAt.isBefore(before) &&
            !created.createdAt.isAfter(after),
        isTrue,
        reason:
            'createdAt ${created.createdAt} should fall within [$before, $after]',
      );
    });
  });
}
