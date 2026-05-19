import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:fulfilled/widgets/empty_state.dart';
import 'package:fulfilled/widgets/icon_button_36.dart';
import 'package:fulfilled/widgets/meal_section.dart';
import 'package:fulfilled/widgets/primary_button.dart';
import 'package:fulfilled/widgets/ring_summary_card.dart';

import 'package:decimal/decimal.dart';

import '../../domain/calories/estimate.dart';
import '../../domain/day_summary.dart';
import '../../domain/enums.dart';
import '../../domain/food.dart';
import '../../domain/log_entry.dart';
import '../../domain/meal.dart';
import '../../domain/weight.dart';
import '../../providers/calorie_providers.dart';
import '../../providers/food_providers.dart';
import '../../providers/goal_providers.dart';
import '../../providers/log_providers.dart';
import '../../providers/profile_providers.dart';
import '../../providers/repository_providers.dart';
import '../../providers/weight_providers.dart';
import '../../routing/routes.dart';
import '../../theme/context_extensions.dart';
import '../log_entry/edit_log_entry_action.dart';
import '../log_entry/log_entry_sheet.dart';
import '../quick_add/quick_add_sheet.dart';
import 'today_internals.dart';
import 'package:fulfilled/widgets/quick_add_chips.dart';
import 'widgets/copy_day_sheet.dart';
import 'widgets/mini_weight_sparkline.dart';

/// Expanded (desktop / iPad-landscape) variant of screen 01.
///
/// Layout per `screen_01_day_view_web.html`, post-UX-104:
/// - Top bar (rendered by `AppScaffold.topBarTrailing`): page title +
///   single tappable `DatePill` (+ optional `TodayPill` on backdated
///   views) + search input stub + primary "Log food" button. The prior
///   chevron-flanked date title is gone; per-day navigation is the
///   swipe gesture (UX-103) or the date picker the `DatePill` tap
///   opens.
/// - Body: 2-column content. Left = 2×2 meal grid. Right rail (≥ 1024
///   only) = stack of three cards: ring-summary, quick-add chips, mini
///   weight sparkline.
///
/// **Right-rail threshold.** Per architecture §1, the right rail is
/// expanded-only (≥ 1024 px). This widget is mounted only at expanded
/// breakpoints by [TodayScreen], so the rail unconditionally renders.
class DayViewExpanded extends ConsumerWidget {
  const DayViewExpanded({required this.date, super.key});

  final DateTime date;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summaryAsync = ref.watch(daySummaryProvider(date));
    final entriesAsync = ref.watch(logEntriesProvider(date));
    final recentsAsync = ref.watch(recentFoodsProvider);
    final frequentsAsync = ref.watch(frequentFoodsProvider);
    final weightAsync = ref.watch(weightSeriesProvider(WeightRange.oneMonth));
    final weightUnit = ref.watch(weightUnitProvider);
    // Provider reads lifted out of the (former) `_BurnedKvRow` and
    // `_WeekProgressPill` ConsumerWidgets inside `RingSummaryCard`
    // (testing_guide.md §4.4 passive-view rule). The card is now a
    // pure presentation leaf taking resolved values.
    final burnedKcal = ref.watch(caloriesBurnedTodayProvider).valueOrNull;
    final weeklyLogDays = ref.watch(weeklyLogDaysProvider).valueOrNull ?? 0;
    // For today's date the ring's kcal/macro targets are *derived*
    // from the live profile + active-goal intent; the BE-returned
    // stored values are a snapshot and drift after profile edits.
    // Past days keep the BE value (per-day historical snapshot).
    final effective = isLocalNowDay(date)
        ? ref.watch(effectiveActiveGoalTargetsProvider)
        : null;

