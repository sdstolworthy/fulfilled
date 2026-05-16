import 'package:decimal/decimal.dart';

import 'enums.dart';
import 'nutrition.dart';

/// Draft for screen 05 — custom food creation. Mirrors the eventual
/// `FoodCreate` payload but with everything optional so the form can be
/// filled incrementally and validated at the leaf.
///
/// `servings` carries label + grams pairs; the 100 g system serving is
/// auto-seeded server-side so the draft does not include it (gotcha in
/// architecture §9 screen 05).
///
/// Validation lives on this class — `errors` returns a list of
/// per-field error codes. The sticky footer copy ("Fix N errors") reads
/// `errors.length`.
class CustomFoodDraft {
  const CustomFoodDraft({
    this.name = '',
    this.brand,
    this.barcode,
    this.energyKcal,
    this.proteinG,
    this.carbsG,
    this.fatG,
    this.fiberG,
    this.sugarG,
    this.sodiumMg,
    this.saturatedFatG,
    this.userServings = const <DraftServing>[],
  });

  final String name;
  final String? brand;
  final String? barcode;

  /// Per-100 g nutrition. Required client-side: `energyKcal`, `proteinG`,
  /// `carbsG`, `fatG` — architecture gotcha "client validation is
  /// additive". The other fields are optional.
  final Decimal? energyKcal;
  final Decimal? proteinG;
  final Decimal? carbsG;
  final Decimal? fatG;
  final Decimal? fiberG;
  final Decimal? sugarG;
  final Decimal? sodiumMg;
  final Decimal? saturatedFatG;

  final List<DraftServing> userServings;

  CustomFoodDraft copyWith({
    String? name,
    String? brand,
    String? barcode,
    Decimal? energyKcal,
    Decimal? proteinG,
    Decimal? carbsG,
    Decimal? fatG,
    Decimal? fiberG,
    Decimal? sugarG,
    Decimal? sodiumMg,
    Decimal? saturatedFatG,
    List<DraftServing>? userServings,
  }) =>
      CustomFoodDraft(
        name: name ?? this.name,
        brand: brand ?? this.brand,
        barcode: barcode ?? this.barcode,
        energyKcal: energyKcal ?? this.energyKcal,
        proteinG: proteinG ?? this.proteinG,
        carbsG: carbsG ?? this.carbsG,
        fatG: fatG ?? this.fatG,
        fiberG: fiberG ?? this.fiberG,
        sugarG: sugarG ?? this.sugarG,
        sodiumMg: sodiumMg ?? this.sodiumMg,
        saturatedFatG: saturatedFatG ?? this.saturatedFatG,
        userServings: userServings ?? this.userServings,
      );

  /// Codes of missing/invalid fields. Empty when the draft is savable.
  List<String> get errors {
    final out = <String>[];
    if (name.trim().isEmpty) out.add('name');
    if (energyKcal == null) out.add('energy_kcal');
    if (proteinG == null) out.add('protein_g');
    if (carbsG == null) out.add('carbs_g');
    if (fatG == null) out.add('fat_g');
    return out;
  }

  bool get isValid => errors.isEmpty;

  /// Snapshot the draft as the wire-shaped `NutritionPer100g`. Missing
  /// macros become null; the caller is expected to gate on [isValid].
  NutritionPer100g toNutrition() => NutritionPer100g(
        energyKcal: energyKcal,
        proteinG: proteinG,
        carbsG: carbsG,
        fatG: fatG,
        fiberG: fiberG,
        sugarG: sugarG,
        sodiumMg: sodiumMg,
        saturatedFatG: saturatedFatG,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CustomFoodDraft &&
          other.name == name &&
          other.brand == brand &&
          other.barcode == barcode &&
          other.energyKcal == energyKcal &&
          other.proteinG == proteinG &&
          other.carbsG == carbsG &&
          other.fatG == fatG &&
          other.fiberG == fiberG &&
          other.sugarG == sugarG &&
          other.sodiumMg == sodiumMg &&
          other.saturatedFatG == saturatedFatG &&
          _servingListEq(other.userServings, userServings);

  @override
  int get hashCode => Object.hash(
        name,
        brand,
        barcode,
        energyKcal,
        proteinG,
        carbsG,
        fatG,
        fiberG,
        sugarG,
        sodiumMg,
        saturatedFatG,
        Object.hashAll(userServings),
      );
}

/// In-progress serving row in the custom-food form. Not a `Serving` —
/// no id yet (the server allocates it on POST).
class DraftServing {
  const DraftServing({required this.label, required this.grams});
  final String label;
  final Decimal grams;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DraftServing && other.label == label && other.grams == grams;

