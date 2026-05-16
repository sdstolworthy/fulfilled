// MOCK ONLY — this entire file is deletable once the real API is wired.
//
// Seed data for the mock repositories. The numbers are realistic enough to
// drive every screen (the day view's ring, the meal sections, the weight
// sparkline, the goal hero, etc.) without anyone being startled by a
// number that doesn't make sense for a real human. They are not, however,
// stable enough to assert on in screen-level golden tests — anything that
// pins the entire seed in place will need updating when the real API
// lands.
//
// The data references the "today" anchor returned by [mockToday]; every
// date-shaped fixture is relative to it so the day view always has data
// for the date the user sees. Tests that need a deterministic clock
// override [_clockOverride] via [setMockClockForTesting].

import 'package:decimal/decimal.dart';

import '../domain/day_summary.dart';
import '../domain/enums.dart';
import '../domain/food.dart';
import '../domain/goal.dart';
import '../domain/log_entry.dart';
import '../domain/meal.dart';
import '../domain/nutrition.dart';
import '../domain/serving.dart';
import '../domain/user.dart';
import '../domain/weight.dart';

/// Test-controllable clock. Production callers see real "now".
DateTime Function()? _clockOverride;

/// `DateTime.now()` for fixtures. Default is local now; tests inject a
/// fixed clock to keep the seed deterministic.
DateTime mockNow() => (_clockOverride ?? DateTime.now)();

/// Today, midnight local — the anchor for every date-shaped fixture
/// below. Stripping the time component matches the wire's `YYYY-MM-DD`
/// convention (T-16: dates are local-calendar, not UTC).
DateTime mockToday() {
  final n = mockNow();
  return DateTime(n.year, n.month, n.day);
}

/// Override for tests. Pass `null` to restore real `DateTime.now`.
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
  int customFoodCount = 0,
  Decimal? currentWeightKg,
  WeightUnit weightUnit = WeightUnit.kg,
}) {
  return User(
    id: mockUserId,
    displayName: 'Sam Reyes',
    email: 'sam@example.com',
    sex: Sex.male,
    birthDate: DateTime(1993, 4, 12),
    heightCm: _d('178'),
    currentWeightKg: currentWeightKg ?? _d('79.4'),
    activityLevel: ActivityLevel.moderate,
    customFoodCount: customFoodCount,
    createdAt: DateTime(2026, 1, 5, 9, 0),
    updatedAt: DateTime(2026, 5, 12, 8, 30),
    weightUnit: weightUnit,
  );
}

// ─── Foods ───────────────────────────────────────────────────────────────
//
// Each food carries:
//   - a stable `id` (used by log entries below; do not renumber)
//   - per-100 g nutrition (sodium in mg on the presentation model)
//   - servings, exactly one of which has `isDefault = true`
//   - one synthetic 100 g `ServingSource.system` serving (T-10)
//
// The mix is intentional: ~12 OFF, ~9 USDA, 4 user — 25 total — enough
// to show source variety in `SearchResultRow` and the "My foods · N"
// row on screen 08.
//
// **Quick-add synthetic food** (`food_quick_add`). The "Quick add
// calories" affordance on the Today header logs raw kcal without
// scanning a real food. To reuse the existing `LogCreate` path we mint
// a synthetic food whose per-100 g panel is exactly 100 kcal — its
// one serving (`sv_kcal`) is 1 g, so the existing log math collapses
// to `quantity == kcal value`. We piggy-back on `FoodSource.user`
// because no `synthetic` variant exists yet (and PM ruled we don't add
// one for v1); `FoodRepository.customFoods` and `customCount`
// explicitly skip this id so it never surfaces in "My foods".

/// Stable id of the synthetic Quick-add food. Referenced from the Today
/// header's quick-add sheet and from `FoodRepository`'s My-foods filter.
const String quickAddFoodId = 'food_quick_add';

/// Stable id of the synthetic 1 g `kcal` serving on the Quick-add food.
const String quickAddServingId = 'sv_kcal';

Serving _systemHundredG(String id) => Serving(
      id: id,
      name: '100 g',
      grams: _d('100'),
      isDefault: false,
      source: ServingSource.system,
      sortOrder: 100,
    );

