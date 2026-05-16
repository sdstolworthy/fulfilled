import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:fulfilled/widgets/empty_state.dart';
import 'package:fulfilled/widgets/icon_button_36.dart';
import 'package:fulfilled/widgets/meal_section.dart';
import 'package:fulfilled/widgets/primary_button.dart';
import 'package:fulfilled/widgets/ring_summary_card.dart';

import '../../domain/day_summary.dart';
import '../../domain/log_entry.dart';
import '../../domain/meal.dart';
import '../../providers/log_providers.dart';
import '../../providers/repository_providers.dart';
import '../../routing/routes.dart';
import '../../theme/context_extensions.dart';
import '../quick_add/quick_add_sheet.dart';
import 'today_internals.dart';
import 'widgets/log_food_fab.dart';

/// Compact (mobile / narrow-web) variant of screen 01. Renders inside the
/// shell's `AppScaffold`, threading the FAB through the scaffold slot
/// (T-12: the FAB is the only floating action).
///
/// Layout per `screen_01_day_view.html`, post-UX-102:
/// 1. Header row — search icon only (right-aligned). The avatar
///    placeholder and the bolt quick-add icon are gone; the quick-add
///    affordance is now reachable via the FAB long-press menu.
/// 2. Date bar — "Today" + sub-line "Thursday, May 14" + chevron pair.
/// 3. Ring-summary card.
/// 4. Scrollable column of four MealSections.
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
      body: CustomScrollView(
        slivers: <Widget>[
          const SliverToBoxAdapter(child: _CompactHeader()),
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
                data: (s) => RingSummaryCard(summary: s, compact: true),
                loading: () => const TodaySkeleton(
                  height: 196,
                  semanticsLabel: 'Loading today summary',
                ),
                error: (e, _) => TodayErrorCard(message: '$e'),
              ),
            ),
          ),
          // QL-108 — empty-day pill. Renders between the ring summary
          // and the meal sections when `logEntriesProvider(date)` resolves
          // to an empty list (any day, including backdates). The pill
          // disappears the moment the first entry lands because
          // `entriesAsync` is reactive. Uses the lifted `EmptyState`
          // primitive directly — `EmptyState`-style "pill" (not a card).
          SliverToBoxAdapter(
            child: _EmptyDayPill(entriesAsync: entriesAsync),
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
              onAddTap: (Meal _) =>
                  context.push(Routes.foodsSearchPath),
              // LU-005: tapping a logged row opens the LogEntrySheet in
              // edit mode. The handler guards on pending-sync (T-22)
              // and fetches the full Food before opening — see
              // `editLogEntry` for the gates.
              onEntryTap: (entry) => editLogEntry(ref, context, entry),
              // QL-108 — thread the outbox's `isPendingSync` predicate
              // down so `_EntryRow` can render the "Pending sync" badge
              // and pulse it on rejected tap. The compact form factor
              // mounts the outbox-backed `LogRepository` (see
              // `repository_providers.dart`); the predicate returns
              // `false` for ack'd entries.
              isPendingSync: (entry) =>
                  ref.read(logRepositoryProvider).isPendingSync(entry.id),
            ),
          ),
        ],
      ),
    );
  }
}

/// UX-102 — the compact header collapses to a single right-aligned
/// search `IconButton36`. The placeholder avatar (a 36×36 SS-initials
/// circle, PM Risk 2 placeholder until auth) and the bolt
/// "Quick add calories" icon are gone. The bolt's handler moves to the
/// FAB's long-press menu (see `LogFoodFab.onQuickAdd`). Profile is one
/// tap away on the bottom tab bar; carrying a placeholder avatar on the
/// most-viewed screen was the same anti-pattern QL-006 / QL-007 cut for
/// the bookmark and the export row. Architect §6.1 + §6.2.
class _CompactHeader extends StatelessWidget {
  const _CompactHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.space.x5,
        context.space.x1 + 2,
        context.space.x5,
        context.space.x3,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: <Widget>[
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

class _DateBar extends StatelessWidget {
  const _DateBar({required this.date});
  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.space.x5,
        0,
        context.space.x5,
        context.space.x2,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(todayHeadline(date), style: context.text.pageTitle),
                SizedBox(height: context.space.x05),
                Text(
                  todaySubline(date),
                  style: context.text.meta.copyWith(color: colors.ink2),
                ),
              ],
            ),
          ),
          // QL-106 — the pill sits between the title block and the
          // chevrons. Hidden on the local-now day (the chip would tap
          // back to the same view). Tapping calls `context.go(
          // Routes.todayPath)`; backdated users get a one-tap return.
          if (!isLocalNowDay(date)) ...<Widget>[
            const TodayPill(),
            SizedBox(width: context.space.x2),
          ],
          IconButton36(
            icon: Icons.chevron_left,
            tooltip: 'Previous day',
            onPressed: () => navigateDay(context, date, -1),
            color: context.colors.ink2,
          ),
          IconButton36(
            icon: Icons.chevron_right,
            tooltip: 'Next day',
            onPressed: () => navigateDay(context, date, 1),
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
  const _EmptyDayPill({required this.entriesAsync});

  final AsyncValue<List<LogEntry>> entriesAsync;

  @override
  Widget build(BuildContext context) {
    final entries = entriesAsync.valueOrNull;
    if (entries == null || entries.isNotEmpty) {
      return const SizedBox.shrink();
    }
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
        action: SizedBox(
          width: 200,
          child: PrimaryButton(
            dense: true,
            label: 'Log a food',
            onPressed: () => context.push(Routes.foodsSearchPath),
          ),
        ),
      ),
    );
  }
}
