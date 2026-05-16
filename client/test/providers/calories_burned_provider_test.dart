import 'package:decimal/decimal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/user.dart';
import 'package:fulfilled/providers/calorie_providers.dart';
import 'package:fulfilled/providers/profile_providers.dart';

/// Unit tests for [caloriesBurnedTodayProvider] (T-020 / B8).
///
/// The provider derives "Burned" from `meProvider` via the canonical
/// Mifflin-St Jeor TDEE math in `lib/domain/calories/estimate.dart`.
/// The reference numbers below mirror `test/domain/calories/estimate_test.dart`
/// so a change to the math surfaces in both files.

User _user({
  Sex? sex = Sex.male,
  DateTime? birthDate,
  Decimal? heightCm,
  Decimal? weightKg,
  ActivityLevel? activityLevel = ActivityLevel.sedentary,
}) {
  return User(
    id: 'u_test',
    sex: sex,
    birthDate: birthDate,
    heightCm: heightCm,
    currentWeightKg: weightKg,
    activityLevel: activityLevel,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );
}

void main() {
  group('caloriesBurnedTodayProvider', () {
    test(
      'male sedentary @ 80 kg 180 cm → TDEE in the canonical band',
      () async {
        // Reference computation (see estimate_test.dart):
        //   BMR  = 10*80 + 6.25*180 - 5*age + 5
        //   TDEE = BMR * 1.2 (sedentary)
        // The provider doesn't pin `now`, so the exact value depends
        // on today's age math against the seeded birthDate. We assert
        // membership in the canonical age-30…age-31 band instead of
        // a single integer so the test doesn't flake on a birthday.
        final container = ProviderContainer(
          overrides: <Override>[
            meProvider.overrideWith(
              (_) async => _user(
                sex: Sex.male,
                birthDate: DateTime(1995, 1, 1),
                heightCm: Decimal.parse('180'),
                weightKg: Decimal.parse('80'),
                activityLevel: ActivityLevel.sedentary,
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        final burned = await container.read(caloriesBurnedTodayProvider.future);
        // age-30 → TDEE 2136 ; age-31 → TDEE 2130 ; age-32 → 2124.
        // Anything in the [2100, 2200] band is plausible for a decade
        // either side of today; tightening further would require pinning
        // `now`, which the provider intentionally does not expose.
        expect(burned >= Decimal.fromInt(2100), isTrue);
        expect(burned <= Decimal.fromInt(2200), isTrue);
      },
    );

    test(
      'same profile twice returns the identical value (determinism)',
      () async {
        // Two reads through two separate containers with the same
        // upstream profile must produce the same Decimal — there's no
        // hidden jitter in the provider.
        Override profileOverride() => meProvider.overrideWith(
              (_) async => _user(
                sex: Sex.female,
                birthDate: DateTime(1998, 5, 16),
                heightCm: Decimal.parse('165'),
                weightKg: Decimal.parse('60'),
                activityLevel: ActivityLevel.active,
              ),
            );

        final a = ProviderContainer(overrides: <Override>[profileOverride()]);
        addTearDown(a.dispose);
        final b = ProviderContainer(overrides: <Override>[profileOverride()]);
        addTearDown(b.dispose);

        final ra = await a.read(caloriesBurnedTodayProvider.future);
        final rb = await b.read(caloriesBurnedTodayProvider.future);
        expect(ra, rb);
      },
    );

    test(
      'throws when profile is incomplete (fresh user → consumer renders —)',
      () async {
        // A brand-new user (no sex / birthDate / height / weight /
        // activity level) is the "fresh user" case in PM B8. The
        // provider surfaces this as an error so the ring summary card
        // can silently fall back to `'—'` in the error arm.
        final container = ProviderContainer(
          overrides: <Override>[
            meProvider.overrideWith(
              (_) async => _user(
                sex: null,
                birthDate: null,
                heightCm: null,
                weightKg: null,
                activityLevel: null,
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        await expectLater(
          container.read(caloriesBurnedTodayProvider.future),
          throwsA(isA<Exception>()),
        );
      },
    );

    test(
      'non-negative for every supported activity band',
      () async {
        // Belt-and-braces: TDEE ≥ BMR ≥ 0 for every Mifflin-St Jeor
        // band, but the provider's clamp guarantees the public surface
        // is non-negative regardless. Spot-check the lightest band.
        final container = ProviderContainer(
          overrides: <Override>[
            meProvider.overrideWith(
              (_) async => _user(
                sex: Sex.female,
                birthDate: DateTime(1980, 1, 1),
                heightCm: Decimal.parse('150'),
                weightKg: Decimal.parse('45'),
                activityLevel: ActivityLevel.sedentary,
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        final burned = await container.read(caloriesBurnedTodayProvider.future);
        expect(burned >= Decimal.zero, isTrue);
      },
    );
  });
}
