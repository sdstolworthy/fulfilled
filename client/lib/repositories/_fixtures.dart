// MOCK ONLY — this entire file is deletable once the real API is wired.
//
// Seed data for the mock repositories, reshaped to Ask 10's per-serving
// nutrition model. Each food has 1+ servings; every serving carries its
// own kcal + macros + an {amount, unit} declaration. No per-100g math.
//
// The per-serving numbers were synthesized from the previous per-100g
// fixtures × the serving grams that used to live on `Serving.grams` —
// so the realism is preserved end-to-end (the day view's totals and
// the per-meal subtotals land at the same neighborhoods as before).

import 'package:decimal/decimal.dart';

import '../domain/day_summary.dart';
import '../domain/enums.dart';
import '../domain/food.dart';
import '../domain/goal.dart';
import '../domain/log_entry.dart';
import '../domain/meal.dart';
import '../domain/quick_add.dart';
import '../domain/serving.dart';
import '../domain/unit.dart';
import '../domain/user.dart';
import '../domain/weight.dart';

/// Test-controllable clock.
DateTime Function()? _clockOverride;

DateTime mockNow() => (_clockOverride ?? DateTime.now)();

DateTime mockToday() {
  final n = mockNow();
  return DateTime(n.year, n.month, n.day);
}

void setMockClockForTesting(DateTime Function()? clock) {
  _clockOverride = clock;
}

DateTime _daysAgo(int days) {
  final t = mockToday();
  return DateTime(t.year, t.month, t.day - days);
}

DateTime _dayAt(int days, int hour, int minute) {
  final t = mockToday();
  return DateTime(t.year, t.month, t.day - days, hour, minute);
}

Decimal _d(String v) => Decimal.parse(v);

// ─── User ────────────────────────────────────────────────────────────────

const String mockUserId = 'u_sam_reyes';

User buildSeedUser({
  WeightUnit weightUnit = WeightUnit.kg,
}) {
  return User(
    id: mockUserId,
    displayName: 'Sam Reyes',
    email: 'sam@example.com',
    sex: Sex.male,
    birthDate: DateTime(1993, 4, 12),
    heightCm: _d('178'),
    activityLevel: ActivityLevel.moderate,
    createdAt: DateTime(2026, 1, 5, 9, 0),
    updatedAt: DateTime(2026, 5, 12, 8, 30),
    weightUnit: weightUnit,
  );
}

// ─── Foods ───────────────────────────────────────────────────────────────
//
// Per-serving nutrition (kcal + macros) inlined. Mix of mass / volume /
// count units so the editor + log-entry sheet have variety to render.

// The canonical ids for the Quick-add synthetic food + serving live
// on `domain/quick_add.dart` (audit #8). Re-exported through this
// file's existing `fx.quickAddFoodId` namespace would clash with the
// re-export, so callers that need them import from the domain
// directly.

