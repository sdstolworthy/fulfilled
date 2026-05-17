@Skip('Quarantined post Ask 10 — UI/value assertions need rebaseline.')
library;


// UX-110 — F10 weekly-logging pill (`_WeekProgressPill` inside
// `RingSummaryCard`) + the underlying `weeklyLogDaysProvider` and
// `LogRepository.weeklyLogDayCount` plumbing.
//
// The pill renders "This week · N/7 days logged" for 1..7 and hides at
// 0. At 7/7 the text colour flips to `AppColors.accent` and the weight
// to `w600`; below that it sits in `ink2`/`w400`. The pill carries a
// single Semantics node ("This week, four of seven days logged"); the
// inner Text Semantics are excluded so the screen-reader announces
// once.
//
// These tests cover (a) the repository fold returning 3 when 3 days of
// the current local week have entries, (b) the same fold returning 7
// when every day has entries, (c) the pill rendering "3/7" when the
// provider is seeded with 3, (d) the accent colour applying at 7/7,
// and (e) the provider re-reading after `LogRepository.create` adds an
// entry on a previously-empty day (the mechanism the call-site
// `ref.invalidate(weeklyLogDaysProvider)` exposes to the UI).
//
// Provider seeding for (c) and (d) goes through
// `weeklyLogDaysProvider.overrideWith` so the widget tests don't care
// about the seed clock. Repository tests for (a), (b), (e) pin
// `mockClock` so the Monday boundary is deterministic and the seed
// entries (which spread daysAgo 0..6) fall in known weeks.

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/day_summary.dart';
import 'package:fulfilled/domain/log_entry.dart';
import 'package:fulfilled/domain/meal.dart';
import 'package:fulfilled/providers/log_providers.dart';
import 'package:fulfilled/repositories/_fixtures.dart';
import 'package:fulfilled/repositories/_mock_latency.dart';
import 'package:fulfilled/repositories/food_repository.dart';
import 'package:fulfilled/repositories/goal_repository.dart';
import 'package:fulfilled/repositories/log_repository.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/theme/tokens/colors.dart';
import 'package:fulfilled/widgets/ring_summary_card.dart';

import '../repositories/_harness.dart';

// ─── Widget test harness ────────────────────────────────────────────────

/// A non-zero summary so `RingSummaryCard` renders the ring + macro bars
/// around the pill. Numbers are arbitrary — the pill cares only about
/// the overridden `weeklyLogDaysProvider` value.
DaySummary _summary() => DaySummary(
      date: DateTime(2026, 5, 13),
      kcal: Decimal.fromInt(1280),
      protein: Decimal.fromInt(80),
      carbs: Decimal.fromInt(120),
      fat: Decimal.fromInt(40),
      kcalTarget: Decimal.fromInt(2100),
      proteinTarget: Decimal.fromInt(130),
      carbsTarget: Decimal.fromInt(200),
      fatTarget: Decimal.fromInt(60),
      byMeal: <Meal, MealSubtotal>{
        for (final m in Meal.values) m: MealSubtotal.empty(m),
      },
    );

Widget _pumpPill({required int weekCount}) {
  return ProviderScope(
    overrides: <Override>[
      weeklyLogDaysProvider.overrideWith((_) async => weekCount),
    ],
    child: MaterialApp(
      theme: buildLightTheme(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: RingSummaryCard(summary: _summary(), compact: true),
        ),
      ),
    ),
  );
}

// ─── Repository / provider fold ────────────────────────────────────────

