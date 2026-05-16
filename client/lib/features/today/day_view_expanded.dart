import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:fulfilled/widgets/meal_section.dart';
import 'package:fulfilled/widgets/ring_summary_card.dart';

import '../../domain/day_summary.dart';
import '../../domain/enums.dart';
import '../../domain/food.dart';
import '../../domain/log_entry.dart';
import '../../domain/meal.dart';
import '../../domain/weight.dart';
import '../../providers/food_providers.dart';
import '../../providers/log_providers.dart';
import '../../providers/profile_providers.dart';
import '../../providers/weight_providers.dart';
import '../../routing/routes.dart';
import '../../theme/context_extensions.dart';
import '../log_entry/log_entry_sheet.dart';
import 'today_internals.dart';
import 'widgets/mini_weight_sparkline.dart';
import 'widgets/quick_add_chips.dart';

/// Expanded (desktop / iPad-landscape) variant of screen 01.
///
/// Layout per `screen_01_day_view_web.html`:
/// - Top bar (rendered by `AppScaffold.topBarTrailing`): page title +
///   date chevrons + search input stub + primary "Log food" button.
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
        return SingleChildScrollView(
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
                  _DateChevrons(date: date),
                  SizedBox(width: context.space.x4),
                  _TopSearchField(
                    onTap: () => context.push(Routes.foodsSearchPath),
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
                    child: _MealGrid(
                      date: date,
                      summaryAsync: summaryAsync,
                      entriesAsync: entriesAsync,
                      // LU-005: tap-to-edit. The pending-sync guard
                      // inside `editLogEntry` is a no-op on expanded
                      // (no outbox), but routing through the same
                      // helper keeps both day views feature-parity.
                      onEntryTap: (entry) =>
                          editLogEntry(ref, context, entry),
                    ),
                  ),
                  SizedBox(width: context.space.x6),
                  SizedBox(
                    width: 360,
                    child: _RightRail(
                      summaryAsync: summaryAsync,
                      recentsAsync: recentsAsync,
                      frequentsAsync: frequentsAsync,
                      weightAsync: weightAsync,
                      weightUnit: weightUnit,
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DateChevrons extends StatelessWidget {
  const _DateChevrons({required this.date});
  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _Chevron(
          icon: Icons.chevron_left,
          tooltip: 'Previous day',
          onTap: () => navigateDay(context, date, -1),
        ),
        SizedBox(width: context.space.x2),
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: context.space.x3,
            vertical: context.space.x1 + 2,
          ),
          decoration: BoxDecoration(
            color: colors.surface,
            border: Border.all(color: colors.line),
            borderRadius: BorderRadius.circular(context.radius.r1),
          ),
          child: Text(
            todayHeadline(date),
            style: context.text.meta.copyWith(
              color: colors.ink,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        SizedBox(width: context.space.x2),
        _Chevron(
          icon: Icons.chevron_right,
          tooltip: 'Next day',
          onTap: () => navigateDay(context, date, 1),
        ),
      ],
    );
  }
}

class _Chevron extends StatelessWidget {
  const _Chevron({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 22,
        child: Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: colors.surface,
            border: Border.all(color: colors.line),
            borderRadius: BorderRadius.circular(context.radius.r1),
          ),
          child: Icon(icon, size: 16, color: colors.ink2),
        ),
      ),
    );
  }
}

class _TopSearchField extends StatelessWidget {
  const _TopSearchField({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Tooltip(
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
  });
  final DateTime date;
  final AsyncValue<DaySummary> summaryAsync;
  final AsyncValue<List<LogEntry>> entriesAsync;
  final void Function(LogEntry entry) onEntryTap;

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
            onAddTap: () => context.push(Routes.foodsSearchPath),
            onEntryTap: onEntryTap,
            dense: true,
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
    required this.recentsAsync,
    required this.frequentsAsync,
    required this.weightAsync,
    required this.weightUnit,
  });

  final AsyncValue<DaySummary> summaryAsync;
  final AsyncValue<List<Food>> recentsAsync;
  final AsyncValue<List<Food>> frequentsAsync;
  final AsyncValue<List<WeightSeriesPoint>> weightAsync;
  final WeightUnit weightUnit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        summaryAsync.when(
          data: (s) => RingSummaryCard(summary: s, compact: false),
          loading: () => const TodaySkeleton(
            height: 296,
            semanticsLabel: 'Loading summary',
          ),
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
