// MOCK ONLY — this entire file is deletable once the real API is wired.
//
// Seed data for the mock repositories, reshaped to Ask 10's per-serving
// nutrition model. Each food has 1+ servings; every serving carries its
// own kcal + macros + an {amount, unit} declaration. No per-100g math.
//
// Audit-fix F2 (partial): the clock + shared helpers used to live at
// the top of this file. They've moved to `_clock.dart` so per-domain
// fixture files (a follow-up split — see the audit's F2 finding for
// `_food_fixtures.dart` / `_log_fixtures.dart` / …) can import only
// what they need without re-declaring the clock seam. Each Decimal
// literal in this file now reads `dec('…')` instead of the previous
// library-private `_d('…')` — same function, public so the future
// split-files can share it. `_daysAgo` / `_dayAt` are likewise now
// the public `daysAgo` / `dayAt` from `_clock.dart`.

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
import '_clock.dart';

// Re-export the clock seam through this file's namespace so existing
// `import '_fixtures.dart' show mockNow, mockToday, …` imports keep
// working without churn. `dec` / `daysAgo` / `dayAt` are also exposed
// since some test fixtures use them directly.
export '_clock.dart';

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
    heightCm: dec('178'),
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
      createdAt: daysAgo(82),
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
          amount: dec('170'),
          unit: Unit.g,
          kcal: dec('100'),
          proteinG: dec('17'),
          carbsG: dec('6.1'),
          fatG: dec('0.7'),
          fiberG: dec('0'),
          sugarG: dec('5.4'),
          sodiumMg: dec('61'),
          saturatedFatG: dec('0.2'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
        Serving(
          id: 'sv_greek_yogurt_cup',
          label: '1 cup',
          amount: dec('1'),
          unit: Unit.cup,
          kcal: dec('145'),
          proteinG: dec('24.5'),
          carbsG: dec('8.8'),
          fatG: dec('1.0'),
          fiberG: dec('0'),
          sugarG: dec('7.8'),
          sodiumMg: dec('88'),
          saturatedFatG: dec('0.2'),
          isDefault: false,
          source: ServingSource.off,
          sortOrder: 2,
        ),
      ],
      categoriesTags: const <String>['dairies', 'yogurts'],
    ),
    Food(
      id: 'f_peanut_butter',
      createdAt: daysAgo(78),
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
          amount: dec('2'),
          unit: Unit.tbsp,
          kcal: dec('192'),
          proteinG: dec('7.1'),
          carbsG: dec('7.1'),
          fatG: dec('16.3'),
          fiberG: dec('1.7'),
          sugarG: dec('2.9'),
          sodiumMg: dec('137'),
          saturatedFatG: dec('3.2'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['spreads', 'nut-butters'],
    ),
    Food(
      id: 'f_oatmeal_rolled',
      createdAt: daysAgo(74),
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
          amount: dec('40'),
          unit: Unit.g,
          kcal: dec('152'),
          proteinG: dec('5.3'),
          carbsG: dec('27.1'),
          fatG: dec('2.6'),
          fiberG: dec('4.0'),
          sugarG: dec('0.4'),
          sodiumMg: dec('2.4'),
          saturatedFatG: dec('0.4'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['cereals', 'oats'],
    ),
    Food(
      id: 'f_protein_bar',
      createdAt: daysAgo(70),
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
          amount: dec('1'),
          unit: Unit.piece,
          kcal: dec('200'),
          proteinG: dec('20'),
          carbsG: dec('24'),
          fatG: dec('8'),
          fiberG: dec('14'),
          sugarG: dec('2'),
          sodiumMg: dec('300'),
          saturatedFatG: dec('3'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['snacks', 'protein-bars'],
    ),
    Food(
      id: 'f_almond_milk',
      createdAt: daysAgo(66),
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
          amount: dec('1'),
          unit: Unit.cup,
          kcal: dec('31'),
          proteinG: dec('1'),
          carbsG: dec('0.7'),
          fatG: dec('2.6'),
          fiberG: dec('1'),
          sugarG: dec('0'),
          sodiumMg: dec('173'),
          saturatedFatG: dec('0.2'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['beverages', 'plant-milks'],
    ),
    Food(
      id: 'f_cliff_bar',
      createdAt: daysAgo(62),
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
          amount: dec('1'),
          unit: Unit.piece,
          kcal: dec('272'),
          proteinG: dec('10.2'),
          carbsG: dec('47.6'),
          fatG: dec('5.6'),
          fiberG: dec('4.6'),
          sugarG: dec('22.6'),
          sodiumMg: dec('170'),
          saturatedFatG: dec('1.2'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['snacks', 'energy-bars'],
    ),
    Food(
      id: 'f_pasta_penne',
      createdAt: daysAgo(58),
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
          amount: dec('56'),
          unit: Unit.g,
          kcal: dec('200'),
          proteinG: dec('7'),
          carbsG: dec('40'),
          fatG: dec('1'),
          fiberG: dec('2'),
          sugarG: dec('2'),
          sodiumMg: dec('6'),
          saturatedFatG: dec('0.2'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['pastas'],
    ),
    Food(
      id: 'f_dark_chocolate',
      createdAt: daysAgo(54),
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
          amount: dec('20'),
          unit: Unit.g,
          kcal: dec('120'),
          proteinG: dec('1.6'),
          carbsG: dec('9.2'),
          fatG: dec('8.5'),
          fiberG: dec('2.2'),
          sugarG: dec('4.8'),
          sodiumMg: dec('4'),
          saturatedFatG: dec('5.1'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['confectioneries', 'dark-chocolate'],
    ),
    Food(
      id: 'f_olive_oil',
      createdAt: daysAgo(50),
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
          amount: dec('1'),
          unit: Unit.tbsp,
          kcal: dec('119'),
          proteinG: dec('0'),
          carbsG: dec('0'),
          fatG: dec('13.5'),
          fiberG: dec('0'),
          sugarG: dec('0'),
          sodiumMg: dec('0.3'),
          saturatedFatG: dec('1.9'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['oils', 'olive-oil'],
    ),
    Food(
      id: 'f_whole_wheat_bread',
      createdAt: daysAgo(46),
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
          amount: dec('1'),
          unit: Unit.piece,
          kcal: dec('120'),
          proteinG: dec('6'),
          carbsG: dec('20'),
          fatG: dec('2'),
          fiberG: dec('4'),
          sugarG: dec('4'),
          sodiumMg: dec('240'),
          saturatedFatG: dec('0'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['breads', 'whole-grain'],
    ),
    Food(
      id: 'f_cottage_cheese',
      createdAt: daysAgo(42),
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
          amount: dec('0.5'),
          unit: Unit.cup,
          kcal: dec('81'),
          proteinG: dec('15.3'),
          carbsG: dec('4.0'),
          fatG: dec('1.4'),
          fiberG: dec('0'),
          sugarG: dec('4.0'),
          sodiumMg: dec('362'),
          saturatedFatG: dec('0.8'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['dairies', 'cheeses'],
    ),
    Food(
      id: 'f_la_croix',
      createdAt: daysAgo(38),
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
          amount: dec('355'),
          unit: Unit.ml,
          kcal: dec('0'),
          proteinG: dec('0'),
          carbsG: dec('0'),
          fatG: dec('0'),
          fiberG: dec('0'),
          sugarG: dec('0'),
          sodiumMg: dec('0'),
          saturatedFatG: dec('0'),
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
      createdAt: daysAgo(36),
      name: 'Apple, raw, with skin',
      source: FoodSource.usda,
      isCustom: false,
      servings: <Serving>[
        Serving(
          id: 'sv_apple_medium',
          label: '1 medium',
          amount: dec('1'),
          unit: Unit.piece,
          kcal: dec('95'),
          proteinG: dec('0.5'),
          carbsG: dec('25.5'),
          fatG: dec('0.4'),
          fiberG: dec('4.4'),
          sugarG: dec('18.9'),
          sodiumMg: dec('2'),
          saturatedFatG: dec('0'),
          isDefault: true,
          source: ServingSource.system,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['fruits'],
    ),
    Food(
      id: 'f_banana_raw',
      createdAt: daysAgo(34),
      name: 'Banana, raw',
      source: FoodSource.usda,
      isCustom: false,
      servings: <Serving>[
        Serving(
          id: 'sv_banana_medium',
          label: '1 medium',
          amount: dec('1'),
          unit: Unit.piece,
          kcal: dec('105'),
          proteinG: dec('1.3'),
          carbsG: dec('26.9'),
          fatG: dec('0.4'),
          fiberG: dec('3.1'),
          sugarG: dec('14.4'),
          sodiumMg: dec('1'),
          isDefault: true,
          source: ServingSource.system,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['fruits'],
    ),
    Food(
      id: 'f_chicken_breast',
      createdAt: daysAgo(32),
      name: 'Chicken breast, skinless, cooked',
      source: FoodSource.usda,
      isCustom: false,
      servings: <Serving>[
        Serving(
          id: 'sv_chicken_breast_piece',
          label: '1 breast',
          amount: dec('172'),
          unit: Unit.g,
          kcal: dec('284'),
          proteinG: dec('53.3'),
          carbsG: dec('0'),
          fatG: dec('6.2'),
          fiberG: dec('0'),
          sugarG: dec('0'),
          sodiumMg: dec('127'),
          saturatedFatG: dec('1.7'),
          isDefault: true,
          source: ServingSource.system,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['meats', 'poultry'],
    ),
    Food(
      id: 'f_brown_rice',
      createdAt: daysAgo(30),
      name: 'Brown rice, cooked',
      source: FoodSource.usda,
      isCustom: false,
      servings: <Serving>[
        Serving(
          id: 'sv_rice_cup',
          label: '1 cup',
          amount: dec('1'),
          unit: Unit.cup,
          kcal: dec('240'),
          proteinG: dec('5.3'),
          carbsG: dec('49.9'),
          fatG: dec('2'),
          fiberG: dec('3.1'),
          sugarG: dec('0.8'),
          sodiumMg: dec('8'),
          saturatedFatG: dec('0.4'),
          isDefault: true,
          source: ServingSource.system,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['grains', 'rice'],
    ),
    Food(
      id: 'f_broccoli',
      createdAt: daysAgo(28),
      name: 'Broccoli, cooked',
      source: FoodSource.usda,
      isCustom: false,
      servings: <Serving>[
        Serving(
          id: 'sv_broccoli_cup',
          label: '1 cup',
          amount: dec('1'),
          unit: Unit.cup,
          kcal: dec('55'),
          proteinG: dec('3.7'),
          carbsG: dec('11.2'),
          fatG: dec('0.6'),
          fiberG: dec('5.1'),
          sugarG: dec('2.2'),
          sodiumMg: dec('64'),
          isDefault: true,
          source: ServingSource.system,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['vegetables'],
    ),
    Food(
      id: 'f_egg_large',
      createdAt: daysAgo(26),
      name: 'Egg, whole, cooked',
      source: FoodSource.usda,
      isCustom: false,
      servings: <Serving>[
        Serving(
          id: 'sv_egg_large',
          label: '1 large',
          amount: dec('1'),
          unit: Unit.piece,
          kcal: dec('78'),
          proteinG: dec('6.5'),
          carbsG: dec('0.6'),
          fatG: dec('5.5'),
          fiberG: dec('0'),
          sugarG: dec('0.6'),
          sodiumMg: dec('62'),
          saturatedFatG: dec('1.7'),
          isDefault: true,
          source: ServingSource.system,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['eggs'],
    ),
    Food(
      id: 'f_avocado',
      createdAt: daysAgo(24),
      name: 'Avocado, raw',
      source: FoodSource.usda,
      isCustom: false,
      servings: <Serving>[
        Serving(
          id: 'sv_avocado_half',
          label: '1/2 fruit',
          amount: dec('100'),
          unit: Unit.g,
          kcal: dec('160'),
          proteinG: dec('2'),
          carbsG: dec('8.5'),
          fatG: dec('14.7'),
          fiberG: dec('6.7'),
          sugarG: dec('0.7'),
          sodiumMg: dec('7'),
          saturatedFatG: dec('2.1'),
          isDefault: true,
          source: ServingSource.system,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['fruits'],
    ),
    Food(
      id: 'f_salmon_atlantic',
      createdAt: daysAgo(22),
      name: 'Salmon, Atlantic, cooked',
      source: FoodSource.usda,
      isCustom: false,
      servings: <Serving>[
        Serving(
          id: 'sv_salmon_fillet',
          label: '1 fillet',
          amount: dec('170'),
          unit: Unit.g,
          kcal: dec('354'),
          proteinG: dec('37.6'),
          carbsG: dec('0'),
          fatG: dec('22.8'),
          fiberG: dec('0'),
          sugarG: dec('0'),
          sodiumMg: dec('100'),
          saturatedFatG: dec('5.3'),
          isDefault: true,
          source: ServingSource.system,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['seafood', 'fish'],
    ),
    Food(
      id: 'f_spinach_raw',
      createdAt: daysAgo(20),
      name: 'Spinach, raw',
      source: FoodSource.usda,
      isCustom: false,
      servings: <Serving>[
        Serving(
          id: 'sv_spinach_cup',
          label: '1 cup',
          amount: dec('1'),
          unit: Unit.cup,
          kcal: dec('7'),
          proteinG: dec('0.9'),
          carbsG: dec('1.1'),
          fatG: dec('0.1'),
          fiberG: dec('0.7'),
          sugarG: dec('0.1'),
          sodiumMg: dec('24'),
          saturatedFatG: dec('0'),
          isDefault: true,
          source: ServingSource.system,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['vegetables', 'leafy-greens'],
    ),
    Food(
      id: 'f_almonds',
      createdAt: daysAgo(18),
      name: 'Almonds, raw',
      source: FoodSource.usda,
      isCustom: false,
      servings: <Serving>[
        Serving(
          id: 'sv_almonds_ounce',
          label: '1 oz',
          amount: dec('1'),
          unit: Unit.oz,
          kcal: dec('162'),
          proteinG: dec('5.9'),
          carbsG: dec('6.0'),
          fatG: dec('14'),
          fiberG: dec('3.5'),
          sugarG: dec('1.2'),
          sodiumMg: dec('0.3'),
          saturatedFatG: dec('1.1'),
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
      createdAt: daysAgo(35),
      name: "Mom's lasagna",
      source: FoodSource.user,
      isCustom: true,
      servings: <Serving>[
        Serving(
          id: 'sv_lasagna_slice',
          label: '1 slice',
          amount: dec('220'),
          unit: Unit.g,
          kcal: dec('392'),
          proteinG: dec('23.1'),
          carbsG: dec('31.2'),
          fatG: dec('19.1'),
          fiberG: dec('2.9'),
          sugarG: dec('6.8'),
          sodiumMg: dec('924'),
          saturatedFatG: dec('7.9'),
          isDefault: true,
          source: ServingSource.user,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['user-recipes'],
    ),
    Food(
      id: 'f_home_smoothie',
      createdAt: daysAgo(14),
      name: 'Home green smoothie',
      source: FoodSource.user,
      isCustom: true,
      servings: <Serving>[
        Serving(
          id: 'sv_smoothie_glass',
          label: '1 large glass',
          amount: dec('450'),
          unit: Unit.ml,
          kcal: dec('279'),
          proteinG: dec('10.8'),
          carbsG: dec('51.8'),
          fatG: dec('5'),
          fiberG: dec('12.2'),
          sugarG: dec('35.1'),
          sodiumMg: dec('203'),
          isDefault: true,
          source: ServingSource.user,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['user-recipes'],
    ),
    Food(
      id: 'f_dad_chili',
      createdAt: daysAgo(50),
      name: "Dad's turkey chili",
      source: FoodSource.user,
      isCustom: true,
      servings: <Serving>[
        Serving(
          id: 'sv_chili_bowl',
          label: '1 bowl',
          amount: dec('340'),
          unit: Unit.g,
          kcal: dec('350'),
          proteinG: dec('32'),
          carbsG: dec('33'),
          fatG: dec('10.5'),
          fiberG: dec('8.2'),
          sugarG: dec('7.1'),
          sodiumMg: dec('1292'),
          saturatedFatG: dec('3.1'),
          isDefault: true,
          source: ServingSource.user,
          sortOrder: 1,
        ),
      ],
      categoriesTags: const <String>['user-recipes'],
    ),
    Food(
      id: 'f_office_coffee',
      createdAt: daysAgo(7),
      name: 'Office coffee w/ oat milk',
      source: FoodSource.user,
      isCustom: true,
      servings: <Serving>[
        Serving(
          id: 'sv_coffee_mug',
          label: '1 mug',
          amount: dec('350'),
          unit: Unit.ml,
          kcal: dec('53'),
          proteinG: dec('1.4'),
          carbsG: dec('9.1'),
          fatG: dec('1.4'),
          fiberG: dec('0'),
          sugarG: dec('4.9'),
          sodiumMg: dec('49'),
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
      createdAt: daysAgo(90),
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
    startedOn: daysAgo(60),
    endedOn: null,
    startWeightKg: dec('82.4'),
    targetWeightKg: dec('76.0'),
    weeklyRateKg: dec('-0.5'),
    dailyCalorieTarget: 2150,
    proteinTargetG: dec('165'),
    carbsTargetG: dec('215'),
    fatTargetG: dec('70'),
    isActive: true,
    createdAt: daysAgo(60).add(const Duration(hours: 9)),
    updatedAt: daysAgo(60).add(const Duration(hours: 9)),
  );
}

Goal buildSeedPreviousGoal() {
  return Goal(
    id: 'g_prior_maintain',
    startedOn: daysAgo(180),
    endedOn: daysAgo(61),
    startWeightKg: dec('80.0'),
    targetWeightKg: dec('80.0'),
    weeklyRateKg: Decimal.zero,
    dailyCalorieTarget: 2400,
    proteinTargetG: dec('150'),
    carbsTargetG: dec('260'),
    fatTargetG: dec('80'),
    isActive: false,
    createdAt: daysAgo(180).add(const Duration(hours: 9)),
    updatedAt: daysAgo(61).add(const Duration(hours: 9)),
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
    final dayOffset = samples.length - 1 - i;
    final date = daysAgo(dayOffset);
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
        quantity: dec('1'),
        note: 'with almond milk',
      ),
      _LogSeed(
        foodId: 'f_greek_yogurt_plain',
        servingId: 'sv_greek_yogurt_container',
        meal: Meal.breakfast,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_chicken_breast',
        servingId: 'sv_chicken_breast_piece',
        meal: Meal.lunch,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_brown_rice',
        servingId: 'sv_rice_cup',
        meal: Meal.lunch,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_broccoli',
        servingId: 'sv_broccoli_cup',
        meal: Meal.lunch,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_apple_raw',
        servingId: 'sv_apple_medium',
        meal: Meal.snack,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_almonds',
        servingId: 'sv_almonds_ounce',
        meal: Meal.snack,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_salmon_atlantic',
        servingId: 'sv_salmon_fillet',
        meal: Meal.dinner,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_pasta_penne',
        servingId: 'sv_penne_serving',
        meal: Meal.dinner,
        quantity: dec('1.5'),
      ),
      _LogSeed(
        foodId: 'f_olive_oil',
        servingId: 'sv_oo_tbsp',
        meal: Meal.dinner,
        quantity: dec('1'),
      ),
    ],
    1: <_LogSeed>[
      _LogSeed(
        foodId: 'f_oatmeal_rolled',
        servingId: 'sv_oats_half_cup',
        meal: Meal.breakfast,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_banana_raw',
        servingId: 'sv_banana_medium',
        meal: Meal.breakfast,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_moms_lasagna',
        servingId: 'sv_lasagna_slice',
        meal: Meal.dinner,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_dark_chocolate',
        servingId: 'sv_choco_square',
        meal: Meal.snack,
        quantity: dec('1'),
      ),
    ],
    2: <_LogSeed>[
      _LogSeed(
        foodId: 'f_protein_bar',
        servingId: 'sv_quest_bar',
        meal: Meal.breakfast,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_dad_chili',
        servingId: 'sv_chili_bowl',
        meal: Meal.lunch,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_home_smoothie',
        servingId: 'sv_smoothie_glass',
        meal: Meal.snack,
        quantity: dec('1'),
      ),
    ],
    3: <_LogSeed>[
      _LogSeed(
        foodId: 'f_egg_large',
        servingId: 'sv_egg_large',
        meal: Meal.breakfast,
        quantity: dec('2'),
      ),
      _LogSeed(
        foodId: 'f_whole_wheat_bread',
        servingId: 'sv_bread_slice',
        meal: Meal.breakfast,
        quantity: dec('2'),
      ),
      _LogSeed(
        foodId: 'f_chicken_breast',
        servingId: 'sv_chicken_breast_piece',
        meal: Meal.lunch,
        quantity: dec('1'),
      ),
    ],
    4: <_LogSeed>[
      _LogSeed(
        foodId: 'f_cottage_cheese',
        servingId: 'sv_cottage_half_cup',
        meal: Meal.breakfast,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_apple_raw',
        servingId: 'sv_apple_medium',
        meal: Meal.snack,
        quantity: dec('1'),
      ),
    ],
    5: <_LogSeed>[
      _LogSeed(
        foodId: 'f_oatmeal_rolled',
        servingId: 'sv_oats_half_cup',
        meal: Meal.breakfast,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_chicken_breast',
        servingId: 'sv_chicken_breast_piece',
        meal: Meal.lunch,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_avocado',
        servingId: 'sv_avocado_half',
        meal: Meal.lunch,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_dad_chili',
        servingId: 'sv_chili_bowl',
        meal: Meal.dinner,
        quantity: dec('1'),
      ),
    ],
    6: <_LogSeed>[
      _LogSeed(
        foodId: 'f_cliff_bar',
        servingId: 'sv_clif_bar',
        meal: Meal.snack,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_salmon_atlantic',
        servingId: 'sv_salmon_fillet',
        meal: Meal.dinner,
        quantity: dec('1'),
      ),
      _LogSeed(
        foodId: 'f_brown_rice',
        servingId: 'sv_rice_cup',
        meal: Meal.dinner,
        quantity: dec('0.75'),
      ),
    ],
  };

  final out = <LogEntry>[];
  var seq = 0;
  for (final entry in byDay.entries) {
    final dayOffset = entry.key;
    final seeds = entry.value;
    for (final seed in seeds) {
      final f = food(seed.foodId);
      final serv = f.servings.firstWhere((s) => s.id == seed.servingId);
      final hour = _hourForMeal(seed.meal);
      final at = dayAt(dayOffset, hour, 0 + (seq % 30));
      out.add(
        computeLogEntry(
          id: 'le_${dayOffset}_${seq++}',
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
