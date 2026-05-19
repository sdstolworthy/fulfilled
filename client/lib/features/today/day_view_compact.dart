import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:fulfilled/widgets/empty_state.dart';
import 'package:fulfilled/widgets/icon_button_36.dart';
import 'package:fulfilled/widgets/meal_section.dart';
import 'package:fulfilled/widgets/primary_button.dart';
import 'package:fulfilled/widgets/quick_add_chips.dart';
import 'package:fulfilled/widgets/ring_summary_card.dart';

import '../../domain/day_summary.dart';
import '../../domain/food.dart';
import '../../domain/log_entry.dart';
import '../../domain/meal.dart';
import '../../providers/calorie_providers.dart';
import '../../providers/food_providers.dart';
import '../../providers/goal_providers.dart';
import '../../providers/log_providers.dart';
import '../../providers/repository_providers.dart';
import '../../routing/routes.dart';
import '../../theme/context_extensions.dart';
import '../log_entry/edit_log_entry_action.dart';
import '../log_entry/log_entry_sheet.dart';
import '../quick_add/quick_add_sheet.dart';
import 'today_internals.dart';
import 'widgets/copy_day_sheet.dart';
import 'widgets/log_food_fab.dart';

/// Compact (mobile / narrow-web) variant of screen 01. Renders inside the
/// shell's `AppScaffold`, threading the FAB through the scaffold slot
/// (T-12: the FAB is the only floating action).
///
/// Layout per `screen_01_day_view.html`, post-UX-104:
/// 1. Date bar — centered `DatePill` (+ optional `TodayPill` on
///    backdated views), with the search icon pinned to the trailing
///    edge. The pre-UX-104 chevron pair is gone (per-day nav: swipe
///    UX-103, or the date picker the `DatePill` tap opens) and the
///    separate `_CompactHeader` row collapses into this single band.
/// 2. Ring-summary card.
/// 3. Scrollable column of four MealSections.
class DayViewCompact extends ConsumerWidget {
  const DayViewCompact({required this.date, super.key});

  /// The local-calendar day this view is rendering. The screen-root widget
  /// resolves "now" once (T-16) and threads it down so date arithmetic is
  /// not duplicated across leaves.
  final DateTime date;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summaryAsync = ref.watch(daySummaryProvider(date));
    final entriesAsync = ref.watch(logEntriesProvider(date));
    // Provider reads lifted out of the (former) `_BurnedKvRow` and
    // `_WeekProgressPill` ConsumerWidgets so `RingSummaryCard` itself
    // stays a pure presentation leaf (testing_guide.md §4.4).
    //
    // Burned kcal is only surfaced on the expanded right-rail card —
    // compact omits the row — but resolving it here keeps the
    // container symmetrical with `day_view_expanded.dart` and the
    // provider is already in scope for the macro/ring math elsewhere.
    final burnedKcal = ref.watch(caloriesBurnedTodayProvider).valueOrNull;
    final weeklyLogDays = ref.watch(weeklyLogDaysProvider).valueOrNull ?? 0;
    // For *today*, the kcal target shown in the ring is derived from
    // the current profile + goal intent — not the stored snapshot on
    // the goal record (which can drift after a profile edit until
    // the user re-saves the goal). For past days we trust the BE's
    // value: it's the closest thing we have to a per-day historical
    // snapshot of the target the user was logging against.
    final effective = isLocalNowDay(date)
        ? ref.watch(effectiveActiveGoalTargetsProvider)
        : null;