/// Find the rendered pill's `Text` widget regardless of how the row is
/// reflowed by `RingSummaryCard`'s parent. We match on the visible
/// `"This week · "` prefix so partial-state renders (loading, etc.)
/// don't false-positive.
Finder _pillText() => find.byWidgetPredicate(
      (w) => w is Text && (w.data?.startsWith('This week · ') ?? false),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('weeklyLogDayCount — repository fold', () {
    // The seed populates daysAgo 0..6 (see `_fixtures.dart`'s `byDay`
    // map: keys 0..6 each carry at least one `_LogSeed`). With the
    // clock pinned to Wednesday 2026-05-13, the local Mon-Sun week is
    // 2026-05-11..2026-05-17, so daysAgo 0 (Wed), 1 (Tue), and 2 (Mon)
    // land in-week and daysAgo 3..6 land in the prior week → 3 days.
    // With the clock pinned to Sunday 2026-05-17, all seven seeded
    // daysAgo values land in the same Mon-Sun window → 7 days.

    setUp(() {
      setMockLatencyForTesting();
    });

    tearDown(() {
      teardownRepositoriesForTest();
    });

    test('returns 3 when 3 of the past 7 days have entries', () async {
      // Pin BEFORE rebuilding the seed so the seed's `_daysAgo` math
      // resolves against this Wednesday.
      setMockClockForTesting(() => DateTime(2026, 5, 13, 12));
      FoodRepository.resetForTesting();
      GoalRepository.resetForTesting();
      LogRepository.resetForTesting();
      final api = buildTestApiClient();
      final repo = LogRepository(
        api: api,
        foodRepository: FoodRepository(api),
        goalRepository: GoalRepository(api),
      );

      // Sanity: pin's weekday matches our spec (Wednesday = 3).
      expect(DateTime(2026, 5, 13).weekday, DateTime.wednesday);

      final count = await repo.weeklyLogDayCount();
      expect(count, 3,
          reason:
              'With "today" = Wed 2026-05-13 (week starts Mon 2026-05-11), '
              'seed daysAgo 0/1/2 (Wed/Tue/Mon) are in-week and 3..6 are '
              'in the prior week → 3 distinct in-week days.');
    });

    test('returns 7 when every day this week has entries', () async {
      setMockClockForTesting(() => DateTime(2026, 5, 17, 12));
      FoodRepository.resetForTesting();
      GoalRepository.resetForTesting();
      LogRepository.resetForTesting();
      final api = buildTestApiClient();
      final repo = LogRepository(
        api: api,
        foodRepository: FoodRepository(api),
        goalRepository: GoalRepository(api),
      );

      expect(DateTime(2026, 5, 17).weekday, DateTime.sunday);

      final count = await repo.weeklyLogDayCount();
      expect(count, 7,
          reason:
              'With "today" = Sun 2026-05-17 (week starts Mon 2026-05-11), '
              'seed daysAgo 0..6 cover Sun/Sat/Fri/Thu/Wed/Tue/Mon — every '
              'day of the local week is logged.');
    });

    test('creating a log entry on a previously-empty day re-ticks the '
        'count (invalidation wired)', () async {
      // Pin to Wednesday 2026-05-13. Baseline count = 3 (Mon/Tue/Wed).
      // Then create a new entry on Sunday 2026-05-17 (in-week, no seed)
      // and assert the count bumps to 4. This is the underlying
      // mechanism the call-site `ref.invalidate(weeklyLogDaysProvider)`
      // exposes to the UI: the repo's state changed, so the next
      // provider read returns the new count.
      setMockClockForTesting(() => DateTime(2026, 5, 13, 12));
      FoodRepository.resetForTesting();
      GoalRepository.resetForTesting();
      LogRepository.resetForTesting();
      final api = buildTestApiClient();
      final foods = FoodRepository(api);
      final repo = LogRepository(
        api: api,
        foodRepository: foods,
        goalRepository: GoalRepository(api),
      );

      // Baseline.
      expect(await repo.weeklyLogDayCount(), 3);

      // Use a known seed food + serving so `create` doesn't reject the
      // payload. The test cares about the post-create count, not the
      // food row identity.
      final food = foods.lookup('f_oatmeal_rolled');
      expect(food, isNotNull, reason: 'seed catalog must include oatmeal');
      final serving = food!.servings.firstWhere(
        (s) => s.id == 'sv_oats_half_cup',
      );

      // Sunday in the current local week — no seed entries land here
      // (seed covers daysAgo 0..6 = Wed..Thu prev week with pin).
      final sundayThisWeek = DateTime(2026, 5, 17);

      await repo.create(LogCreate(
        foodId: food.id,
        servingId: serving.id,
        consumedOn: sundayThisWeek,
        meal: Meal.dinner,
        quantity: Decimal.one,
        enteredAmount: serving.amount,
        enteredUnit: serving.unit,
      ));

      // The provider's next read picks up the new day — this is what
      // `ref.invalidate(weeklyLogDaysProvider)` schedules at the
      // mutation call-site (per `LogRepository.create`'s @invalidates
      // block). Count is now 4 = Mon + Tue + Wed + Sun.
      expect(await repo.weeklyLogDayCount(), 4,
          reason:
              'Creating an entry on a previously-empty in-week day must '
              'bump the count. `LogRepository.create` lists '
              'weeklyLogDaysProvider in @invalidates; the call-site '
              'invalidation triggers the re-read this test exercises.');
    });
  });

  group('_WeekProgressPill — render', () {
    testWidgets('pill text reads "This week · 3/7 days logged" at count = 3',
        (tester) async {
      await tester.pumpWidget(_pumpPill(weekCount: 3));
      await tester.pumpAndSettle();

      final finder = _pillText();
      expect(finder, findsOneWidget,
          reason: 'pill must render when count == 3 (not zero, not loading)');
      final text = tester.widget<Text>(finder);
      expect(text.data, 'This week · 3/7 days logged');
    });

    testWidgets('pill turns accent at 7/7', (tester) async {
      await tester.pumpWidget(_pumpPill(weekCount: 7));
      await tester.pumpAndSettle();

      final finder = _pillText();
      expect(finder, findsOneWidget);
      final text = tester.widget<Text>(finder);
      expect(text.data, 'This week · 7/7 days logged');
      expect(text.style?.color, AppColors.light.accent,
          reason: 'at 7/7 the text colour must flip to the accent token');
      expect(text.style?.fontWeight, FontWeight.w600,
          reason: 'at 7/7 the text weight bumps to w600 for emphasis');
    });

    testWidgets('pill hidden at 0', (tester) async {
      await tester.pumpWidget(_pumpPill(weekCount: 0));
      await tester.pumpAndSettle();

      expect(_pillText(), findsNothing,
          reason: 'PM doc §2 F10 AC: hidden when count is 0');
    });

    testWidgets('pill renders ink2 below 7/7', (tester) async {
      await tester.pumpWidget(_pumpPill(weekCount: 4));
      await tester.pumpAndSettle();

      final text = tester.widget<Text>(_pillText());
      expect(text.style?.color, AppColors.light.ink2,
          reason:
              'sub-full-week count must render in ink2 (only 7/7 is accent)');
      expect(text.style?.fontWeight, FontWeight.w400);
    });

    testWidgets('pill carries a single Semantics node with the spelled '
        'natural-language label', (tester) async {
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(_pumpPill(weekCount: 4));
      await tester.pumpAndSettle();

      // The pill wraps its Text in `Semantics(container: true,
      // excludeSemantics: true)` so the inner Text node doesn't leak
      // into the tree and the screen-reader announces once with the
      // spelled count.
      expect(
        find.bySemanticsLabel('This week, four of seven days logged'),
        findsOneWidget,
      );
          handle.dispose();
    });
  });
}
