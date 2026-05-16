import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/drafts.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/user.dart';
import 'package:fulfilled/providers/draft_providers.dart';
import 'package:fulfilled/providers/profile_providers.dart';

/// Tests for [weightUnitProvider] and [onboardingWeightUnitProvider]
/// (LU-006).
///
/// Both providers are pure derived `Provider<WeightUnit>` — no async,
/// no IO. The locale fallback runs through
/// [localeDefaultWeightUnitProvider] so tests can pin a known value
/// without poking the platform dispatcher (architect §3.4).

User _user({WeightUnit weightUnit = WeightUnit.kg}) => User(
      id: 'u_test',
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
      weightUnit: weightUnit,
    );

void main() {
  group('weightUnitProvider', () {
    test('returns the user\'s weightUnit when meProvider resolves', () async {
      final container = ProviderContainer(
        overrides: <Override>[
          meProvider.overrideWith((_) async => _user(weightUnit: WeightUnit.lb)),
        ],
      );
      addTearDown(container.dispose);

      // Resolve `meProvider` first so the derived provider sees `data`.
      await container.read(meProvider.future);
      expect(container.read(weightUnitProvider), WeightUnit.lb);
    });

    test('falls back to locale default while meProvider is loading', () {
      // Future that never completes — pins `meProvider` in `AsyncLoading`.
      final never = Completer<User>();
      addTearDown(() {
        if (!never.isCompleted) never.complete(_user());
      });

      final container = ProviderContainer(
        overrides: <Override>[
          meProvider.overrideWith((_) => never.future),
          // Mock the locale seam so the assertion does not depend on
          // the platform dispatcher's `Locale.countryCode`.
          localeDefaultWeightUnitProvider.overrideWithValue(WeightUnit.st),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(weightUnitProvider), WeightUnit.st);
    });

    test('falls back to locale default when meProvider errors', () async {
      final container = ProviderContainer(
        overrides: <Override>[
          meProvider.overrideWith((_) async => throw StateError('boom')),
          localeDefaultWeightUnitProvider.overrideWithValue(WeightUnit.lb),
        ],
      );
      addTearDown(container.dispose);

      // Let the future settle into `AsyncError`.
      try {
        await container.read(meProvider.future);
      } catch (_) {
        // Expected — `meProvider` is now in `AsyncError`.
      }
      expect(container.read(weightUnitProvider), WeightUnit.lb);
    });

    test(
      'overriding meProvider with WeightUnit.lb flips the provider to lb',
      () async {
        final container = ProviderContainer(
          overrides: <Override>[
            meProvider
                .overrideWith((_) async => _user(weightUnit: WeightUnit.lb)),
          ],
        );
        addTearDown(container.dispose);

        await container.read(meProvider.future);
        expect(container.read(weightUnitProvider), WeightUnit.lb);
      },
    );
  });

  group('onboardingWeightUnitProvider', () {
    test('reads the draft value when set', () {
      final container = ProviderContainer(
        overrides: <Override>[
          // Pin the locale seam to a *different* value so we can prove
          // the draft wins when it carries an explicit selection.
          localeDefaultWeightUnitProvider.overrideWithValue(WeightUnit.kg),
        ],
      );
      addTearDown(container.dispose);

      container
          .read(onboardingDraftProvider.notifier)
          .setWeightUnit(WeightUnit.st);

      expect(container.read(onboardingWeightUnitProvider), WeightUnit.st);
    });

    test('falls back to locale default when the draft has no selection', () {
      final container = ProviderContainer(
        overrides: <Override>[
          localeDefaultWeightUnitProvider.overrideWithValue(WeightUnit.lb),
        ],
      );
      addTearDown(container.dispose);

      // The draft is fresh — `weightUnit` is null.
      expect(
        container.read(onboardingDraftProvider).weightUnit,
        isNull,
      );
      expect(container.read(onboardingWeightUnitProvider), WeightUnit.lb);
    });

    test('flips when the chooser writes a new value into the draft', () {
      final container = ProviderContainer(
        overrides: <Override>[
          localeDefaultWeightUnitProvider.overrideWithValue(WeightUnit.kg),
        ],
      );
      addTearDown(container.dispose);

      // Initial: no draft selection → locale default.
      expect(container.read(onboardingWeightUnitProvider), WeightUnit.kg);

      container
          .read(onboardingDraftProvider.notifier)
          .setWeightUnit(WeightUnit.lb);
      expect(container.read(onboardingWeightUnitProvider), WeightUnit.lb);
    });
  });

  group('OnboardingDraft.weightUnit', () {
    test('copyWith carries the new weightUnit through', () {
      const draft = OnboardingDraft();
      expect(draft.weightUnit, isNull);

      final updated = draft.copyWith(weightUnit: WeightUnit.lb);
      expect(updated.weightUnit, WeightUnit.lb);
    });

    test('equality and hashCode consider the weightUnit field', () {
      const a = OnboardingDraft(weightUnit: WeightUnit.lb);
      const b = OnboardingDraft(weightUnit: WeightUnit.lb);
      const c = OnboardingDraft(weightUnit: WeightUnit.kg);
      const fresh = OnboardingDraft();

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
      expect(a, isNot(fresh));
    });
  });
}
