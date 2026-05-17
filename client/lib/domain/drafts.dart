import 'package:decimal/decimal.dart';

import 'enums.dart';
import 'unit.dart';

/// Draft for screen 05 — custom food creation. Per Ask 10 the
/// per-100g nutrition panel is gone; nutrition lives on each
/// [DraftServing] instead. The form is a list of servings plus
/// identity metadata (name, brand, barcode).
///
/// Validation: at least one serving with a positive amount + non-null
/// kcal is required. Each serving's required fields are validated on
/// the serving itself. The footer "Fix N errors" reads `errors.length`.
class CustomFoodDraft {
  const CustomFoodDraft({
    this.name = '',
    this.brand,
    this.barcode,
    this.servings = const <DraftServing>[],
  });

  final String name;
  final String? brand;
  final String? barcode;

  /// User-defined servings. At least one is required to save.
  final List<DraftServing> servings;

  CustomFoodDraft copyWith({
    String? name,
    String? brand,
    String? barcode,
    List<DraftServing>? servings,
  }) =>
      CustomFoodDraft(
        name: name ?? this.name,
        brand: brand ?? this.brand,
        barcode: barcode ?? this.barcode,
        servings: servings ?? this.servings,
      );

  /// Codes of missing/invalid fields. Empty when the draft is savable.
  ///
  /// Per-row serving errors are surfaced as `serving:<index>:<field>`
  /// so the editor row can highlight its own bad fields without
  /// inventing a separate per-row error pipe.
  List<String> get errors {
    final out = <String>[];
    if (name.trim().isEmpty) out.add('name');
    if (servings.isEmpty) {
      out.add('servings');
    } else {
      for (var i = 0; i < servings.length; i++) {
        final s = servings[i];
        if (s.amount == null || s.amount! <= Decimal.zero) {
          out.add('serving:$i:amount');
        }
        if (s.kcal == null) out.add('serving:$i:kcal');
      }
    }
    return out;
  }

  bool get isValid => errors.isEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CustomFoodDraft &&
          other.name == name &&
          other.brand == brand &&
          other.barcode == barcode &&
          _servingListEq(other.servings, servings);

  @override
  int get hashCode => Object.hash(
        name,
        brand,
        barcode,
        Object.hashAll(servings),
      );
}

/// In-progress serving row in the custom-food form. Not a `Serving` —
/// no id yet (the server allocates it on POST). Fields are nullable so
/// a freshly-added row starts empty; `CustomFoodDraft.errors` flags
/// any row that's still missing required fields at save time.
class DraftServing {
  const DraftServing({
    this.label,
    this.amount,
    this.unit = Unit.g,
    this.kcal,
    this.proteinG,
    this.carbsG,
    this.fatG,
    this.fiberG,
    this.sugarG,
    this.sodiumMg,
    this.saturatedFatG,
    this.isDefault = false,
  });

  final String? label;
  final Decimal? amount;
  final Unit unit;
  final Decimal? kcal;
  final Decimal? proteinG;
  final Decimal? carbsG;
  final Decimal? fatG;
  final Decimal? fiberG;
  final Decimal? sugarG;
  final Decimal? sodiumMg;
  final Decimal? saturatedFatG;
  final bool isDefault;

  DraftServing copyWith({
    String? label,
    Decimal? amount,
    Unit? unit,
    Decimal? kcal,
    Decimal? proteinG,
    Decimal? carbsG,
    Decimal? fatG,
    Decimal? fiberG,
    Decimal? sugarG,
    Decimal? sodiumMg,
    Decimal? saturatedFatG,
    bool? isDefault,
  }) =>
      DraftServing(
        label: label ?? this.label,
        amount: amount ?? this.amount,
        unit: unit ?? this.unit,
        kcal: kcal ?? this.kcal,
        proteinG: proteinG ?? this.proteinG,
        carbsG: carbsG ?? this.carbsG,
        fatG: fatG ?? this.fatG,
        fiberG: fiberG ?? this.fiberG,
        sugarG: sugarG ?? this.sugarG,
        sodiumMg: sodiumMg ?? this.sodiumMg,
        saturatedFatG: saturatedFatG ?? this.saturatedFatG,
        isDefault: isDefault ?? this.isDefault,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DraftServing &&
          other.label == label &&
          other.amount == amount &&
          other.unit == unit &&
          other.kcal == kcal &&
          other.proteinG == proteinG &&
          other.carbsG == carbsG &&
          other.fatG == fatG &&
          other.fiberG == fiberG &&
          other.sugarG == sugarG &&
          other.sodiumMg == sodiumMg &&
          other.saturatedFatG == saturatedFatG &&
          other.isDefault == isDefault;

  @override
  int get hashCode => Object.hash(
        label,
        amount,
        unit,
        kcal,
        proteinG,
        carbsG,
        fatG,
        fiberG,
        sugarG,
        sodiumMg,
        saturatedFatG,
        isDefault,
      );
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

  final WeightUnit? weightUnit;
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
