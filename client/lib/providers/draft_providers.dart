import 'package:decimal/decimal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/drafts.dart';
import '../domain/enums.dart';
import '../domain/food.dart';
import 'profile_providers.dart';

/// Draft-state providers for the two multi-step forms:
///
/// - [customFoodDraftProvider] — screen 05 ("Create custom food"). Holds
///   the in-progress draft until the user taps Save. The form mutates it
///   field-by-field via the notifier methods below.
/// - [onboardingDraftProvider] — screen 09 (3-step onboarding). Holds
///   profile + goal bits until step 3's "Get started" tap commits both
///   to the server (PATCH /me + POST /goals).
///
/// **Reset semantics.** Both notifiers expose a `reset()` method. Screen
/// agents must call it:
///   - on successful submit (otherwise the next visit prefills with the
///     just-submitted values),
///   - on explicit "Discard" affordances.
/// Cancelling without an explicit discard does *not* reset — that's by
/// design so a user who taps Back and reopens the form continues where
/// they left off. The provider's lifecycle (kept alive for the app
/// session) is what makes that possible.

// ─── Custom food draft ────────────────────────────────────────────────────

/// Notifier wrapping [CustomFoodDraft]. Each method mutates exactly one
/// field — the form binds an input to the matching method via
/// `onChanged: ref.read(customFoodDraftProvider.notifier).setName`.
class CustomFoodDraftNotifier extends StateNotifier<CustomFoodDraft> {
  CustomFoodDraftNotifier() : super(const CustomFoodDraft());

  void setName(String v) => state = state.copyWith(name: v);
  void setBrand(String? v) => state = state.copyWith(brand: v);
  void setBarcode(String? v) => state = state.copyWith(barcode: v);

  void setEnergyKcal(Decimal? v) => state = state.copyWith(energyKcal: v);
  void setProteinG(Decimal? v) => state = state.copyWith(proteinG: v);
  void setCarbsG(Decimal? v) => state = state.copyWith(carbsG: v);
  void setFatG(Decimal? v) => state = state.copyWith(fatG: v);
  void setFiberG(Decimal? v) => state = state.copyWith(fiberG: v);
  void setSugarG(Decimal? v) => state = state.copyWith(sugarG: v);
  void setSodiumMg(Decimal? v) => state = state.copyWith(sodiumMg: v);
  void setSaturatedFatG(Decimal? v) =>
      state = state.copyWith(saturatedFatG: v);

  /// Replace the serving list wholesale. The custom-food form re-builds
  /// the whole list when a row is added/removed/reordered — per-row
  /// mutation belongs to the screen, not the notifier.
  void setServings(List<DraftServing> servings) =>
      state = state.copyWith(userServings: servings);

  /// Restore the empty draft. Call this on successful submit or explicit
  /// "Discard" — see file docstring.
  void reset() => state = const CustomFoodDraft();

  /// Seed the draft from an existing [Food] — used by the edit-mode
  /// branch of `CustomFoodScreen` to pre-populate every field from the
  /// food on first build. Only user-defined servings flow into
  /// `userServings`; the synthetic 100 g system row is filtered out
  /// (the form never edits it — T-10 says it's auto-managed).
  ///
  /// Mirrors the create-flow shape: `name` collapses null/empty to '',
  /// optional strings stay as-is, nutrition decimals pass through
  /// untouched.
  void seedFromFood(Food food) {
    state = CustomFoodDraft(
      name: food.name,
      brand: food.brand,
      barcode: food.barcode,
      energyKcal: food.nutritionPer100g.energyKcal,
      proteinG: food.nutritionPer100g.proteinG,
      carbsG: food.nutritionPer100g.carbsG,
      fatG: food.nutritionPer100g.fatG,
      fiberG: food.nutritionPer100g.fiberG,
      sugarG: food.nutritionPer100g.sugarG,
      sodiumMg: food.nutritionPer100g.sodiumMg,
      saturatedFatG: food.nutritionPer100g.saturatedFatG,
      userServings: <DraftServing>[
        for (final s in food.servings)
          if (s.source != ServingSource.system)
            DraftServing(label: s.name, grams: s.grams),
      ],
    );
  }
}

final customFoodDraftProvider =
    StateNotifierProvider<CustomFoodDraftNotifier, CustomFoodDraft>((ref) {
  return CustomFoodDraftNotifier();
});