    // The outer `ShellRoute` already wraps this widget in `AppScaffold`,
    // so we render a transparent inner `Scaffold` here purely to attach
    // the FAB — wrapping in `AppScaffold` again would stack two
    // `NavigationBar`s on top of each other.
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: LogFoodFab(
        onPressed: () => context.push(Routes.foodsSearchPath),
        // UX-102: the bolt icon's prior handler moves from
        // `_CompactHeader` into the FAB's long-press menu.
        onQuickAdd: () => showQuickAddSheet(context),
      ),
      // UX-103: horizontal-swipe-to-change-day wraps the scrollable body
      // (and only the body — not the FAB or shell chrome). The wrap is
      // translucent so vertical drags pass through to the
      // `CustomScrollView`'s scroll gesture; only horizontal flings past
      // the 200 px/s floor route via `navigateDay`.
      body: DaySwipeWrap(
        date: date,
        child: CustomScrollView(
          slivers: <Widget>[
            // UX-104 — the header row merges the date affordance and the
            // search icon into one band. `_DateBar` renders the centered
            // `DatePill` (+ optional `TodayPill`) with the search
            // `IconButton36` pinned to the trailing edge. The standalone
            // `_CompactHeader` row is gone; this is the single-row layout
            // the ticket's "compact visual" line specifies.
            SliverToBoxAdapter(child: _DateBar(date: date)),
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  context.space.x5,
                  context.space.x2,
                  context.space.x5,
                  context.space.x3 + 2,
                ),
                child: summaryAsync.when(
                  data: (s) => RingSummaryCard(
                    summary: overrideDaySummaryWithEffective(s, effective),
                    compact: true,
                    burnedKcal: burnedKcal,
                    weeklyLogDays: weeklyLogDays,
                  ),
                  loading: () => const RingSummaryCardSkeleton(compact: true),
                  error: (e, _) => TodayErrorCard(message: '$e'),
                ),
              ),
            ),
            // UX-107 F2 — Recent-foods chip strip. Sits between the
            // ring summary card and the empty-day pill / meal grid.
            // Today-only, ≥ 4 recents floor (per PM doc §2 F2 AC); the
            // wrapper widget owns the gates and the
            // `showLogEntrySheet(food, defaultMeal)` tap binding so
            // `QuickAddChips` itself stays gate-free.
            SliverToBoxAdapter(child: _TodayRecentChipsRow(date: date)),
            // QL-108 — empty-day pill. Renders between the ring summary
            // and the meal sections when `logEntriesProvider(date)`
            // resolves to an empty list (any day, including backdates).
            // The pill disappears the moment the first entry lands
            // because `entriesAsync` is reactive. Uses the lifted
            // `EmptyState` primitive directly — `EmptyState`-style
            // "pill" (not a card).
            SliverToBoxAdapter(
              child: _EmptyDayPill(
                date: date,
                entriesAsync: entriesAsync,
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                context.space.x5,
                0,
                context.space.x5,
                context.space.x6 * 5, // generous bottom inset for the FAB
              ),
              sliver: _MealsSliver(
                date: date,
                summaryAsync: summaryAsync,
                entriesAsync: entriesAsync,
                // Thread the meal hint through `?meal=<wire>` so the
                // search → detail → log-entry-sheet chain can default
                // the meal picker to the section the user tapped under
                // instead of falling back to `mealForLocalTime`.
                onAddTap: (Meal m) => context.push(
                  '${Routes.foodsSearchPath}?meal=${m.wire}',
                ),
                // LU-005: tapping a logged row opens the LogEntrySheet
                // in edit mode. The handler guards on pending-sync
                // (T-22) and fetches the full Food before opening —
                // see `editLogEntry` for the gates.
                onEntryTap: (entry) => editLogEntry(ref, context, entry),
                // QL-108 — thread the outbox's `isPendingSync` predicate
                // down so `_EntryRow` can render the "Pending sync"
                // badge and pulse it on rejected tap. The compact form
                // factor mounts the outbox-backed `LogRepository` (see
                // `repository_providers.dart`); the predicate returns
                // `false` for ack'd entries.
                isPendingSync: (entry) =>
                    ref.read(logRepositoryProvider).isPendingSync(entry.id),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// UX-104 — single-row compact header. Centered `DatePill` (+ optional
/// `TodayPill` on backdated views), with the search `IconButton36`
/// pinned to the trailing edge. The pre-UX-104 layout had two stacked
/// rows: a right-aligned search row (`_CompactHeader`) above a left-
/// aligned title block flanked by chevron `IconButton36`s. The chevrons
/// are gone (per-day navigation is now swipe — UX-103 — or the date
/// picker the `DatePill` tap opens), the title block collapses into the
/// pill, and the search icon merges into the same row. Net: one band
/// of chrome above the ring summary card instead of two.
///
/// Architect §6.1 + §6.2 + §6.3.
class _DateBar extends StatelessWidget {
  const _DateBar({required this.date});
  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final showTodayPill = !isLocalNowDay(date);
    // The trailing search `IconButton36` reserves ~36 px on the right.
    // We pad the leading edge by the same amount so the
    // `DatePill` + `TodayPill` cluster sits visually centred in the row
    // without needing a separate `Stack`/`Align`.
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.space.x5,
        context.space.x1 + 2,
        context.space.x5,
        context.space.x2,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          // Leading spacer mirrors the trailing search button's footprint
          // (~36 px) so the centre cluster lands on the row's true
          // midline.
          const SizedBox(width: 36),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.max,
              children: <Widget>[
                DatePill(date: date),
                if (showTodayPill) ...<Widget>[
                  SizedBox(width: context.space.x2),
                  const TodayPill(),
                ],
              ],
            ),
          ),
          IconButton36(
            icon: Icons.search,
            tooltip: 'Search',
            onPressed: () => context.push(Routes.foodsSearchPath),
            color: context.colors.ink2,
          ),
        ],
      ),
    );
  }
}

