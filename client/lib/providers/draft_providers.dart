import 'package:decimal/decimal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/drafts.dart';
import '../domain/enums.dart';
import '../domain/food.dart';
import 'profile_providers.dart';

/// Draft-state providers for the two multi-step forms:
///
/// - [customFoodDraftProvider] — screen 05 ("Create custom food"). Per
///   Ask 10 nutrition lives on each [DraftServing], not on the top of
///   the draft.
/// - [onboardingDraftProvider] — screen 09 (3-step onboarding).
///
/// **Reset semantics.** Both notifiers expose a `reset()` method. Screen
/// agents must call it:
///   - on successful submit (otherwise the next visit prefills with the
///     just-submitted values),
///   - on explicit "Discard" affordances.

// ─── Custom food draft ────────────────────────────────────────────────────

class CustomFoodDraftNotifier extends StateNotifier<CustomFoodDraft> {
  CustomFoodDraftNotifier() : super(const CustomFoodDraft());

  void setName(String v) => state = state.copyWith(name: v);
  void setBrand(String? v) => state = state.copyWith(brand: v);
  void setBarcode(String? v) => state = state.copyWith(barcode: v);

  /// Replace the serving list wholesale. The custom-food form re-builds
  /// the whole list when a row is added/removed/reordered or when any
  /// per-row field changes.
  void setServings(List<DraftServing> servings) =>
      state = state.copyWith(servings: servings);

  /// Mutate a single serving in-place by index. Equivalent to
  /// [setServings] with one row replaced; convenient for per-row
  /// onChanged callbacks.
  void updateServingAt(int i, DraftServing next) {
    final copy = <DraftServing>[...state.servings];
    if (i < 0 || i >= copy.length) return;
    copy[i] = next;
    state = state.copyWith(servings: copy);
  }

  void addServing([DraftServing? seed]) {
    final next = seed ?? const DraftServing();
    state = state.copyWith(servings: <DraftServing>[...state.servings, next]);
  }

  void removeServingAt(int i) {
    final copy = <DraftServing>[...state.servings]..removeAt(i);
    state = state.copyWith(servings: copy);
  }

  /// Restore the empty draft.
  void reset() => state = const CustomFoodDraft();

  /// Seed the draft from an existing [Food] — used by the edit-mode
  /// branch of `CustomFoodScreen` to pre-populate every field from the
  /// food on first build.
  void seedFromFood(Food food) {
    state = CustomFoodDraft(
      name: food.name,
      brand: food.brand,
      barcode: food.barcode,
      servings: <DraftServing>[
        for (final s in food.servings)
          DraftServing(
            label: s.label,
            amount: s.amount,
            unit: s.unit,
            kcal: s.kcal,
            proteinG: s.proteinG,
            carbsG: s.carbsG,
            fatG: s.fatG,
            fiberG: s.fiberG,
            sugarG: s.sugarG,
            sodiumMg: s.sodiumMg,
            saturatedFatG: s.saturatedFatG,
            isDefault: s.isDefault,
          ),
      ],
    );
  }
}

final customFoodDraftProvider =
    StateNotifierProvider<CustomFoodDraftNotifier, CustomFoodDraft>((ref) {
  return CustomFoodDraftNotifier();
});

// ─── Onboarding draft ─────────────────────────────────────────────────────

class OnboardingDraftNotifier extends StateNotifier<OnboardingDraft> {
  OnboardingDraftNotifier() : super(const OnboardingDraft());

  void goToStep(int step) {
    final clamped = step < 1 ? 1 : (step > 3 ? 3 : step);
    state = state.copyWith(currentStep: clamped);
  }

  void next() => goToStep(state.currentStep + 1);
  void previous() => goToStep(state.currentStep - 1);

  void setSex(Sex? v) => state = state.copyWith(sex: v);
  void setBirthDate(DateTime? v) => state = state.copyWith(birthDate: v);
  void setHeightCm(Decimal? v) => state = state.copyWith(heightCm: v);
  void setCurrentWeightKg(Decimal? v) =>
      state = state.copyWith(currentWeightKg: v);
  void setActivityLevel(ActivityLevel? v) =>
      state = state.copyWith(activityLevel: v);

  void setDirection(GoalDirection? v) => state = state.copyWith(direction: v);
  void setRateKgPerWeek(Decimal? v) =>
      state = state.copyWith(rateKgPerWeek: v);
  void setTargetWeightKg(Decimal? v) =>
      state = state.copyWith(targetWeightKg: v);

  void setWeightUnit(WeightUnit v) => state = state.copyWith(weightUnit: v);
  void setHeightUnit(HeightUnit v) => state = state.copyWith(heightUnit: v);

  void reset() => state = const OnboardingDraft();
}

final onboardingDraftProvider =
    StateNotifierProvider<OnboardingDraftNotifier, OnboardingDraft>((ref) {
  return OnboardingDraftNotifier();
});

final onboardingWeightUnitProvider = Provider<WeightUnit>((ref) {
  final draft = ref.watch(onboardingDraftProvider);
  return draft.weightUnit ?? ref.watch(localeDefaultWeightUnitProvider);
});

final onboardingHeightUnitProvider = Provider<HeightUnit>((ref) {
  final draft = ref.watch(onboardingDraftProvider);
  return draft.heightUnit ?? ref.watch(localeDefaultHeightUnitProvider);
});
