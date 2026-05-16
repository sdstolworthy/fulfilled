import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/enums.dart';
import '../domain/locale_defaults.dart';
import '../domain/user.dart';
import 'repository_providers.dart';

/// Profile-domain provider — just one read: [meProvider]. Screen 08
/// (Profile / You) and onboarding step 2's pre-fill bind here.
///
/// **Derived fields.** `User.currentWeightKg` is filled from the most
/// recent weight entry; `User.customFoodCount` is filled from the food
/// repository. After mutations to either, screens should
/// `ref.invalidate(meProvider)` so the derived fields refresh.

/// Current user, with derived fields.
final meProvider = FutureProvider<User>((ref) {
  final repo = ref.watch(profileRepositoryProvider);
  return repo.me();
});

/// Locale-derived fallback weight unit. Wraps
/// [defaultWeightUnitForLocale] so tests can override the fallback
/// without spinning up a Flutter binding (architect §3.4 — the helper
/// itself takes a `countryCodeOverride`, but providers cannot reach
/// the override from inside `ref.watch`).
///
/// Override this in [ProviderContainer] tests when asserting the
/// loading / error fallback path of [weightUnitProvider] or
/// `onboardingWeightUnitProvider` (LU-006).
final localeDefaultWeightUnitProvider = Provider<WeightUnit>((ref) {
  // ignore: deprecated_member_use_from_same_package
  return defaultWeightUnitForLocale();
});

/// Locale-derived fallback height unit. Mirror of
/// [localeDefaultWeightUnitProvider] — the test seam for
/// [heightUnitProvider] and (later) `onboardingHeightUnitProvider`.
///
/// Override this in [ProviderContainer] tests to pin a known
/// `HeightUnit` without taking a dependency on `WidgetsBinding`'s
/// platform dispatcher.
///
/// QL-104 will sweep both per-axis locale providers in favour of a
/// shared `localeDefaultsProvider` reading [defaultUnitsForLocale]
/// directly; until then this provider keeps the per-axis test seam
/// stable for QL-102's foundation.
final localeDefaultHeightUnitProvider = Provider<HeightUnit>((ref) {
  // ignore: deprecated_member_use_from_same_package
  return defaultHeightUnitForLocale();
});

/// Active weight unit for the authenticated user.
///
/// Derived from `meProvider.user.weightUnit`. While `meProvider` is
/// loading or errored, falls back to [localeDefaultWeightUnitProvider]
/// (which wraps [defaultWeightUnitForLocale]) so the UI never has to
/// render a placeholder unit suffix (architect §3.10).
///
/// **Re-renders propagate**: any widget that
/// `ref.watch(weightUnitProvider)` rebuilds when the user changes
/// their preference — the PATCH /me path invalidates `meProvider`,
/// which updates this provider on the next frame (tenant T-18).
final weightUnitProvider = Provider<WeightUnit>((ref) {
  return ref.watch(meProvider).maybeWhen(
        data: (u) => u.weightUnit,
        orElse: () => ref.watch(localeDefaultWeightUnitProvider),
      );
});

/// Active height unit for the authenticated user.
///
/// Mirror of [weightUnitProvider]. **Per-axis by design** — the
/// architect (§2.1) ruled against a unified `userPreferencesProvider`
/// record so widget rebuilds stay granular: a height-only chooser
/// rebuild doesn't fan out to weight readers (tenant T-18).
///
/// QL-104 flipped the data branch to read `u.heightUnit` now that
/// `User.heightUnit` exists with a `cm` default. While `meProvider` is
/// loading or errored the provider falls back through
/// [localeDefaultHeightUnitProvider] so the UI never has to render a
/// placeholder suffix (architect §3.10, §5.1).
final heightUnitProvider = Provider<HeightUnit>((ref) {
  return ref.watch(meProvider).maybeWhen(
        data: (u) => u.heightUnit,
        orElse: () => ref.watch(localeDefaultHeightUnitProvider),
      );
});
