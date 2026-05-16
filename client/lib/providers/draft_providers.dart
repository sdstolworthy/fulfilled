import 'package:decimal/decimal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/drafts.dart';
import '../domain/enums.dart';

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

  /// Restore the empty draft. Call this on successful submit — see file
  /// docstring.
  void reset() => state = const OnboardingDraft();
}

final onboardingDraftProvider =
    StateNotifierProvider<OnboardingDraftNotifier, OnboardingDraft>((ref) {
  return OnboardingDraftNotifier();
});