  @override
  int get hashCode => Object.hash(label, grams);
}

bool _servingListEq(List<DraftServing> a, List<DraftServing> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Draft for screen 09 — onboarding. Steps mutate this incrementally;
/// the final "Get started" tap POSTs to `/me` (PATCH) and `/goals`.
///
/// Step 1 has no inputs (it's the welcome screen — PM Risk 2 removed
/// the secondary link). Step 2 fills the profile fields. Step 3 fills
/// the goal fields. `currentStep` is one of `1 | 2 | 3` so the router
/// can clamp `:step`.
class OnboardingDraft {
  const OnboardingDraft({
    this.currentStep = 1,
    this.sex,
    this.birthDate,
    this.heightCm,
    this.currentWeightKg,
    this.activityLevel,
    this.direction,
    this.rateKgPerWeek,
    this.targetWeightKg,
    this.weightUnit,
    this.heightUnit,
  });

  final int currentStep;

  // Profile bits.
  final Sex? sex;
  final DateTime? birthDate;
  final Decimal? heightCm;
  final Decimal? currentWeightKg;
  final ActivityLevel? activityLevel;

  // Goal bits.
  final GoalDirection? direction;
  final Decimal? rateKgPerWeek;
  final Decimal? targetWeightKg;

  /// User-chosen display unit during onboarding. `null` means "no
  /// explicit selection yet — fall back to
  /// `defaultWeightUnitForLocale()` at read time". Set by step 2's
  /// chooser the moment the user taps a segment (LU-008); read by
  /// `onboardingWeightUnitProvider` (LU-006) and persisted at final
  /// submit time alongside the rest of the profile patch.
  final WeightUnit? weightUnit;

  /// User-chosen height display unit during onboarding. Mirror of
  /// [weightUnit]. `null` means "no explicit selection yet — fall back
  /// to the locale default at read time". Set by step 2's height
  /// chooser once that widget lands (QL-104); read by
  /// `onboardingHeightUnitProvider` (added by QL-104) and persisted at
  /// final submit alongside the rest of the profile patch.
  final HeightUnit? heightUnit;

  OnboardingDraft copyWith({
    int? currentStep,
    Sex? sex,
    DateTime? birthDate,
    Decimal? heightCm,
    Decimal? currentWeightKg,
    ActivityLevel? activityLevel,
    GoalDirection? direction,
    Decimal? rateKgPerWeek,
    Decimal? targetWeightKg,
    WeightUnit? weightUnit,
    HeightUnit? heightUnit,
  }) =>
      OnboardingDraft(
        currentStep: currentStep ?? this.currentStep,
        sex: sex ?? this.sex,
        birthDate: birthDate ?? this.birthDate,
        heightCm: heightCm ?? this.heightCm,
        currentWeightKg: currentWeightKg ?? this.currentWeightKg,
        activityLevel: activityLevel ?? this.activityLevel,
        direction: direction ?? this.direction,
        rateKgPerWeek: rateKgPerWeek ?? this.rateKgPerWeek,
        targetWeightKg: targetWeightKg ?? this.targetWeightKg,
        weightUnit: weightUnit ?? this.weightUnit,
        heightUnit: heightUnit ?? this.heightUnit,
      );

  bool get isStep2Complete =>
      sex != null &&
      birthDate != null &&
      heightCm != null &&
      currentWeightKg != null &&
      activityLevel != null;

  bool get isStep3Complete =>
      direction != null &&
      (direction == GoalDirection.maintain || rateKgPerWeek != null);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OnboardingDraft &&
          other.currentStep == currentStep &&
          other.sex == sex &&
          other.birthDate == birthDate &&
          other.heightCm == heightCm &&
          other.currentWeightKg == currentWeightKg &&
          other.activityLevel == activityLevel &&
          other.direction == direction &&
          other.rateKgPerWeek == rateKgPerWeek &&
          other.targetWeightKg == targetWeightKg &&
          other.weightUnit == weightUnit &&
          other.heightUnit == heightUnit;

  @override
  int get hashCode => Object.hash(
        currentStep,
        sex,
        birthDate,
        heightCm,
        currentWeightKg,
        activityLevel,
        direction,
        rateKgPerWeek,
        targetWeightKg,
        weightUnit,
        heightUnit,
      );
}