List<Food> buildSeedFoods() {
  return <Food>[
    // ── OFF (branded, off-shelf) ──
    Food(
      id: 'f_greek_yogurt_plain',
      name: 'Greek yogurt, plain',
      brand: 'Fage',
      barcode: '8410076473203',
      source: FoodSource.off,
      isCustom: false,
      qualityScore: 86,
      nutriscore: NutriscoreGrade.b,
      nutritionPer100g: NutritionPer100g(
        energyKcal: _d('59'),
        proteinG: _d('10'),
        carbsG: _d('3.6'),
        fatG: _d('0.4'),
        fiberG: _d('0'),
        sugarG: _d('3.2'),
        sodiumMg: _d('36'),
        saturatedFatG: _d('0.1'),
      ),
      servings: <Serving>[
        Serving(
          id: 'sv_greek_yogurt_container',
          name: '1 container (170 g)',
          grams: _d('170'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
        Serving(
          id: 'sv_greek_yogurt_cup',
          name: '1 cup (245 g)',
          grams: _d('245'),
          isDefault: false,
          source: ServingSource.off,
          sortOrder: 2,
        ),
        _systemHundredG('sv_greek_yogurt_100g'),
      ],
      categoriesTags: const <String>['dairies', 'yogurts'],
    ),
    Food(
      id: 'f_peanut_butter',
      name: 'Peanut butter, smooth',
      brand: 'Skippy',
      barcode: '0037600138307',
      source: FoodSource.off,
      isCustom: false,
      qualityScore: 71,
      nutriscore: NutriscoreGrade.c,
      nutritionPer100g: NutritionPer100g(
        energyKcal: _d('598'),
        proteinG: _d('22.2'),
        carbsG: _d('22.3'),
        fatG: _d('51'),
        fiberG: _d('5.3'),
        sugarG: _d('9.2'),
        sodiumMg: _d('429'),
        saturatedFatG: _d('10'),
      ),
      servings: <Serving>[
        Serving(
          id: 'sv_pb_tbsp',
          name: '2 tbsp (32 g)',
          grams: _d('32'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
        _systemHundredG('sv_pb_100g'),
      ],
      categoriesTags: const <String>['spreads', 'nut-butters'],
    ),
    Food(
      id: 'f_oatmeal_rolled',
      name: 'Rolled oats',
      brand: 'Quaker',
      barcode: '0030000010402',
      source: FoodSource.off,
      isCustom: false,
      qualityScore: 91,
      nutriscore: NutriscoreGrade.a,
      nutritionPer100g: NutritionPer100g(
        energyKcal: _d('379'),
        proteinG: _d('13.2'),
        carbsG: _d('67.7'),
        fatG: _d('6.5'),
        fiberG: _d('10.1'),
        sugarG: _d('0.9'),
        sodiumMg: _d('6'),
        saturatedFatG: _d('1.1'),
      ),
      servings: <Serving>[
        Serving(
          id: 'sv_oats_half_cup',
          name: '1/2 cup dry (40 g)',
          grams: _d('40'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
        _systemHundredG('sv_oats_100g'),
      ],
      categoriesTags: const <String>['cereals', 'oats'],
    ),
    Food(
      id: 'f_protein_bar',
      name: 'Chocolate chip cookie dough protein bar',
      brand: 'Quest',
      barcode: '0888849000043',
      source: FoodSource.off,
      isCustom: false,
      qualityScore: 64,
      nutriscore: NutriscoreGrade.c,
      nutritionPer100g: NutritionPer100g(
        energyKcal: _d('333'),
        proteinG: _d('33.3'),
        carbsG: _d('40'),
        fatG: _d('13.3'),
        fiberG: _d('23.3'),
        sugarG: _d('3.3'),
        sodiumMg: _d('500'),
        saturatedFatG: _d('5'),
      ),
      servings: <Serving>[
        Serving(
          id: 'sv_quest_bar',
          name: '1 bar (60 g)',
          grams: _d('60'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
        _systemHundredG('sv_quest_100g'),
      ],
      categoriesTags: const <String>['snacks', 'protein-bars'],
    ),
    Food(
      id: 'f_almond_milk',
      name: 'Almond milk, unsweetened',
      brand: 'Silk',
      barcode: '0025293001428',
      source: FoodSource.off,
      isCustom: false,
      qualityScore: 78,
      nutriscore: NutriscoreGrade.b,
      nutritionPer100g: NutritionPer100g(
        energyKcal: _d('13'),
        proteinG: _d('0.4'),
        carbsG: _d('0.3'),
        fatG: _d('1.1'),
        fiberG: _d('0.4'),
        sugarG: _d('0'),
        sodiumMg: _d('72'),
        saturatedFatG: _d('0.1'),
      ),
      servings: <Serving>[
        Serving(
          id: 'sv_almond_milk_cup',
          name: '1 cup (240 ml ≈ 240 g)',
          grams: _d('240'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
        _systemHundredG('sv_almond_milk_100g'),
      ],
      categoriesTags: const <String>['beverages', 'plant-milks'],
    ),
    Food(
      id: 'f_cliff_bar',
      name: 'Chocolate chip energy bar',
      brand: 'Clif',
      barcode: '0722252100702',
      source: FoodSource.off,
      isCustom: false,
      qualityScore: 58,
      nutriscore: NutriscoreGrade.c,
      nutritionPer100g: NutritionPer100g(
        energyKcal: _d('400'),
        proteinG: _d('15'),
        carbsG: _d('70'),
        fatG: _d('8.3'),
        fiberG: _d('6.7'),
        sugarG: _d('33.3'),
        sodiumMg: _d('250'),
        saturatedFatG: _d('1.7'),
      ),
      servings: <Serving>[
        Serving(
          id: 'sv_clif_bar',
          name: '1 bar (68 g)',
          grams: _d('68'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
        _systemHundredG('sv_clif_100g'),
      ],
      categoriesTags: const <String>['snacks', 'energy-bars'],
    ),
    Food(
      id: 'f_pasta_penne',
      name: 'Penne rigate, dry',
      brand: 'Barilla',
      barcode: '8076809529433',
      source: FoodSource.off,
      isCustom: false,
      qualityScore: 80,
      nutriscore: NutriscoreGrade.a,
      nutritionPer100g: NutritionPer100g(
        energyKcal: _d('357'),
        proteinG: _d('12.5'),
        carbsG: _d('71.4'),
        fatG: _d('1.8'),
        fiberG: _d('3.6'),
        sugarG: _d('3.6'),
        sodiumMg: _d('11'),
        saturatedFatG: _d('0.4'),
      ),
      servings: <Serving>[
        Serving(
          id: 'sv_penne_serving',
          name: '1 serving dry (56 g)',
          grams: _d('56'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
        _systemHundredG('sv_penne_100g'),
      ],
      categoriesTags: const <String>['pastas'],
    ),
    Food(
      id: 'f_dark_chocolate',
      name: 'Dark chocolate, 70%',
      brand: "Lindt",
      barcode: '0037466060309',
      source: FoodSource.off,
      isCustom: false,
      qualityScore: 62,
      nutriscore: NutriscoreGrade.d,
      nutritionPer100g: NutritionPer100g(
        energyKcal: _d('598'),
        proteinG: _d('7.8'),
        carbsG: _d('45.9'),
        fatG: _d('42.6'),
        fiberG: _d('10.9'),
        sugarG: _d('24'),
        sodiumMg: _d('20'),
        saturatedFatG: _d('25.6'),
      ),
      servings: <Serving>[
        Serving(
          id: 'sv_choco_square',
          name: '2 squares (20 g)',
          grams: _d('20'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
        _systemHundredG('sv_choco_100g'),
      ],
      categoriesTags: const <String>['confectioneries', 'dark-chocolate'],
    ),
    Food(
      id: 'f_olive_oil',
      name: 'Extra virgin olive oil',
      brand: 'California Olive Ranch',
      barcode: '0850734001057',
      source: FoodSource.off,
      isCustom: false,
      qualityScore: 88,
      nutriscore: NutriscoreGrade.c,
      nutritionPer100g: NutritionPer100g(
        energyKcal: _d('884'),
        proteinG: _d('0'),
        carbsG: _d('0'),
        fatG: _d('100'),
        fiberG: _d('0'),
        sugarG: _d('0'),
        sodiumMg: _d('2'),
        saturatedFatG: _d('13.8'),
      ),
      servings: <Serving>[
        Serving(
          id: 'sv_oo_tbsp',
          name: '1 tbsp (13.5 g)',
          grams: _d('13.5'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
        _systemHundredG('sv_oo_100g'),
      ],
      categoriesTags: const <String>['oils', 'olive-oil'],
    ),
    Food(
      id: 'f_whole_wheat_bread',
      name: 'Whole wheat bread',
      brand: "Dave's Killer Bread",
      barcode: '0013764000035',
      source: FoodSource.off,
      isCustom: false,
      qualityScore: 75,
      nutriscore: NutriscoreGrade.a,
      nutritionPer100g: NutritionPer100g(
        energyKcal: _d('250'),
        proteinG: _d('12.5'),
        carbsG: _d('41.7'),
        fatG: _d('4.2'),
        fiberG: _d('8.3'),
        sugarG: _d('8.3'),
        sodiumMg: _d('500'),
        saturatedFatG: _d('0'),
      ),
      servings: <Serving>[
        Serving(
          id: 'sv_bread_slice',
          name: '1 slice (48 g)',
          grams: _d('48'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
        _systemHundredG('sv_bread_100g'),
      ],
      categoriesTags: const <String>['breads', 'whole-grain'],
    ),
    Food(
      id: 'f_cottage_cheese',
      name: 'Low-fat cottage cheese',
      brand: 'Good Culture',
      barcode: '0856769005317',
      source: FoodSource.off,
      isCustom: false,
      qualityScore: 82,
      nutriscore: NutriscoreGrade.b,
      nutritionPer100g: NutritionPer100g(
        energyKcal: _d('72'),
        proteinG: _d('13.5'),
        carbsG: _d('3.5'),
        fatG: _d('1.2'),
        fiberG: _d('0'),
        sugarG: _d('3.5'),
        sodiumMg: _d('320'),
        saturatedFatG: _d('0.7'),
      ),
      servings: <Serving>[
        Serving(
          id: 'sv_cottage_half_cup',
          name: '1/2 cup (113 g)',
          grams: _d('113'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
        _systemHundredG('sv_cottage_100g'),
      ],
      categoriesTags: const <String>['dairies', 'cheeses'],
    ),
    Food(
      id: 'f_la_croix',
      name: 'Sparkling water, grapefruit',
      brand: 'La Croix',
      barcode: '0073360100208',
      source: FoodSource.off,
      isCustom: false,
      qualityScore: 95,
      nutriscore: NutriscoreGrade.a,
      nutritionPer100g: NutritionPer100g(
        energyKcal: _d('0'),
        proteinG: _d('0'),
        carbsG: _d('0'),
        fatG: _d('0'),
        fiberG: _d('0'),
        sugarG: _d('0'),
        sodiumMg: _d('0'),
        saturatedFatG: _d('0'),
      ),
      servings: <Serving>[
        Serving(
          id: 'sv_lacroix_can',
          name: '1 can (355 ml)',
          grams: _d('355'),
          isDefault: true,
          source: ServingSource.off,
          sortOrder: 1,
        ),
        _systemHundredG('sv_lacroix_100g'),
      ],
      categoriesTags: const <String>['beverages', 'sparkling-water'],
    ),
    // ── USDA (generic / commodity) ──
    Food(
      id: 'f_apple_raw',
      name: 'Apple, raw, with skin',
      brand: null,
      barcode: null,
      source: FoodSource.usda,
      isCustom: false,
      qualityScore: null,
      nutriscore: null,
      nutritionPer100g: NutritionPer100g(
        energyKcal: _d('52'),
        proteinG: _d('0.3'),
        carbsG: _d('14'),
        fatG: _d('0.2'),
        fiberG: _d('2.4'),
        sugarG: _d('10.4'),
        sodiumMg: _d('1'),
        saturatedFatG: _d('0'),
      ),
      servings: <Serving>[
        Serving(
          id: 'sv_apple_medium',
          name: '1 medium (182 g)',
          grams: _d('182'),
          isDefault: true,
          source: ServingSource.system,
          sortOrder: 1,
        ),
        _systemHundredG('sv_apple_100g'),
      ],
      categoriesTags: const <String>['fruits'],
    ),
    Food(
      id: 'f_banana_raw',
      name: 'Banana, raw',
      source: FoodSource.usda,
      isCustom: false,
      nutritionPer100g: NutritionPer100g(
        energyKcal: _d('89'),
        proteinG: _d('1.1'),
        carbsG: _d('22.8'),
        fatG: _d('0.3'),
        fiberG: _d('2.6'),
        sugarG: _d('12.2'),
        sodiumMg: _d('1'),
      ),
      servings: <Serving>[
        Serving(
          id: 'sv_banana_medium',
          name: '1 medium (118 g)',
          grams: _d('118'),
          isDefault: true,
          source: ServingSource.system,
          sortOrder: 1,
        ),
        _systemHundredG('sv_banana_100g'),
      ],
      categoriesTags: const <String>['fruits'],
    ),
    Food(
      id: 'f_chicken_breast',
      name: 'Chicken breast, skinless, cooked',
      source: FoodSource.usda,
      isCustom: false,
      nutritionPer100g: NutritionPer100g(
        energyKcal: _d('165'),
        proteinG: _d('31'),
        carbsG: _d('0'),
        fatG: _d('3.6'),
        fiberG: _d('0'),
        sugarG: _d('0'),
        sodiumMg: _d('74'),
        saturatedFatG: _d('1'),
      ),
      servings: <Serving>[
        Serving(
          id: 'sv_chicken_breast_piece',
          name: '1 breast (172 g)',
          grams: _d('172'),
          isDefault: true,
          source: ServingSource.system,
          sortOrder: 1,
        ),
        _systemHundredG('sv_chicken_100g'),
      ],
      categoriesTags: const <String>['meats', 'poultry'],
    ),
    Food(
      id: 'f_brown_rice',
      name: 'Brown rice, cooked',
      source: FoodSource.usda,
      isCustom: false,
      nutritionPer100g: NutritionPer100g(
        energyKcal: _d('123'),
        proteinG: _d('2.7'),
        carbsG: _d('25.6'),
        fatG: _d('1'),
        fiberG: _d('1.6'),
        sugarG: _d('0.4'),
        sodiumMg: _d('4'),
        saturatedFatG: _d('0.2'),
      ),
      servings: <Serving>[
        Serving(
          id: 'sv_rice_cup',
          name: '1 cup (195 g)',
          grams: _d('195'),
          isDefault: true,
          source: ServingSource.system,
          sortOrder: 1,
        ),
        _systemHundredG('sv_rice_100g'),
      ],
      categoriesTags: const <String>['grains', 'rice'],
    ),
    Food(
      id: 'f_broccoli',
      name: 'Broccoli, cooked',
      source: FoodSource.usda,
      isCustom: false,
      nutritionPer100g: NutritionPer100g(
        energyKcal: _d('35'),
        proteinG: _d('2.4'),
        carbsG: _d('7.2'),
        fatG: _d('0.4'),
        fiberG: _d('3.3'),
        sugarG: _d('1.4'),
        sodiumMg: _d('41'),
      ),
      servings: <Serving>[
        Serving(
          id: 'sv_broccoli_cup',
          name: '1 cup (156 g)',
          grams: _d('156'),
          isDefault: true,
          source: ServingSource.system,
          sortOrder: 1,
        ),
        _systemHundredG('sv_broccoli_100g'),
      ],
      categoriesTags: const <String>['vegetables'],
    ),
    Food(
      id: 'f_egg_large',
      name: 'Egg, whole, cooked',
      source: FoodSource.usda,
      isCustom: false,
      nutritionPer100g: NutritionPer100g(
        energyKcal: _d('155'),
        proteinG: _d('13'),
        carbsG: _d('1.1'),
        fatG: _d('11'),
        fiberG: _d('0'),
        sugarG: _d('1.1'),
        sodiumMg: _d('124'),
        saturatedFatG: _d('3.3'),
      ),
      servings: <Serving>[
        Serving(
          id: 'sv_egg_large',
          name: '1 large (50 g)',
          grams: _d('50'),
          isDefault: true,
          source: ServingSource.system,
          sortOrder: 1,
        ),
        _systemHundredG('sv_egg_100g'),
      ],
      categoriesTags: const <String>['eggs'],
    ),
    Food(
      id: 'f_avocado',
      name: 'Avocado, raw',
      source: FoodSource.usda,
      isCustom: false,
      nutritionPer100g: NutritionPer100g(
        energyKcal: _d('160'),
        proteinG: _d('2'),
        carbsG: _d('8.5'),
        fatG: _d('14.7'),
        fiberG: _d('6.7'),
        sugarG: _d('0.7'),
        sodiumMg: _d('7'),
        saturatedFatG: _d('2.1'),
      ),
      servings: <Serving>[
        Serving(
          id: 'sv_avocado_half',
          name: '1/2 fruit (100 g)',
          grams: _d('100'),
          isDefault: true,
          source: ServingSource.system,
          sortOrder: 1,
        ),
        _systemHundredG('sv_avocado_100g'),
      ],
      categoriesTags: const <String>['fruits'],
    ),
    Food(
      id: 'f_salmon_atlantic',
      name: 'Salmon, Atlantic, cooked',
      source: FoodSource.usda,
      isCustom: false,
      nutritionPer100g: NutritionPer100g(
        energyKcal: _d('208'),
        proteinG: _d('22.1'),
        carbsG: _d('0'),
        fatG: _d('13.4'),
        fiberG: _d('0'),
        sugarG: _d('0'),
        sodiumMg: _d('59'),
        saturatedFatG: _d('3.1'),
      ),
      servings: <Serving>[
        Serving(
          id: 'sv_salmon_fillet',
          name: '1 fillet (170 g)',
          grams: _d('170'),
          isDefault: true,
          source: ServingSource.system,
          sortOrder: 1,
        ),
        _systemHundredG('sv_salmon_100g'),
      ],
      categoriesTags: const <String>['seafood', 'fish'],
    ),
    Food(
      id: 'f_spinach_raw',
      name: 'Spinach, raw',
      source: FoodSource.usda,
      isCustom: false,
      nutritionPer100g: NutritionPer100g(
        energyKcal: _d('23'),
        proteinG: _d('2.9'),
        carbsG: _d('3.6'),
        fatG: _d('0.4'),
        fiberG: _d('2.2'),
        sugarG: _d('0.4'),
        sodiumMg: _d('79'),
        saturatedFatG: _d('0.1'),
      ),
      servings: <Serving>[
        Serving(
          id: 'sv_spinach_cup',
          name: '1 cup (30 g)',
          grams: _d('30'),
          isDefault: true,
          source: ServingSource.system,
          sortOrder: 1,
        ),
        _systemHundredG('sv_spinach_100g'),
      ],
      categoriesTags: const <String>['vegetables', 'leafy-greens'],
    ),
    Food(
      id: 'f_almonds',
      name: 'Almonds, raw',
      source: FoodSource.usda,
      isCustom: false,
      nutritionPer100g: NutritionPer100g(
        energyKcal: _d('579'),
        proteinG: _d('21.2'),
        carbsG: _d('21.6'),
        fatG: _d('49.9'),
        fiberG: _d('12.5'),
        sugarG: _d('4.4'),
        sodiumMg: _d('1'),
        saturatedFatG: _d('3.8'),
      ),
      servings: <Serving>[
        Serving(
          id: 'sv_almonds_ounce',
          name: '1 oz (28 g)',
          grams: _d('28'),
          isDefault: true,
          source: ServingSource.system,
          sortOrder: 1,
        ),
        _systemHundredG('sv_almonds_100g'),
      ],
      categoriesTags: const <String>['nuts'],
    ),

    // ── User-custom ──
    Food(
      id: 'f_moms_lasagna',
      name: "Mom's lasagna",
      brand: null,
      barcode: null,
      source: FoodSource.user,
      isCustom: true,
      nutritionPer100g: NutritionPer100g(
        energyKcal: _d('178'),
        proteinG: _d('10.5'),
        carbsG: _d('14.2'),
        fatG: _d('8.7'),
        fiberG: _d('1.3'),
        sugarG: _d('3.1'),
        sodiumMg: _d('420'),
        saturatedFatG: _d('3.6'),
      ),
      servings: <Serving>[
        Serving(
          id: 'sv_lasagna_slice',
          name: '1 slice (220 g)',
          grams: _d('220'),
          isDefault: true,
          source: ServingSource.user,
          sortOrder: 1,
        ),
        _systemHundredG('sv_lasagna_100g'),
      ],
      categoriesTags: const <String>['user-recipes'],
    ),
    Food(
      id: 'f_home_smoothie',
      name: 'Home green smoothie',
      source: FoodSource.user,
      isCustom: true,
      nutritionPer100g: NutritionPer100g(
        energyKcal: _d('62'),
        proteinG: _d('2.4'),
        carbsG: _d('11.5'),
        fatG: _d('1.1'),
        fiberG: _d('2.7'),
        sugarG: _d('7.8'),
        sodiumMg: _d('45'),
      ),
      servings: <Serving>[
        Serving(
          id: 'sv_smoothie_glass',
          name: '1 large glass (450 g)',
          grams: _d('450'),
          isDefault: true,
          source: ServingSource.user,
          sortOrder: 1,
        ),
        _systemHundredG('sv_smoothie_100g'),
      ],
      categoriesTags: const <String>['user-recipes'],
    ),
    Food(
      id: 'f_dad_chili',
      name: "Dad's turkey chili",
      source: FoodSource.user,
      isCustom: true,
      nutritionPer100g: NutritionPer100g(
        energyKcal: _d('103'),
        proteinG: _d('9.4'),
        carbsG: _d('9.7'),
        fatG: _d('3.1'),
        fiberG: _d('2.4'),
        sugarG: _d('2.1'),
        sodiumMg: _d('380'),
        saturatedFatG: _d('0.9'),
      ),
      servings: <Serving>[
        Serving(
          id: 'sv_chili_bowl',
          name: '1 bowl (340 g)',
          grams: _d('340'),
          isDefault: true,
          source: ServingSource.user,
          sortOrder: 1,
        ),
        _systemHundredG('sv_chili_100g'),
      ],
      categoriesTags: const <String>['user-recipes'],
    ),
    Food(
      id: 'f_office_coffee',
      name: 'Office coffee w/ oat milk',
      source: FoodSource.user,
      isCustom: true,
      nutritionPer100g: NutritionPer100g(
        energyKcal: _d('15'),
        proteinG: _d('0.4'),
        carbsG: _d('2.6'),
        fatG: _d('0.4'),
        fiberG: _d('0'),
        sugarG: _d('1.4'),
        sodiumMg: _d('14'),
      ),
      servings: <Serving>[
        Serving(
          id: 'sv_coffee_mug',
          name: '1 mug (350 g)',
          grams: _d('350'),
          isDefault: true,
          source: ServingSource.user,
          sortOrder: 1,
        ),
        _systemHundredG('sv_coffee_100g'),
      ],
      categoriesTags: const <String>['user-recipes', 'beverages'],
    ),

    // ── Synthetic: Quick add ───────────────────────────────────────────
    //
    // Reserves the `food_quick_add` row so the Today header's "Quick
    // add calories" affordance can POST a normal `LogCreate` against a
    // real food id. The per-100 g panel is exactly 100 kcal and the
    // single serving is 1 g — so the standard log math
    // (`per100 × grams / 100 × quantity`) collapses to
    // `quantity == kcal value`. Macros default to zero; the optional
    // macros toggle on the quick-add sheet supplies an override via
    // `LogCreate.nutritionOverride` when the user opts in.
    //
    // `source == user` is the least-bad enum value (no `synthetic`
    // variant in v1 per PM); `FoodRepository.customFoods` /
    // `customCount` skip this id by name so it never appears in "My
    // foods".
    Food(
      id: quickAddFoodId,
      name: 'Quick add',
      source: FoodSource.user,
      isCustom: false,
      nutritionPer100g: NutritionPer100g(
        energyKcal: _d('100'),
        proteinG: Decimal.zero,
        carbsG: Decimal.zero,
        fatG: Decimal.zero,
        sodiumMg: Decimal.zero,
      ),
      servings: <Serving>[
        Serving(
          id: quickAddServingId,
          name: 'kcal',
          grams: Decimal.one,
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
    // Lose 0.5 kg/week — signed negative on the wire convention.
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
//
// 30 days, slight downward trend with mild noise. The most recent entry
// matches `buildSeedUser`'s `currentWeightKg` (79.4) so the profile and
// weight screens agree.

List<WeightEntry> buildSeedWeights() {
  final out = <WeightEntry>[];
  // Start at 82.1 thirty days ago, lose ~0.07 kg/day on average with ±0.25
  // kg of noise, landing at ~80 today. Deterministic — no RNG.
  const samples = <double>[
    82.1, 82.0, 81.9, 82.1, 81.8, 81.7, 81.5,
    81.6, 81.4, 81.2, 81.0, 81.1, 80.9, 80.8,
    80.7, 80.5, 80.6, 80.4, 80.3, 80.1, 80.2,
    80.0, 79.8, 79.9, 79.7, 79.6, 79.5, 79.6, 79.4, 79.4,
  ];
  // Order: samples[0] is 29 days ago; samples.last is today.
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
//
// Seven days of partial coverage (today and prior 6). Today gets all 4
// meals populated so screen 01's day-view brief is satisfied. Prior days
// have varying coverage to exercise the "empty meal section" and the
// trend coloring on the ring across days.

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

  // Map of [daysAgo] → seeds for that day. Today (0) is fully populated.
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

/// Build a [LogEntry] with a frozen snapshot computed from the food's
/// per-100 g nutrition × the serving × quantity. This is what the
/// server does on `POST /log`; the mock repository mirrors the math so
/// the day summary and the entry both agree.
LogEntry computeLogEntry({
  required String id,
  required Food food,
  required Serving serving,
  required DateTime consumedOn,
  required Meal meal,
  required Decimal quantity,
  required DateTime createdAt,
  String? note,
}) {
  final gramsTotal = serving.grams * quantity;
  // Ratio = grams / 100. Use Rational → Decimal with a fixed scale so we
  // never carry an infinite expansion through the math.
  final ratio = (gramsTotal / Decimal.fromInt(100))
      .toDecimal(scaleOnInfinitePrecision: 6);

  Decimal? scale(Decimal? v) =>
      v == null ? null : (v * ratio);

  final per = food.nutritionPer100g;
  final kcal = (per.energyKcal ?? Decimal.zero) * ratio;
  final snapshot = NutritionSnapshot(
    caloriesKcal: kcal,
    proteinG: scale(per.proteinG),
    carbsG: scale(per.carbsG),
    fatG: scale(per.fatG),
    fiberG: scale(per.fiberG),
    sugarG: scale(per.sugarG),
    sodiumMg: scale(per.sodiumMg),
    saturatedFatG: scale(per.saturatedFatG),
  );

  return LogEntry(
    id: id,
    foodId: food.id,
    foodName: food.name,
    servingId: serving.id,
    servingName: serving.name,
    consumedOn: consumedOn,
    meal: meal,
    quantity: quantity,
    gramsTotal: gramsTotal,
    nutritionSnapshot: snapshot,
    note: note,
    createdAt: createdAt,
    updatedAt: createdAt,
  );
}

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

/// Compute the 7-day moving average client-side (architect gotcha for
/// screen 06). Window is the preceding 7 entries inclusive of `i`. For
/// `i < 6` there aren't enough points; we leave `movingAvg7d` null.
///
/// Math stays in `Decimal` to honor T-17. The sum / 7 rational is
/// resolved to 4 decimal places — plenty of precision for a chart axis
/// label that formats to one decimal at the leaf.
List<WeightSeriesPoint> buildWeightSeries(List<WeightEntry> entries) {
  // Caller guarantees ascending-by-recordedOn order. Defensive sort here
  // anyway — the mock fixture is already sorted, but future seed
  // shuffles shouldn't break the moving-avg math.
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