class _MealsSliver extends StatelessWidget {
  const _MealsSliver({
    required this.date,
    required this.summaryAsync,
    required this.entriesAsync,
    required this.onAddTap,
    required this.onEntryTap,
    required this.isPendingSync,
  });

  final DateTime date;
  final AsyncValue<DaySummary> summaryAsync;
  final AsyncValue<List<LogEntry>> entriesAsync;
  final void Function(Meal meal) onAddTap;
  final void Function(LogEntry entry) onEntryTap;

  /// Predicate the meal section threads to `_EntryRow` so each row
  /// renders the "Pending sync" badge and pulses it on rejected tap
  /// (QL-108). Read from `LogRepository.isPendingSync` upstream.
  final bool Function(LogEntry entry) isPendingSync;

  @override
  Widget build(BuildContext context) {
    final summary = summaryAsync.valueOrNull;
    final entries = entriesAsync.valueOrNull;

    // Loading: skeleton list. T-08 — skeletons that match final layout
    // (one rectangle per meal at meal-section height).
    if (summary == null || entries == null) {
      return SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, i) => Padding(
            padding: EdgeInsets.only(bottom: context.space.x3),
            child: const TodaySkeleton(
              height: 160,
              semanticsLabel: 'Loading meal',
            ),
          ),
          childCount: Meal.values.length,
        ),
      );
    }

    final byMeal = entriesByMeal(entries);

    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, i) {
          final meal = Meal.values[i];
          final subtotal = summary.byMeal[meal] ?? MealSubtotal.empty(meal);
          return Padding(
            padding: EdgeInsets.only(bottom: context.space.x3),
            child: MealSection(
              subtotal: subtotal,
              entries: byMeal[meal] ?? const <LogEntry>[],
              onAddTap: () => onAddTap(meal),
              onEntryTap: onEntryTap,
              isPendingSync: isPendingSync,
              // UX-106 F1 — per-meal copy-day. Threads through to
              // `showCopyDaySheet` with the section's meal preselected.
              // The sheet's post-save flow routes via `context.go(
              // pathForDay(targetDate))` (T-24); no extra routing here.
              onCopyMeal: (m) => showCopyDaySheet(
                context,
                targetDate: date,
                preselectMeals: <Meal>[m],
              ),
            ),
          );
        },
        childCount: Meal.values.length,
      ),
    );
  }
}

/// Empty-day pill (QL-108). Renders between the ring summary and the
/// meal sections when the day's `logEntriesProvider` resolves to an
/// empty list. The pill is hidden while entries are loading (skeletons
/// upstream cover that frame) and on the error branch (the
/// `TodayErrorCard` already communicates "we couldn't load your day").
/// The moment the first entry lands `entriesAsync` re-emits a non-empty
/// list and the pill disappears on the next frame.
///
/// Uses the lifted `EmptyState` primitive directly so every "no items
/// here" surface picks up the same icon size, text scale, and `ink2/ink3`
/// token wash. Not a card — the pill is informational and does not draw
/// a surface border. `Icons.eco_outlined` matches the day-view's
/// "fresh-start" affordance; the action is a dense `PrimaryButton` that
/// pushes the search route.
class _EmptyDayPill extends StatelessWidget {
  const _EmptyDayPill({required this.date, required this.entriesAsync});

  /// The day this view is rendering. Threaded so the secondary
  /// "Copy from another day" affordance can pass `targetDate: date` to
  /// `showCopyDaySheet`, and so the today-only gate can compare against
  /// `isLocalNowDay(date)`.
  final DateTime date;

  final AsyncValue<List<LogEntry>> entriesAsync;