    // The outer `ShellRoute` already wraps this widget in `AppScaffold`
    // (which is what renders the sidebar nav on expanded). Wrapping again
    // would stack two sidebars — and on top of that, the inner
    // `AppScaffold`'s `topBarTrailing` slot never reaches the outer
    // shell, so the date chevrons + search + Log food button would
    // silently disappear. Inlining them at the top of the body is the
    // simplest fix for v1.
    return LayoutBuilder(
      builder: (context, constraints) {
        // The mock pins the right rail at 360 px; everything else flows.
        // UX-103: wrap the scrollable region in `DaySwipeWrap` so left/
        // right flings change day. The wrap is translucent — vertical
        // drags fall through to the `SingleChildScrollView`. We wrap
        // only the body's scroll content (not the inline date chevrons
        // row in the header above, which is itself part of the column
        // inside the scroll view).
        return DaySwipeWrap(
          date: date,
          child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            context.space.x8,
            context.space.x6,
            context.space.x8,
            context.space.x6,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text('Today', style: context.text.pageTitle),
                  const Spacer(),
                  // UX-104 — replaces the prior `_DateChevrons` cluster
                  // (chevron + boxed date title + chevron). The single
                  // `DatePill` is the date affordance; tap opens a date
                  // picker bounded to [today - 60 days, today]. Per-day
                  // navigation is the swipe gesture (UX-103). The
                  // `TodayPill` continues to flank the pill on backdated
                  // views — QL-009 behaviour unchanged.
                  DatePill(date: date),
                  if (!isLocalNowDay(date)) ...<Widget>[
                    SizedBox(width: context.space.x2),
                    const TodayPill(),
                  ],
                  SizedBox(width: context.space.x4),
                  _TopSearchField(
                    onTap: () => context.push(Routes.foodsSearchPath),
                  ),
                  SizedBox(width: context.space.x2 + 2),
                  // Quick-add affordance — sits between the search field
                  // and the primary "Log food" button. Same icon + tooltip
                  // as the compact header so the affordance is identical
                  // across form factors.
                  IconButton36(
                    icon: Icons.bolt_outlined,
                    tooltip: 'Quick add calories',
                    onPressed: () => showQuickAddSheet(context),
                    color: context.colors.ink2,
                  ),
                  SizedBox(width: context.space.x2 + 2),
                  _LogFoodButton(
                    onPressed: () => context.push(Routes.foodsSearchPath),
                  ),
                ],
              ),
              SizedBox(height: context.space.x6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        // QL-108 — empty-day pill renders between the
                        // page header and the meal grid when the day
                        // has no entries. Reactive on `entriesAsync`;
                        // disappears the moment the first entry lands.
                        _EmptyDayPill(entriesAsync: entriesAsync),
                        _MealGrid(
                          date: date,
                          summaryAsync: summaryAsync,
                          entriesAsync: entriesAsync,
                          // LU-005: tap-to-edit. The pending-sync guard
                          // inside `editLogEntry` is a no-op on expanded
                          // (no outbox), but routing through the same
                          // helper keeps both day views feature-parity.
                          onEntryTap: (entry) =>
                              editLogEntry(ref, context, entry),
                          // QL-108 — pass the pending-sync predicate
                          // through. Always returns `false` on expanded
                          // (no outbox), but the row code is shared with
                          // compact so the prop ships unconditionally.
                          isPendingSync: (entry) => ref
                              .read(logRepositoryProvider)
                              .isPendingSync(entry.id),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: context.space.x6),
                  SizedBox(
                    width: 360,
                    child: _RightRail(
                      summaryAsync: summaryAsync,
                      effective: effective,
                      recentsAsync: recentsAsync,
                      frequentsAsync: frequentsAsync,
                      weightAsync: weightAsync,
                      weightUnit: weightUnit,
                      burnedKcal: burnedKcal,
                      weeklyLogDays: weeklyLogDays,
                    ),
                  ),
                ],
              ),
            ],
          ),
          ),
        );
      },
    );
  }
}

