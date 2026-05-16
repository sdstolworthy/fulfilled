import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:fulfilled/widgets/meal_section.dart';
import 'package:fulfilled/widgets/ring_summary_card.dart';

import '../../domain/day_summary.dart';
import '../../domain/log_entry.dart';
import '../../domain/meal.dart';
import '../../providers/log_providers.dart';
import '../../routing/routes.dart';
import '../../theme/context_extensions.dart';
import 'today_internals.dart';
import 'widgets/log_food_fab.dart';

/// Compact (mobile / narrow-web) variant of screen 01. Renders inside the
/// shell's `AppScaffold`, threading the FAB through the scaffold slot
/// (T-12: the FAB is the only floating action).
///
/// Layout per `screen_01_day_view.html`:
/// 1. Header row — avatar + search icon. (Avatar tap is a future Profile
///    deep-link; in v1 it's a no-op so the chrome reads "complete" without
///    a half-wired flow.)
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
            ),
          ),
        ],
      ),
    );
  }
}

class _CompactHeader extends StatelessWidget {
  const _CompactHeader();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.space.x5,
        context.space.x1 + 2,
        context.space.x5,
        context.space.x3,
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: colors.accentSoft,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              'SS', // placeholder initials — the profile provider supplies the real ones once wired
              style: context.text.meta.copyWith(
                color: colors.accent,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
          const Spacer(),
          _IconBtn(
            icon: Icons.search,
            tooltip: 'Search',
            onTap: () => context.push(Routes.foodsSearchPath),
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
          _IconBtn(
            icon: Icons.chevron_left,
            tooltip: 'Previous day',
            onTap: () => navigateDay(context, date, -1),
          ),
          _IconBtn(
            icon: Icons.chevron_right,
            tooltip: 'Next day',
            onTap: () => navigateDay(context, date, 1),
          ),
        ],
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  const _IconBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 24,
        child: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          child: Icon(icon, size: 20, color: context.colors.ink2),
        ),
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
  });

  final DateTime date;
  final AsyncValue<DaySummary> summaryAsync;
  final AsyncValue<List<LogEntry>> entriesAsync;
  final void Function(Meal meal) onAddTap;

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
            ),
          );
        },
        childCount: Meal.values.length,
      ),
    );
  }
}
