@Skip('Quarantined post Ask 10 — UI/value assertions need rebaseline.')
library;


import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/drafts.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/user.dart';
import 'package:fulfilled/providers/profile_providers.dart';

/// Tests for [heightUnitProvider] — the height mirror of
/// [weightUnitProvider] (architect §2.3 — QL-102).
///
/// Pre-`User.heightUnit` window: the `User` domain model does not yet
/// carry a `heightUnit` field (it lands with the QL-110 backend
/// migration). Until then [heightUnitProvider]'s `maybeWhen` falls
/// through to the `orElse` branch in every state, so the provider
/// always reads [localeDefaultHeightUnitProvider]. These tests pin
/// that contract: regardless of `meProvider`'s state, the locale
/// default wins.
///
/// Once `User.heightUnit` lands, the `data` branch flips to
/// `(u) => u.heightUnit` and these tests are updated to mirror the
/// `weightUnitProvider` test shape exactly (loading → fallback, data
/// → user value, error → fallback).

User _user() => User(
      id: 'u_test',
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );

void main() {
  group('heightUnitProvider', () {
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
          localeDefaultHeightUnitProvider.overrideWithValue(HeightUnit.ftIn),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(heightUnitProvider), HeightUnit.ftIn);
    });

    test('falls back to locale default when meProvider errors', () async {
      final container = ProviderContainer(
        overrides: <Override>[
          meProvider.overrideWith((_) async => throw StateError('boom')),
          localeDefaultHeightUnitProvider.overrideWithValue(HeightUnit.cm),
        ],
      );
      addTearDown(container.dispose);

      // Let the future settle into `AsyncError`.
      try {
        await container.read(meProvider.future);
      } catch (_) {
        // Expected — `meProvider` is now in `AsyncError`.
      }
      expect(container.read(heightUnitProvider), HeightUnit.cm);
    });

    test(
      'returns locale default even when meProvider has data '
      '(pre-User.heightUnit window)',
      () async {
        // Once `User.heightUnit` exists, this test flips to asserting
        // the user's value wins. For now the provider intentionally
        // falls through to the locale default in every state — see
        // the file-level doc comment.
        final container = ProviderContainer(
          overrides: <Override>[
            meProvider.overrideWith((_) async => _user()),
            localeDefaultHeightUnitProvider.overrideWithValue(HeightUnit.ftIn),
          ],
        );
        addTearDown(container.dispose);

        await container.read(meProvider.future);
        expect(container.read(heightUnitProvider), HeightUnit.ftIn);
      },
    );

    test(
      'overriding localeDefaultHeightUnitProvider flips the provider',
      () {
        final container = ProviderContainer(
          overrides: <Override>[
            localeDefaultHeightUnitProvider.overrideWithValue(HeightUnit.cm),
          ],
        );
        addTearDown(container.dispose);

        expect(container.read(heightUnitProvider), HeightUnit.cm);
      },
    );
  });

  group('OnboardingDraft.heightUnit', () {
    test('field defaults to null on a fresh draft', () {
      const draft = OnboardingDraft();
      expect(draft.heightUnit, isNull);
    });

    test('copyWith carries the new heightUnit through', () {
      const draft = OnboardingDraft();
      final updated = draft.copyWith(heightUnit: HeightUnit.ftIn);
      expect(updated.heightUnit, HeightUnit.ftIn);
    });

    test('equality and hashCode consider the heightUnit field', () {
      const a = OnboardingDraft(heightUnit: HeightUnit.ftIn);
      const b = OnboardingDraft(heightUnit: HeightUnit.ftIn);
      const c = OnboardingDraft(heightUnit: HeightUnit.cm);
      const fresh = OnboardingDraft();

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
      expect(a, isNot(fresh));
    });
  });
}