class _TopSearchField extends StatelessWidget {
  const _TopSearchField({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    // A11y (UX-112, PM UX pack §6): the visual reads as a text input
    // but the affordance routes to `/foods/search` — screen readers
    // need an explicit button role so the announcement isn't
    // "edit text" but "button: Search foods". `MergeSemantics` keeps
    // the icon + label glyphs from composing as two separate nodes.
    return Semantics(
      button: true,
      label: 'Search foods',
      child: MergeSemantics(
        child: Tooltip(
          message: 'Search foods (⌘K)',
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(context.radius.r1),
            child: Container(
              width: 280,
              height: 36,
              padding: EdgeInsets.symmetric(horizontal: context.space.x3),
              decoration: BoxDecoration(
                color: colors.bg,
                border: Border.all(color: colors.line),
                borderRadius: BorderRadius.circular(context.radius.r1),
              ),
              child: Row(
                children: <Widget>[
                  Icon(Icons.search, size: 16, color: colors.ink3),
                  SizedBox(width: context.space.x2),
                  Expanded(
                    child: Text(
                      'Search foods or paste a barcode…',
                      overflow: TextOverflow.ellipsis,
                      style: context.text.meta.copyWith(color: colors.ink3),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LogFoodButton extends StatelessWidget {
  const _LogFoodButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(context.radius.r1),
        child: Container(
          height: 36,
          padding: EdgeInsets.symmetric(horizontal: context.space.x3 + 2),
          decoration: BoxDecoration(
            color: colors.accent,
            borderRadius: BorderRadius.circular(context.radius.r1),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.add, size: 14, color: colors.surface),
              SizedBox(width: context.space.x1 + 2),
              Text(
                'Log food',
                style: context.text.meta.copyWith(
                  color: colors.surface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MealGrid extends StatelessWidget {
  const _MealGrid({
    required this.date,
    required this.summaryAsync,
    required this.entriesAsync,
    required this.onEntryTap,
    required this.isPendingSync,
  });
  final DateTime date;
  final AsyncValue<DaySummary> summaryAsync;
  final AsyncValue<List<LogEntry>> entriesAsync;
  final void Function(LogEntry entry) onEntryTap;

  /// Predicate threaded down to `_EntryRow` for the "Pending sync" badge
  /// + rejected-tap pulse (QL-108). Always `false` on expanded (no
  /// outbox) — the prop ships unconditionally to keep the leaf widget
  /// form-factor-blind.
  final bool Function(LogEntry entry) isPendingSync;

  @override
  Widget build(BuildContext context) {
    final summary = summaryAsync.valueOrNull;
    final entries = entriesAsync.valueOrNull;

    if (summary == null || entries == null) {
      // T-08: render 4 skeletons in the 2×2 grid layout the user will see.
      return _GridShell(
        children: <Widget>[
          for (var i = 0; i < Meal.values.length; i++)
            const TodaySkeleton(
              height: 170,
              semanticsLabel: 'Loading meal',
            ),
        ],
      );
    }

    final byMeal = entriesByMeal(entries);
    return _GridShell(
      children: <Widget>[
        for (final meal in Meal.values)
          MealSection(
            subtotal: summary.byMeal[meal] ?? MealSubtotal.empty(meal),
            entries: byMeal[meal] ?? const <LogEntry>[],
            // Thread the meal hint as `?meal=<wire>`; see the compact
            // sibling for the chain that consumes it.
            onAddTap: () => context.push(
              '${Routes.foodsSearchPath}?meal=${meal.wire}',
            ),
            onEntryTap: onEntryTap,
            isPendingSync: isPendingSync,
            dense: true,
            // UX-106 F1 — per-meal copy-day overflow renders on the
            // expanded card too. The empty-day "Copy from another day"
            // affordance is compact-only (architect §3.4 (B) — the
            // expanded grid always shows all five cards, so the
            // per-meal path is the right scope on expanded).
            onCopyMeal: (m) => showCopyDaySheet(
              context,
              targetDate: date,
              preselectMeals: <Meal>[m],
            ),
          ),
      ],
    );
  }
}

class _GridShell extends StatelessWidget {
  const _GridShell({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final gap = context.space.x4;
    // A plain Wrap with calculated width gives stable heights per row
    // without forcing each cell to the tallest row's height (GridView
    // does the opposite). For four cells the rhythm is two rows of two.
    return LayoutBuilder(
      builder: (context, constraints) {
        final tileWidth = (constraints.maxWidth - gap) / 2;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: <Widget>[
            for (final c in children) SizedBox(width: tileWidth, child: c),
          ],
        );
      },
    );
  }
}

class _RightRail extends StatelessWidget {
  const _RightRail({
    required this.summaryAsync,
    required this.effective,
    required this.recentsAsync,
    required this.frequentsAsync,
    required this.weightAsync,
    required this.weightUnit,
    required this.burnedKcal,
    required this.weeklyLogDays,
  });

  final AsyncValue<DaySummary> summaryAsync;

  /// Live derived kcal + macro targets for today, or null on past
  /// days / when an upstream input is missing. Passed in from the
  /// parent so the rail itself stays a stateless leaf.
  final CalorieEstimate? effective;

  final AsyncValue<List<Food>> recentsAsync;
  final AsyncValue<List<Food>> frequentsAsync;
  final AsyncValue<List<WeightSeriesPoint>> weightAsync;
  final WeightUnit weightUnit;

  /// Resolved Burned-kcal and weekly-log-day count threaded through from
  /// the container so `RingSummaryCard` stays a pure presentation leaf
  /// (testing_guide.md §4.4). `burnedKcal == null` renders the silent
  /// `'—'` fallback; `weeklyLogDays == 0` hides the F10 pill.
  final Decimal? burnedKcal;
  final int weeklyLogDays;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        summaryAsync.when(
          data: (s) => RingSummaryCard(
            summary: overrideDaySummaryWithEffective(s, effective),
            compact: false,
            burnedKcal: burnedKcal,
            weeklyLogDays: weeklyLogDays,
          ),
          loading: () => const RingSummaryCardSkeleton(compact: false),
          error: (e, _) => TodayErrorCard(message: '$e'),
        ),
        SizedBox(height: context.space.x4),
        _QuickAddCard(
          recentsAsync: recentsAsync,
          frequentsAsync: frequentsAsync,
        ),
        SizedBox(height: context.space.x4),
        weightAsync.when(
          data: (pts) => MiniWeightSparkline(points: pts, unit: weightUnit),
          loading: () => const TodaySkeleton(
            height: 140,
            semanticsLabel: 'Loading weight chart',
          ),
          error: (e, _) => TodayErrorCard(message: '$e'),
        ),
      ],
    );
  }
}

class _QuickAddCard extends StatelessWidget {
  const _QuickAddCard({
    required this.recentsAsync,
    required this.frequentsAsync,
  });
  final AsyncValue<List<Food>> recentsAsync;
  final AsyncValue<List<Food>> frequentsAsync;

  @override
  Widget build(BuildContext context) {
    final recents = recentsAsync.valueOrNull ?? const <Food>[];
    final frequents = frequentsAsync.valueOrNull ?? const <Food>[];
    final loading =
        recentsAsync.isLoading || frequentsAsync.isLoading;
    if (loading && recents.isEmpty && frequents.isEmpty) {
      return const TodaySkeleton(
        height: 168,
        semanticsLabel: 'Loading quick add',
      );
    }
    return QuickAddChips(
      recents: recents,
      frequents: frequents,
      onTapFood: (food) => showLogEntrySheet(context, food: food),
    );
  }
}

/// Expanded mirror of compact's empty-day pill (QL-108). Renders above
/// the meal grid when the day has no entries. Hidden while loading and
/// when the day has at least one entry. Uses the lifted `EmptyState`
/// primitive so the affordance shape matches the compact day view
/// byte-for-byte.
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
      padding: EdgeInsets.only(bottom: context.space.x4),
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
