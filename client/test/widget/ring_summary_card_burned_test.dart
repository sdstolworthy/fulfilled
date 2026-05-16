import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/day_summary.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/meal.dart';
import 'package:fulfilled/domain/user.dart';
import 'package:fulfilled/providers/calorie_providers.dart';
import 'package:fulfilled/providers/profile_providers.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/ring_summary_card.dart';
import 'package:fulfilled/widgets/skeleton.dart';

/// Widget tests for the expanded `RingSummaryCard`'s "Burned" row
/// (T-020 / B8). The row is provider-backed: it renders the formatted
/// kcal value when [caloriesBurnedTodayProvider] resolves, a skeleton
/// while loading, and silently falls back to `'—'` on error.
///
/// All three tests pin `compact: false` so the "Burned" row is in
/// scope — the compact variant intentionally omits it.

DaySummary _summary() {
  return DaySummary(
    date: DateTime(2026, 5, 16),
    kcal: Decimal.fromInt(1288),
    protein: Decimal.fromInt(58),
    carbs: Decimal.fromInt(110),
    fat: Decimal.fromInt(50),
    kcalTarget: Decimal.fromInt(2100),
    proteinTarget: Decimal.fromInt(130),
    carbsTarget: Decimal.fromInt(263),
    fatTarget: Decimal.fromInt(70),
    byMeal: <Meal, MealSubtotal>{
      for (final m in Meal.values) m: MealSubtotal.empty(m),
    },
  );
}

User _seedUser() => User(
      id: 'u_test',
      sex: Sex.male,
      birthDate: DateTime(1993, 4, 12),
      heightCm: Decimal.parse('178'),
      currentWeightKg: Decimal.parse('79.4'),
      activityLevel: ActivityLevel.moderate,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

Widget _harness({
  required List<Override> overrides,
}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: buildLightTheme(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: RingSummaryCard(summary: _summary(), compact: false),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'Burned row renders formatted kcal when provider resolves',
    (tester) async {
      // Pin the upstream profile so the provider resolves
      // deterministically. Seed user from `_fixtures.dart`:
      //   male / 178 cm / 79.4 kg / moderate / age ~33 (DOB 1993-04-12).
      // BMR + activity bands match `estimate.dart` exactly; we only
      // assert the format pattern + `kcal` suffix here — the
      // numeric correctness is covered by the provider unit test.
      await tester.pumpWidget(
        _harness(
          overrides: <Override>[
            meProvider.overrideWith((_) async => _seedUser()),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Burned'), findsOneWidget);
      // No fallback dash on the Burned line — the value resolved.
      // (The Eaten / Goal rows also render values; finding any "—"
      // in the card would only happen if the provider errored.)
      final dashFinder = find.text('—');
      expect(dashFinder, findsNothing);
      // The value is "${formatKcal(kcal)} kcal" — every kv-row value
      // ends with the kcal suffix, so a "kcal" textContaining find
      // surfaces the Burned row alongside Eaten / Goal. We assert
      // three matches: Eaten, Goal, and Burned.
      expect(find.textContaining('kcal'), findsNWidgets(3));
    },
  );

  testWidgets(
    'Burned row renders skeleton while provider is loading',
    (tester) async {
      // Override with a future that never completes — keeps the
      // provider in the loading state for the duration of the test.
      final never = Completer<User>();
      addTearDown(() {
        // Complete the future so Riverpod's internal listeners don't
        // hang the test runtime after teardown.
        if (!never.isCompleted) never.complete(_seedUser());
      });

      await tester.pumpWidget(
        _harness(
          overrides: <Override>[
            meProvider.overrideWith((_) => never.future),
          ],
        ),
      );
      // Don't pumpAndSettle — the provider is intentionally stuck in
      // loading. A single pump is enough to settle the synchronous
      // widget tree below the AsyncValue.
      await tester.pump();

      expect(find.text('Burned'), findsOneWidget);
      // Loading state renders a Skeleton block, not a `—`.
      expect(find.byType(Skeleton), findsWidgets);
      expect(find.text('—'), findsNothing);
    },
  );

  testWidgets(
    'Burned row silently falls back to — when provider errors',
    (tester) async {
      // Fresh user with no profile fields → caloriesBurnedTodayProvider
      // throws, and the consumer must render `—` (not surface).
      final freshUser = User(
        id: 'u_fresh',
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );

      await tester.pumpWidget(
        _harness(
          overrides: <Override>[
            meProvider.overrideWith((_) async => freshUser),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Burned'), findsOneWidget);
      // Exactly one `—` in the card — the Burned row's silent
      // fallback. (Eaten / Goal both render values: `_summary()`
      // pins both `kcal` and `kcalTarget`.)
      expect(find.text('—'), findsOneWidget);
    },
  );
}