  @override
  Widget build(BuildContext context) {
    final entries = entriesAsync.valueOrNull;
    if (entries == null || entries.isNotEmpty) {
      return const SizedBox.shrink();
    }
    // UX-106 F1 — the "Copy from another day" secondary affordance only
    // renders on the local-now day. Backdated empty days keep the
    // pre-UX-106 "Log a food only" shape per architect §3.4 (B) and
    // PM §2 F1 AC ("only renders when the current day is empty").
    final showCopyFrom = isLocalNowDay(date);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.space.x5,
        0,
        context.space.x5,
        context.space.x3,
      ),
      child: EmptyState(
        key: const Key('empty-day-pill'),
        icon: Icons.eco_outlined,
        title: 'No food logged for this day',
        body: '',
        action: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: 200,
              child: PrimaryButton(
                dense: true,
                label: 'Log a food',
                onPressed: () => context.push(Routes.foodsSearchPath),
              ),
            ),
            if (showCopyFrom) ...<Widget>[
              SizedBox(height: context.space.x2),
              _EmptyDayCopyFromButton(date: date),
            ],
          ],
        ),
      ),
    );
  }
}

/// UX-107 F2 — Today-compact recent-foods chip strip wrapper.
///
/// Hosts the lifted `QuickAddChips` in its `compact: true` mode between
/// the `RingSummaryCard` and the `_EmptyDayPill`. Owns the two gates so
/// `QuickAddChips` itself stays gate-free:
///
/// 1. **Today-only.** The strip only renders when the day view is
///    showing the local-now day (`isLocalNowDay(date)`). Backdated days
///    hide the strip entirely; the per-meal copy affordance (UX-106) is
///    the right scope for re-logging onto past days. Per PM doc §2 F2.
/// 2. **≥ 4 recents.** When the user has fewer than four recent foods
///    the strip is hidden — the long-tail signal isn't worth the
///    surface area at three or fewer chips. Empty / loading recents
///    also hide; no skeleton, no placeholder. Architect §4.5 / PM doc
///    §2 F2 AC.
///
/// Tap behavior: `showLogEntrySheet(context, food: f, defaultMeal:
/// mealForLocalTime(now))`. Create-mode, pre-seeded with the chosen
/// food and the time-of-day meal default — explicitly **not** one-tap
/// commit. The sheet handles the rest. Architect §4.4.
class _TodayRecentChipsRow extends ConsumerWidget {
  const _TodayRecentChipsRow({required this.date});

  final DateTime date;

  /// PM doc §2 F2 AC floor — fewer than four recents hides the strip.
  /// The wrapper owns this gate (not `QuickAddChips`) so the widget
  /// stays reusable for surfaces that want chips on smaller counts.
  static const int _minRecents = 4;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!isLocalNowDay(date)) return const SizedBox.shrink();

    final recentsAsync = ref.watch(recentFoodsProvider);
    final recents = recentsAsync.valueOrNull ?? const <Food>[];
    if (recents.length < _minRecents) return const SizedBox.shrink();

    return Padding(
      padding: EdgeInsets.only(bottom: context.space.x3),
      child: QuickAddChips(
        key: const Key('today-recent-chips-row'),
        compact: true,
        recents: recents,
        frequents: const <Food>[],
        onTapFood: (food) => showLogEntrySheet(
          context,
          food: food,
          // Time-of-day meal default. The sheet ignores this in edit
          // mode but we're always in create here.
          defaultMeal: mealForLocalTime(DateTime.now()),
        ),
      ),
    );
  }
}

/// UX-106 F1 — secondary "Copy from another day" affordance inside the
/// empty-day pill. Sits below the primary "Log a food" button and is a
/// `TextButton`-shaped low-prominence link (architect §3.4 (B): the PM
/// names a "text-shaped secondary affordance"; the primary stays
/// primary). Tap opens `showCopyDaySheet(context, targetDate: date)`
/// with no meal preselect → the sheet's chip strip defaults to
/// "All meals". Today-only by construction; the parent `_EmptyDayPill`
/// already gates this widget on `isLocalNowDay(date)`.
class _EmptyDayCopyFromButton extends StatelessWidget {
  const _EmptyDayCopyFromButton({required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    // T-20 — merge the icon + label glyphs into a single screen-reader
    // announcement ("Copy from another day, open copy sheet"). The
    // TextButton's own button role is retained.
    return MergeSemantics(
      child: Semantics(
        label: 'Copy from another day, open copy sheet',
        child: TextButton(
          key: const Key('empty-day-copy-from'),
          onPressed: () => showCopyDaySheet(
            context,
            targetDate: date,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                'Copy from another day',
                style: context.text.meta.copyWith(
                  color: colors.accent,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 16, color: colors.accent),
            ],
          ),
        ),
      ),
    );
  }
}