// ─── Onboarding draft ─────────────────────────────────────────────────────

/// Notifier wrapping [OnboardingDraft]. Step 1 is welcome-only (no
/// inputs); step 2 fills profile bits; step 3 fills goal bits.
/// `next` / `previous` move between steps with bounds-checking.
class OnboardingDraftNotifier extends StateNotifier<OnboardingDraft> {
  OnboardingDraftNotifier() : super(const OnboardingDraft());

  // Step navigation.
  void goToStep(int step) {
    final clamped = step < 1 ? 1 : (step > 3 ? 3 : step);
    state = state.copyWith(currentStep: clamped);
  }

  void next() => goToStep(state.currentStep + 1);
  void previous() => goToStep(state.currentStep - 1);

  // Profile (step 2).
  void setSex(Sex? v) => state = state.copyWith(sex: v);
  void setBirthDate(DateTime? v) => state = state.copyWith(birthDate: v);
  void setHeightCm(Decimal? v) => state = state.copyWith(heightCm: v);
  void setCurrentWeightKg(Decimal? v) =>
      state = state.copyWith(currentWeightKg: v);
  void setActivityLevel(ActivityLevel? v) =>
      state = state.copyWith(activityLevel: v);

  // Goal (step 3).
  void setDirection(GoalDirection? v) => state = state.copyWith(direction: v);
  void setRateKgPerWeek(Decimal? v) =>
      state = state.copyWith(rateKgPerWeek: v);
  void setTargetWeightKg(Decimal? v) =>
      state = state.copyWith(targetWeightKg: v);

  /// Set the user-chosen display unit for the onboarding step 2 weight
  /// row. Wires into `onboardingWeightUnitProvider` (LU-006) — the
  /// chooser segment tap calls this directly.
  void setWeightUnit(WeightUnit v) => state = state.copyWith(weightUnit: v);

  /// Set the user-chosen display unit for the onboarding step 2 height
  /// row. Mirror of [setWeightUnit] — wires into
  /// `onboardingHeightUnitProvider` (QL-104). The chosen unit also
  /// lands on `UserPatch.heightUnit` at final submit.
  void setHeightUnit(HeightUnit v) => state = state.copyWith(heightUnit: v);

  /// Restore the empty draft. Call this on successful submit — see file
  /// docstring.
  void reset() => state = const OnboardingDraft();
}

final onboardingDraftProvider =
    StateNotifierProvider<OnboardingDraftNotifier, OnboardingDraft>((ref) {
  return OnboardingDraftNotifier();
});

/// Active weight unit during onboarding (screen 09 step 2).
///
/// Reads the draft first — once the user taps a segment in step 2's
/// chooser the draft carries an explicit [WeightUnit]. Until then it
/// falls back to [defaultWeightUnitForLocale] so US locale onboarders
/// see `lb` without a manual tap. After the final "Get started" submit
/// `meProvider` invalidates and the global [weightUnitProvider] takes
/// over (architect §3.11).
///
/// The architect spec named this with a leading underscore. It is
/// exported (no underscore) because step 2's widget — owned by a
/// different file — needs to `ref.watch` it. Tests pin this provider
/// directly via [ProviderContainer.overrides] when they need to assert
/// the locale-fallback path independent of the platform dispatcher.
final onboardingWeightUnitProvider = Provider<WeightUnit>((ref) {
  final draft = ref.watch(onboardingDraftProvider);
  return draft.weightUnit ?? ref.watch(localeDefaultWeightUnitProvider);
});

/// Active height unit during onboarding (screen 09 step 2).
///
/// Mirror of [onboardingWeightUnitProvider]. Reads the draft first;
/// once the user taps a segment in step 2's height chooser the draft
/// carries an explicit [HeightUnit]. Until then it falls back to
/// [localeDefaultHeightUnitProvider] so US/UK onboarders see `ft·in`
/// without a manual tap. After the final "Get started" submit
/// `meProvider` invalidates and the global [heightUnitProvider] takes
/// over (architect §5.1, §5.9).
final onboardingHeightUnitProvider = Provider<HeightUnit>((ref) {
  final draft = ref.watch(onboardingDraftProvider);
  return draft.heightUnit ?? ref.watch(localeDefaultHeightUnitProvider);
});