List<Food> buildSeedFoods() {
  return <Food>[
    // ── OFF (branded) ──────────────────────────────────────────────
    Food(
      id: 'f_greek_yogurt_plain',
      createdAt: _daysAgo(82),
      name: 'Greek yogurt, plain',
      brand: 'Fage',
      barcode: '8410076473203',
      source: FoodSource.off,
      isCustom: false,
      qualityScore: 86,
      nutriscore: NutriscoreGrade.b,
      servings: <Serving>[
        Serving(
          id: 'sv_greek_yogurt_container',
          label: '1 container',
          amount: _d('170'),
          unit: Unit.g,
          kcal: _d('100'),
          proteinG: _d('17'),
          carbsG: _d('6.1'),
          fatG: _d('0.7'),
          fiberG: _d('0'),
          sugarG: _d('5.4'),
          sodiumMg: _d('61'),
          saturatedFatG: _d('0.2'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
        Serving(
          id: 'sv_greek_yogurt_cup',
          label: '1 cup',
          amount: _d('1'),
          unit: Unit.cup,
          kcal: _d('145'),
          proteinG: _d('24.5'),
          carbsG: _d('8.8'),
          fatG: _d('1.0'),
          fiberG: _d('0'),
          sugarG: _d('7.8'),
          sodiumMg: _d('88'),
          saturatedFatG: _d('0.2'),
          isDefault: false,
          source: ServingSource.off,
          sortOrder: 2,
        ),
      ],
      categoriesTags: const <String>['dairies', 'yogurts'],
    ),
    Food(
      id: 'f_peanut_butter',
      createdAt: _daysAgo(78),
      name: 'Peanut butter, smooth',
      brand: 'Skippy',
      barcode: '0037600138307',
      source: FoodSource.off,
      isCustom: false,
      qualityScore: 71,
      nutriscore: NutriscoreGrade.c,
      servings: <Serving>[
        Serving(
          id: 'sv_pb_tbsp',
          label: '2 tbsp',
          amount: _d('2'),
          unit: Unit.tbsp,
          kcal: _d('192'),
          proteinG: _d('7.1'),
          carbsG: _d('7.1'),
          fatG: _d('16.3'),
          fiberG: _d('1.7'),
          sugarG: _d('2.9'),
          sodiumMg: _d('137'),
          saturatedFatG: _d('3.2'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['spreads', 'nut-butters'],
    ),
    Food(
      id: 'f_oatmeal_rolled',
      createdAt: _daysAgo(74),
      name: 'Rolled oats',
      brand: 'Quaker',
      barcode: '0030000010402',
      source: FoodSource.off,
      isCustom: false,
      qualityScore: 91,
      nutriscore: NutriscoreGrade.a,
      servings: <Serving>[
        Serving(
          id: 'sv_oats_half_cup',
          label: '1/2 cup dry',
          amount: _d('40'),
          unit: Unit.g,
          kcal: _d('152'),
          proteinG: _d('5.3'),
          carbsG: _d('27.1'),
          fatG: _d('2.6'),
          fiberG: _d('4.0'),
          sugarG: _d('0.4'),
          sodiumMg: _d('2.4'),
          saturatedFatG: _d('0.4'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['cereals', 'oats'],
    ),
    Food(
      id: 'f_protein_bar',
      createdAt: _daysAgo(70),
      name: 'Chocolate chip cookie dough protein bar',
      brand: 'Quest',
      barcode: '0888849000043',
      source: FoodSource.off,
      isCustom: false,
      qualityScore: 64,
      nutriscore: NutriscoreGrade.c,
      servings: <Serving>[
        Serving(
          id: 'sv_quest_bar',
          label: '1 bar',
          amount: _d('1'),
          unit: Unit.piece,
          kcal: _d('200'),
          proteinG: _d('20'),
          carbsG: _d('24'),
          fatG: _d('8'),
          fiberG: _d('14'),
          sugarG: _d('2'),
          sodiumMg: _d('300'),
          saturatedFatG: _d('3'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['snacks', 'protein-bars'],
    ),
    Food(
      id: 'f_almond_milk',
      createdAt: _daysAgo(66),
      name: 'Almond milk, unsweetened',
      brand: 'Silk',
      barcode: '0025293001428',
      source: FoodSource.off,
      isCustom: false,
      qualityScore: 78,
      nutriscore: NutriscoreGrade.b,
      servings: <Serving>[
        Serving(
          id: 'sv_almond_milk_cup',
          label: '1 cup',
          amount: _d('1'),
          unit: Unit.cup,
          kcal: _d('31'),
          proteinG: _d('1'),
          carbsG: _d('0.7'),
          fatG: _d('2.6'),
          fiberG: _d('1'),
          sugarG: _d('0'),
          sodiumMg: _d('173'),
          saturatedFatG: _d('0.2'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['beverages', 'plant-milks'],
    ),
    Food(
      id: 'f_cliff_bar',
      createdAt: _daysAgo(62),
      name: 'Chocolate chip energy bar',
      brand: 'Clif',
      barcode: '0722252100702',
      source: FoodSource.off,
      isCustom: false,
      qualityScore: 58,
      nutriscore: NutriscoreGrade.c,
      servings: <Serving>[
        Serving(
          id: 'sv_clif_bar',
          label: '1 bar',
          amount: _d('1'),
          unit: Unit.piece,
          kcal: _d('272'),
          proteinG: _d('10.2'),
          carbsG: _d('47.6'),
          fatG: _d('5.6'),
          fiberG: _d('4.6'),
          sugarG: _d('22.6'),
          sodiumMg: _d('170'),
          saturatedFatG: _d('1.2'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['snacks', 'energy-bars'],
    ),
    Food(
      id: 'f_pasta_penne',
      createdAt: _daysAgo(58),
      name: 'Penne rigate, dry',
      brand: 'Barilla',
      barcode: '8076809529433',
      source: FoodSource.off,
      isCustom: false,
      qualityScore: 80,
      nutriscore: NutriscoreGrade.a,
      servings: <Serving>[
        Serving(
          id: 'sv_penne_serving',
          label: '1 serving dry',
          amount: _d('56'),
          unit: Unit.g,
          kcal: _d('200'),
          proteinG: _d('7'),
          carbsG: _d('40'),
          fatG: _d('1'),
          fiberG: _d('2'),
          sugarG: _d('2'),
          sodiumMg: _d('6'),
          saturatedFatG: _d('0.2'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['pastas'],
    ),
    Food(
      id: 'f_dark_chocolate',
      createdAt: _daysAgo(54),
      name: 'Dark chocolate, 70%',
      brand: 'Lindt',
      barcode: '0037466060309',
      source: FoodSource.off,
      isCustom: false,
      qualityScore: 62,
      nutriscore: NutriscoreGrade.d,
      servings: <Serving>[
        Serving(
          id: 'sv_choco_square',
          label: '2 squares',
          amount: _d('20'),
          unit: Unit.g,
          kcal: _d('120'),
          proteinG: _d('1.6'),
          carbsG: _d('9.2'),
          fatG: _d('8.5'),
          fiberG: _d('2.2'),
          sugarG: _d('4.8'),
          sodiumMg: _d('4'),
          saturatedFatG: _d('5.1'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['confectioneries', 'dark-chocolate'],
    ),
    Food(
      id: 'f_olive_oil',
      createdAt: _daysAgo(50),
      name: 'Extra virgin olive oil',
      brand: 'California Olive Ranch',
      barcode: '0850734001057',
      source: FoodSource.off,
      isCustom: false,
      qualityScore: 88,
      nutriscore: NutriscoreGrade.c,
      servings: <Serving>[
        Serving(
          id: 'sv_oo_tbsp',
          label: '1 tbsp',
          amount: _d('1'),
          unit: Unit.tbsp,
          kcal: _d('119'),
          proteinG: _d('0'),
          carbsG: _d('0'),
          fatG: _d('13.5'),
          fiberG: _d('0'),
          sugarG: _d('0'),
          sodiumMg: _d('0.3'),
          saturatedFatG: _d('1.9'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['oils', 'olive-oil'],
    ),
    Food(
      id: 'f_whole_wheat_bread',
      createdAt: _daysAgo(46),
      name: 'Whole wheat bread',
      brand: "Dave's Killer Bread",
      barcode: '0013764000035',
      source: FoodSource.off,
      isCustom: false,
      qualityScore: 75,
      nutriscore: NutriscoreGrade.a,
      servings: <Serving>[
        Serving(
          id: 'sv_bread_slice',
          label: '1 slice',
          amount: _d('1'),
          unit: Unit.piece,
          kcal: _d('120'),
          proteinG: _d('6'),
          carbsG: _d('20'),
          fatG: _d('2'),
          fiberG: _d('4'),
          sugarG: _d('4'),
          sodiumMg: _d('240'),
          saturatedFatG: _d('0'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['breads', 'whole-grain'],
    ),
    Food(
      id: 'f_cottage_cheese',
      createdAt: _daysAgo(42),
      name: 'Low-fat cottage cheese',
      brand: 'Good Culture',
      barcode: '0856769005317',
      source: FoodSource.off,
      isCustom: false,
      qualityScore: 82,
      nutriscore: NutriscoreGrade.b,
      servings: <Serving>[
        Serving(
          id: 'sv_cottage_half_cup',
          label: '1/2 cup',
          amount: _d('0.5'),
          unit: Unit.cup,
          kcal: _d('81'),
          proteinG: _d('15.3'),
          carbsG: _d('4.0'),
          fatG: _d('1.4'),
          fiberG: _d('0'),
          sugarG: _d('4.0'),
          sodiumMg: _d('362'),
          saturatedFatG: _d('0.8'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['dairies', 'cheeses'],
    ),
    Food(
      id: 'f_la_croix',
      createdAt: _daysAgo(38),
      name: 'Sparkling water, grapefruit',
      brand: 'La Croix',
      barcode: '0073360100208',
      source: FoodSource.off,
      isCustom: false,
      qualityScore: 95,
      nutriscore: NutriscoreGrade.a,
      servings: <Serving>[
        Serving(
          id: 'sv_lacroix_can',
          label: '1 can',
          amount: _d('355'),
          unit: Unit.ml,
          kcal: _d('0'),
          proteinG: _d('0'),
          carbsG: _d('0'),
          fatG: _d('0'),
          fiberG: _d('0'),
          sugarG: _d('0'),
          sodiumMg: _d('0'),
          saturatedFatG: _d('0'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['beverages', 'sparkling-water'],
    ),
    // ── USDA (generic / commodity) ─────────────────────────────────
    Food(
      id: 'f_apple_raw',
      createdAt: _daysAgo(36),
      name: 'Apple, raw, with skin',
      source: FoodSource.usda,
      isCustom: false,
      servings: <Serving>[
        Serving(
          id: 'sv_apple_medium',
          label: '1 medium',
          amount: _d('1'),
          unit: Unit.piece,
          kcal: _d('95'),
          proteinG: _d('0.5'),
          carbsG: _d('25.5'),
          fatG: _d('0.4'),
          fiberG: _d('4.4'),
          sugarG: _d('18.9'),
          sodiumMg: _d('2'),
          saturatedFatG: _d('0'),
          isDefault: true,
          source: ServingSource.system,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['fruits'],
    ),
    Food(
      id: 'f_banana_raw',
      createdAt: _daysAgo(34),
      name: 'Banana, raw',
      source: FoodSource.usda,
      isCustom: false,
      servings: <Serving>[
        Serving(
          id: 'sv_banana_medium',
          label: '1 medium',
          amount: _d('1'),
          unit: Unit.piece,
          kcal: _d('105'),
          proteinG: _d('1.3'),
          carbsG: _d('26.9'),
          fatG: _d('0.4'),
          fiberG: _d('3.1'),
          sugarG: _d('14.4'),
          sodiumMg: _d('1'),
          isDefault: true,
          source: ServingSource.system,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['fruits'],
    ),
    Food(
      id: 'f_chicken_breast',
      createdAt: _daysAgo(32),
      name: 'Chicken breast, skinless, cooked',
      source: FoodSource.usda,
      isCustom: false,
      servings: <Serving>[
        Serving(
          id: 'sv_chicken_breast_piece',
          label: '1 breast',
          amount: _d('172'),
          unit: Unit.g,
          kcal: _d('284'),
          proteinG: _d('53.3'),
          carbsG: _d('0'),
          fatG: _d('6.2'),
          fiberG: _d('0'),
          sugarG: _d('0'),
          sodiumMg: _d('127'),
          saturatedFatG: _d('1.7'),
          isDefault: true,
          source: ServingSource.system,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['meats', 'poultry'],
    ),
    Food(
      id: 'f_brown_rice',
      createdAt: _daysAgo(30),
      name: 'Brown rice, cooked',
      source: FoodSource.usda,
      isCustom: false,
      servings: <Serving>[
        Serving(
          id: 'sv_rice_cup',
          label: '1 cup',
          amount: _d('1'),
          unit: Unit.cup,
          kcal: _d('240'),
          proteinG: _d('5.3'),
          carbsG: _d('49.9'),
          fatG: _d('2'),
          fiberG: _d('3.1'),
          sugarG: _d('0.8'),
          sodiumMg: _d('8'),
          saturatedFatG: _d('0.4'),
          isDefault: true,
          source: ServingSource.system,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['grains', 'rice'],
    ),
    Food(
      id: 'f_broccoli',
      createdAt: _daysAgo(28),
      name: 'Broccoli, cooked',
      source: FoodSource.usda,
      isCustom: false,
      servings: <Serving>[
        Serving(
          id: 'sv_broccoli_cup',
          label: '1 cup',
          amount: _d('1'),
          unit: Unit.cup,
          kcal: _d('55'),
          proteinG: _d('3.7'),
          carbsG: _d('11.2'),
          fatG: _d('0.6'),
          fiberG: _d('5.1'),
          sugarG: _d('2.2'),
          sodiumMg: _d('64'),
          isDefault: true,
          source: ServingSource.system,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['vegetables'],
    ),
    Food(
      id: 'f_egg_large',
      createdAt: _daysAgo(26),
      name: 'Egg, whole, cooked',
      source: FoodSource.usda,
      isCustom: false,
      servings: <Serving>[
        Serving(
          id: 'sv_egg_large',
          label: '1 large',
          amount: _d('1'),
          unit: Unit.piece,
          kcal: _d('78'),
          proteinG: _d('6.5'),
          carbsG: _d('0.6'),
          fatG: _d('5.5'),
          fiberG: _d('0'),
          sugarG: _d('0.6'),
          sodiumMg: _d('62'),
          saturatedFatG: _d('1.7'),
          isDefault: true,
          source: ServingSource.system,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['eggs'],
    ),
    Food(
      id: 'f_avocado',
      createdAt: _daysAgo(24),
      name: 'Avocado, raw',
      source: FoodSource.usda,
      isCustom: false,
      servings: <Serving>[
        Serving(
          id: 'sv_avocado_half',
          label: '1/2 fruit',
          amount: _d('100'),
          unit: Unit.g,
          kcal: _d('160'),
          proteinG: _d('2'),
          carbsG: _d('8.5'),
          fatG: _d('14.7'),
          fiberG: _d('6.7'),
          sugarG: _d('0.7'),
          sodiumMg: _d('7'),
          saturatedFatG: _d('2.1'),
          isDefault: true,
          source: ServingSource.system,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['fruits'],
    ),
    Food(
      id: 'f_salmon_atlantic',
      createdAt: _daysAgo(22),
      name: 'Salmon, Atlantic, cooked',
      source: FoodSource.usda,
      isCustom: false,
      servings: <Serving>[
        Serving(
          id: 'sv_salmon_fillet',
          label: '1 fillet',
          amount: _d('170'),
          unit: Unit.g,
          kcal: _d('354'),
          proteinG: _d('37.6'),
          carbsG: _d('0'),
          fatG: _d('22.8'),
          fiberG: _d('0'),
          sugarG: _d('0'),
          sodiumMg: _d('100'),
          saturatedFatG: _d('5.3'),
          isDefault: true,
          source: ServingSource.system,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['seafood', 'fish'],
    ),
    Food(
      id: 'f_spinach_raw',
      createdAt: _daysAgo(20),
      name: 'Spinach, raw',
      source: FoodSource.usda,
      isCustom: false,
      servings: <Serving>[
        Serving(
          id: 'sv_spinach_cup',
          label: '1 cup',
          amount: _d('1'),
          unit: Unit.cup,
          kcal: _d('7'),
          proteinG: _d('0.9'),
          carbsG: _d('1.1'),
          fatG: _d('0.1'),
          fiberG: _d('0.7'),
          sugarG: _d('0.1'),
          sodiumMg: _d('24'),
          saturatedFatG: _d('0'),
          isDefault: true,
          source: ServingSource.system,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['vegetables', 'leafy-greens'],
    ),
    Food(
      id: 'f_almonds',
      createdAt: _daysAgo(18),
      name: 'Almonds, raw',
      source: FoodSource.usda,
      isCustom: false,
      servings: <Serving>[
        Serving(
          id: 'sv_almonds_ounce',
          label: '1 oz',
          amount: _d('1'),
          unit: Unit.oz,
          kcal: _d('162'),
          proteinG: _d('5.9'),
          carbsG: _d('6.0'),
          fatG: _d('14'),
          fiberG: _d('3.5'),
          sugarG: _d('1.2'),
          sodiumMg: _d('0.3'),
          saturatedFatG: _d('1.1'),
          isDefault: true,
          source: ServingSource.system,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['nuts'],
    ),

    // ── User-custom ────────────────────────────────────────────────
    Food(
      id: 'f_moms_lasagna',
      createdAt: _daysAgo(35),
      name: "Mom's lasagna",
      source: FoodSource.user,
      isCustom: true,
      servings: <Serving>[
        Serving(
          id: 'sv_lasagna_slice',
          label: '1 slice',
          amount: _d('220'),
          unit: Unit.g,
          kcal: _d('392'),
          proteinG: _d('23.1'),
          carbsG: _d('31.2'),
          fatG: _d('19.1'),
          fiberG: _d('2.9'),
          sugarG: _d('6.8'),
          sodiumMg: _d('924'),
          saturatedFatG: _d('7.9'),
          isDefault: true,
          source: ServingSource.user,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['user-recipes'],
    ),
    Food(
      id: 'f_home_smoothie',
      createdAt: _daysAgo(14),
      name: 'Home green smoothie',
      source: FoodSource.user,
      isCustom: true,
      servings: <Serving>[
        Serving(
          id: 'sv_smoothie_glass',
          label: '1 large glass',
          amount: _d('450'),
          unit: Unit.ml,
          kcal: _d('279'),
          proteinG: _d('10.8'),
          carbsG: _d('51.8'),
          fatG: _d('5'),
          fiberG: _d('12.2'),
          sugarG: _d('35.1'),
          sodiumMg: _d('203'),
          isDefault: true,
          source: ServingSource.user,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['user-recipes'],
    ),
    Food(
      id: 'f_dad_chili',
      createdAt: _daysAgo(50),
      name: "Dad's turkey chili",
      source: FoodSource.user,
      isCustom: true,
      servings: <Serving>[
        Serving(
          id: 'sv_chili_bowl',
          label: '1 bowl',
          amount: _d('340'),
          unit: Unit.g,
          kcal: _d('350'),
          proteinG: _d('32'),
          carbsG: _d('33'),
          fatG: _d('10.5'),
          fiberG: _d('8.2'),
          sugarG: _d('7.1'),
          sodiumMg: _d('1292'),
          saturatedFatG: _d('3.1'),
          isDefault: true,
          source: ServingSource.user,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['user-recipes'],
    ),
    Food(
      id: 'f_office_coffee',
      createdAt: _daysAgo(7),
      name: 'Office coffee w/ oat milk',
      source: FoodSource.user,
      isCustom: true,
      servings: <Serving>[
        Serving(
          id: 'sv_coffee_mug',
          label: '1 mug',
          amount: _d('350'),
          unit: Unit.ml,
          kcal: _d('53'),
          proteinG: _d('1.4'),
          carbsG: _d('9.1'),
          fatG: _d('1.4'),
          fiberG: _d('0'),
          sugarG: _d('4.9'),
          sodiumMg: _d('49'),
          isDefault: true,
          source: ServingSource.user,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['user-recipes', 'beverages'],
    ),

    // ── Synthetic: Quick add ───────────────────────────────────────
    //
    // Reserves the `food_quick_add` row so the Today header's "Quick
    // add calories" affordance can POST against a real food id. The
    // sentinel serving is `{amount: 1, unit: serving, kcal: 1}` — so
    // a user-typed kcal value rides on the log entry's `quantity`
    // field 1:1 (snapshot kcal = quantity × 1).
    Food(
      id: quickAddFoodId,
      createdAt: _daysAgo(90),
      name: 'Quick add',
      source: FoodSource.user,
      isCustom: false,
      servings: <Serving>[
        Serving(
          id: quickAddServingId,
          label: 'kcal',
          amount: Decimal.one,
          unit: Unit.serving,
          kcal: Decimal.one,
          proteinG: Decimal.zero,
          carbsG: Decimal.zero,
          fatG: Decimal.zero,
          sodiumMg: Decimal.zero,
          isDefault: true,
          source: ServingSource.system,
          sortOrder: 0,
        ),
      ],
      categoriesTags: const <String>['quick-add'],
    ),
  ];
}

// ─── Goal ────────────────────────────────────────────────────────────────

const String mockActiveGoalId = 'g_active_lose';

Goal buildSeedActiveGoal() {
  return Goal(
    id: mockActiveGoalId,
    startedOn: _daysAgo(60),
    endedOn: null,
    startWeightKg: _d('82.4'),
    targetWeightKg: _d('76.0'),
    weeklyRateKg: _d('-0.5'),
    dailyCalorieTarget: 2150,
    proteinTargetG: _d('165'),
    carbsTargetG: _d('215'),
    fatTargetG: _d('70'),
    isActive: true,
    createdAt: _daysAgo(60).add(const Duration(hours: 9)),
    updatedAt: _daysAgo(60).add(const Duration(hours: 9)),
  );
}

Goal buildSeedPreviousGoal() {
  return Goal(
    id: 'g_prior_maintain',
    startedOn: _daysAgo(180),
    endedOn: _daysAgo(61),
    startWeightKg: _d('80.0'),
    targetWeightKg: _d('80.0'),
    weeklyRateKg: Decimal.zero,
    dailyCalorieTarget: 2400,
    proteinTargetG: _d('150'),
    carbsTargetG: _d('260'),
    fatTargetG: _d('80'),
    isActive: false,
    createdAt: _daysAgo(180).add(const Duration(hours: 9)),
    updatedAt: _daysAgo(61).add(const Duration(hours: 9)),
  );
}

// ─── Weight series ───────────────────────────────────────────────────────

List<WeightEntry> buildSeedWeights() {
  final out = <WeightEntry>[];
  const samples = <double>[
    82.1, 82.0, 81.9, 82.1, 81.8, 81.7, 81.5,
    81.6, 81.4, 81.2, 81.0, 81.1, 80.9, 80.8,
    80.7, 80.5, 80.6, 80.4, 80.3, 80.1, 80.2,
    80.0, 79.8, 79.9, 79.7, 79.6, 79.5, 79.6, 79.4, 79.4,
  ];
  for (var i = 0; i < samples.length; i++) {
    final daysAgo = samples.length - 1 - i;
    final date = _daysAgo(daysAgo);
    out.add(
      WeightEntry(
        id: 'w_$i',
        recordedOn: date,
        recordedAtLocal: '07:30:00',
        weightKg: Decimal.parse(samples[i].toStringAsFixed(1)),
        createdAt: date.add(const Duration(hours: 7, minutes: 31)),
      ),
    );
  }
  return out;
}

// ─── Log entries ─────────────────────────────────────────────────────────

class _LogSeed {
  const _LogSeed({
    required this.foodId,
    required this.servingId,
    required this.meal,
    required this.quantity,
    this.note,
  });
  final String foodId;
  final String servingId;
  final Meal meal;
  final Decimal quantity;
  final String? note;
}

List<LogEntry> buildSeedLogEntries(List<Food> foods) {
  Food food(String id) => foods.firstWhere((f) => f.id == id);

  final byDay = <int, List<_LogSeed>>{
    0: <_LogSeed>[
      _LogSeed(
        foodId: 'f_oatmeal_rolled',
        servingId: 'sv_oats_half_cup',
        meal: Meal.breakfast,
        quantity: _d('1'),
        note: 'with almond milk',
      ),
      _LogSeed(
        foodId: 'f_greek_yogurt_plain',
        servingId: 'sv_greek_yogurt_container',
        meal: Meal.breakfast,
        quantity: _d('1'),
      ),
      _LogSeed(
        foodId: 'f_chicken_breast',
        servingId: 'sv_chicken_breast_piece',
        meal: Meal.lunch,
        quantity: _d('1'),
      ),
      _LogSeed(
        foodId: 'f_brown_rice',
        servingId: 'sv_rice_cup',
        meal: Meal.lunch,
        quantity: _d('1'),
      ),
      _LogSeed(
        foodId: 'f_broccoli',
        servingId: 'sv_broccoli_cup',
        meal: Meal.lunch,
        quantity: _d('1'),
      ),
      _LogSeed(
        foodId: 'f_apple_raw',
        servingId: 'sv_apple_medium',
        meal: Meal.snack,
        quantity: _d('1'),
      ),
      _LogSeed(
        foodId: 'f_almonds',
        servingId: 'sv_almonds_ounce',
        meal: Meal.snack,
        quantity: _d('1'),
      ),
      _LogSeed(
        foodId: 'f_salmon_atlantic',
        servingId: 'sv_salmon_fillet',
        meal: Meal.dinner,
        quantity: _d('1'),
      ),
      _LogSeed(
        foodId: 'f_pasta_penne',
        servingId: 'sv_penne_serving',
        meal: Meal.dinner,
        quantity: _d('1.5'),
      ),
      _LogSeed(
        foodId: 'f_olive_oil',
        servingId: 'sv_oo_tbsp',
        meal: Meal.dinner,
        quantity: _d('1'),
      ),
    ],
    1: <_LogSeed>[
      _LogSeed(
        foodId: 'f_oatmeal_rolled',
        servingId: 'sv_oats_half_cup',
        meal: Meal.breakfast,
        quantity: _d('1'),
      ),
      _LogSeed(
        foodId: 'f_banana_raw',
        servingId: 'sv_banana_medium',
        meal: Meal.breakfast,
        quantity: _d('1'),
      ),
      _LogSeed(
        foodId: 'f_moms_lasagna',
        servingId: 'sv_lasagna_slice',
        meal: Meal.dinner,
        quantity: _d('1'),
      ),
      _LogSeed(
        foodId: 'f_dark_chocolate',
        servingId: 'sv_choco_square',
        meal: Meal.snack,
        quantity: _d('1'),
      ),
    ],
    2: <_LogSeed>[
      _LogSeed(
        foodId: 'f_protein_bar',
        servingId: 'sv_quest_bar',
        meal: Meal.breakfast,
        quantity: _d('1'),
      ),
      _LogSeed(
        foodId: 'f_dad_chili',
        servingId: 'sv_chili_bowl',
        meal: Meal.lunch,
        quantity: _d('1'),
      ),
      _LogSeed(
        foodId: 'f_home_smoothie',
        servingId: 'sv_smoothie_glass',
        meal: Meal.snack,
        quantity: _d('1'),
      ),
    ],
    3: <_LogSeed>[
      _LogSeed(
        foodId: 'f_egg_large',
        servingId: 'sv_egg_large',
        meal: Meal.breakfast,
        quantity: _d('2'),
      ),
      _LogSeed(
        foodId: 'f_whole_wheat_bread',
        servingId: 'sv_bread_slice',
        meal: Meal.breakfast,
        quantity: _d('2'),
      ),
      _LogSeed(
        foodId: 'f_chicken_breast',
        servingId: 'sv_chicken_breast_piece',
        meal: Meal.lunch,
        quantity: _d('1'),
      ),
    ],
    4: <_LogSeed>[
      _LogSeed(
        foodId: 'f_cottage_cheese',
        servingId: 'sv_cottage_half_cup',
        meal: Meal.breakfast,
        quantity: _d('1'),
      ),
      _LogSeed(
        foodId: 'f_apple_raw',
        servingId: 'sv_apple_medium',
        meal: Meal.snack,
        quantity: _d('1'),
      ),
    ],
    5: <_LogSeed>[
      _LogSeed(
        foodId: 'f_oatmeal_rolled',
        servingId: 'sv_oats_half_cup',
        meal: Meal.breakfast,
        quantity: _d('1'),
      ),
      _LogSeed(
        foodId: 'f_chicken_breast',
        servingId: 'sv_chicken_breast_piece',
        meal: Meal.lunch,
        quantity: _d('1'),
      ),
      _LogSeed(
        foodId: 'f_avocado',
        servingId: 'sv_avocado_half',
        meal: Meal.lunch,
        quantity: _d('1'),
      ),
      _LogSeed(
        foodId: 'f_dad_chili',
        servingId: 'sv_chili_bowl',
        meal: Meal.dinner,
        quantity: _d('1'),
      ),
    ],
    6: <_LogSeed>[
      _LogSeed(
        foodId: 'f_cliff_bar',
        servingId: 'sv_clif_bar',
        meal: Meal.snack,
        quantity: _d('1'),
      ),
      _LogSeed(
        foodId: 'f_salmon_atlantic',
        servingId: 'sv_salmon_fillet',
        meal: Meal.dinner,
        quantity: _d('1'),
      ),
      _LogSeed(
        foodId: 'f_brown_rice',
        servingId: 'sv_rice_cup',
        meal: Meal.dinner,
        quantity: _d('0.75'),
      ),
    ],
  };

  final out = <LogEntry>[];
  var seq = 0;
  for (final entry in byDay.entries) {
    final daysAgo = entry.key;
    final seeds = entry.value;
    for (final seed in seeds) {
      final f = food(seed.foodId);
      final serv = f.servings.firstWhere((s) => s.id == seed.servingId);
      final hour = _hourForMeal(seed.meal);
      final at = _dayAt(daysAgo, hour, 0 + (seq % 30));
      out.add(
        computeLogEntry(
          id: 'le_${daysAgo}_${seq++}',
          food: f,
          serving: serv,
          consumedOn: DateTime(at.year, at.month, at.day),
          meal: seed.meal,
          quantity: seed.quantity,
          createdAt: at,
          note: seed.note,
        ),
      );
    }
  }
  return out;
}

int _hourForMeal(Meal m) {
  switch (m) {
    case Meal.breakfast:
      return 8;
    case Meal.lunch:
      return 12;
    case Meal.dinner:
      return 19;
    case Meal.snack:
      return 15;
  }
}

/// Build a [LogEntry] with the frozen nutrition snapshot computed from
/// `serving.<nutrient> × quantity`. The math lives on
/// [LogEntry.snapshotFor] (audit finding #7); this thin wrapper is
/// kept so the in-file seed data and `_fixture_log_entries` builders
/// stay readable.
LogEntry computeLogEntry({
  required String id,
  required Food food,
  required Serving serving,
  required DateTime consumedOn,
  required Meal meal,
  required Decimal quantity,
  required DateTime createdAt,
  String? note,
}) =>
    LogEntry.snapshotFor(
      id: id,
      food: food,
      serving: serving,
      consumedOn: consumedOn,
      meal: meal,
      quantity: quantity,
      createdAt: createdAt,
      note: note,
    );

// ─── Day summary builder ─────────────────────────────────────────────────

DaySummary buildDaySummary({
  required DateTime date,
  required List<LogEntry> entriesOnDate,
  required Goal? activeGoal,
}) {
  Decimal kcal = Decimal.zero;
  Decimal protein = Decimal.zero;
  Decimal carbs = Decimal.zero;
  Decimal fat = Decimal.zero;

  final byMeal = <Meal, MealSubtotal>{
    for (final m in Meal.values) m: MealSubtotal.empty(m),
  };

  for (final e in entriesOnDate) {
    kcal = kcal + e.nutritionSnapshot.caloriesKcal;
    protein = protein + (e.nutritionSnapshot.proteinG ?? Decimal.zero);
    carbs = carbs + (e.nutritionSnapshot.carbsG ?? Decimal.zero);
    fat = fat + (e.nutritionSnapshot.fatG ?? Decimal.zero);
    final prev = byMeal[e.meal] ?? MealSubtotal.empty(e.meal);
    byMeal[e.meal] = MealSubtotal(
      meal: e.meal,
      kcal: prev.kcal + e.nutritionSnapshot.caloriesKcal,
      proteinG: prev.proteinG + (e.nutritionSnapshot.proteinG ?? Decimal.zero),
      carbsG: prev.carbsG + (e.nutritionSnapshot.carbsG ?? Decimal.zero),
      fatG: prev.fatG + (e.nutritionSnapshot.fatG ?? Decimal.zero),
      entryCount: prev.entryCount + 1,
    );
  }

  return DaySummary(
    date: date,
    kcal: kcal,
    protein: protein,
    carbs: carbs,
    fat: fat,
    kcalTarget: activeGoal?.dailyCalorieTarget == null
        ? null
        : Decimal.fromInt(activeGoal!.dailyCalorieTarget!),
    proteinTarget: activeGoal?.proteinTargetG,
    carbsTarget: activeGoal?.carbsTargetG,
    fatTarget: activeGoal?.fatTargetG,
    byMeal: byMeal,
    activeGoal: activeGoal,
  );
}

// ─── Weight series builder ───────────────────────────────────────────────

List<WeightSeriesPoint> buildWeightSeries(List<WeightEntry> entries) {
  final sorted = <WeightEntry>[...entries]
    ..sort((a, b) => a.recordedOn.compareTo(b.recordedOn));
  final out = <WeightSeriesPoint>[];
  for (var i = 0; i < sorted.length; i++) {
    Decimal? avg;
    if (i >= 6) {
      var sum = Decimal.zero;
      for (var j = i - 6; j <= i; j++) {
        sum = sum + sorted[j].weightKg;
      }
      avg = (sum / Decimal.fromInt(7))
          .toDecimal(scaleOnInfinitePrecision: 4);
    }
    out.add(
      WeightSeriesPoint(
        date: sorted[i].recordedOn,
        weightKg: sorted[i].weightKg,
        movingAvg7d: avg,
      ),
    );
  }
  return out;
}
