import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../domain/food.dart';
import '../../domain/log_entry.dart';
import '../../domain/meal.dart';
import '../../providers/food_providers.dart';
import '../../providers/repository_providers.dart';
import '../../routing/routes.dart';
import '../../theme/context_extensions.dart';
import '../log_entry/log_entry_sheet.dart';

/// Shared helpers for the compact + expanded day views. Lives inside the
/// feature folder because nothing here is used by another screen.

/// Build the headline string for the date bar — "Today" when the date is
/// the local-now day, otherwise the long-form weekday + month-day.
String todayHeadline(DateTime date) {
  final now = DateTime.now();
  final isToday =
      date.year == now.year && date.month == now.month && date.day == now.day;
  if (isToday) return 'Today';
  return DateFormat.EEEE().format(date);
}

/// Sub-line under the headline — `Thursday, May 14` style. Per T-16 the
/// date is local-calendar, so we format with the user's locale via
/// `intl`.
String todaySubline(DateTime date) =>
    DateFormat('EEEE, MMM d').format(date);

/// Group entries by meal, preserving incoming order within each meal.
/// `logEntriesProvider` already sorts newest-first by `createdAt`, so the
/// caller gets that order inside each meal bucket.
Map<Meal, List<LogEntry>> entriesByMeal(List<LogEntry> entries) {
  final out = <Meal, List<LogEntry>>{
    for (final m in Meal.values) m: <LogEntry>[],
  };
  for (final e in entries) {
    out[e.meal]!.add(e);
  }
  return out;
}

/// The canonical day-view path for [date]. `/today` for the local-now
/// day; `/today/$y-$m-$d` otherwise. Pairs with [navigateDay] and is
/// also consumed by `LogEntrySheet`'s save handlers (T-24 Case 2 —
/// route-to-effect) so the chevrons and the log-save flow agree on the
/// canonical shape. Architect §6.1 / QL-105.
///
/// Local-calendar comparison: a `DateTime` whose Y/M/D matches the
/// machine's local-now Y/M/D resolves to "today" regardless of the
/// hour/minute fields. Callers therefore don't need to normalise to
/// midnight before calling.
String pathForDay(DateTime date) {
  final now = DateTime.now();
  final isToday = date.year == now.year &&
      date.month == now.month &&
      date.day == now.day;
  if (isToday) return Routes.todayPath;
  final y = date.year.toString().padLeft(4, '0');
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return '${Routes.todayPath}/$y-$m-$d';
}

/// Push a relative day route. Today is always the canonical `/today` path
/// — addressing it as `/today/2026-05-15` would work but the route table
/// reserves the bare path for "today right now". Thin wrapper over
/// [pathForDay] so the chevrons and the post-save router agree on the
/// canonical shape.
void navigateDay(BuildContext context, DateTime current, int delta) {
  final target = DateTime(current.year, current.month, current.day + delta);
  context.go(pathForDay(target));
}

/// Tap-to-edit handler for a logged entry row on the day view.
///
/// LU-005 — wires `MealSection.onEntryTap` on both compact and expanded
/// to the `LogEntrySheet` in edit mode. Three gates apply in order:
///
/// 1. **Pending-sync guard (T-22).** On compact, `LogRepository
///    .isPendingSync` consults the outbox and returns `true` for entries
///    whose POST hasn't acked. Editing a not-yet-created entry is
///    meaningless and the row's existing "Retry / Discard" affordance
///    is the right interaction for that state. We surface a SnackBar
///    `"Still syncing — edit when sync finishes"` and bail. On
///    medium/expanded the predicate always returns `false` (no outbox).
/// 2. **Food fetch.** The sheet body needs a full `Food` (servings +
///    nutrition); the day-view only has a denormalized name on the
///    entry. We `await ref.read(foodDetailProvider(entry.foodId)
///    .future)`. On error — most likely `FoodNotFoundError` — surface a
///    SnackBar `"Couldn't load this food — try again"` and bail. The
///    cache is usually warm here (Today views recent foods), so the
///    await typically completes in the same frame.
/// 3. **Open the sheet.** `showLogEntrySheet(context, food: food,
///    existing: entry)` — the sheet pre-seeds quantity/serving/meal
///    /date/note from `existing` and PATCHes on submit. Return value is
///    discarded; the sheet handled invalidation.
///
/// Lives here so `day_view_compact.dart` and `day_view_expanded.dart`
/// don't duplicate the same handler verbatim — architect §2.1 prefers
/// factoring.
Future<void> editLogEntry(
  WidgetRef ref,
  BuildContext context,
  LogEntry entry,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);

  // Gate 1: pending-sync. Always false on medium/expanded (no outbox).
  final repo = ref.read(logRepositoryProvider);
  if (repo.isPendingSync(entry.id)) {
    messenger?.showSnackBar(
      const SnackBar(
        content: Text('Still syncing — edit when sync finishes'),
      ),
    );
    return;
  }

  // Gate 2: food fetch. `foodDetailProvider` is a `FutureProvider.family`;
  // `.future` resolves to the cached value when warm.
  final Food food;
  try {
    food = await ref.read(foodDetailProvider(entry.foodId).future);
  } catch (_) {
    messenger?.showSnackBar(
      const SnackBar(
        content: Text("Couldn't load this food — try again"),
      ),
    );
    return;
  }

  if (!context.mounted) return;

  // Gate 3: open the sheet in edit mode. Discard the return — the sheet
  // itself invalidates `daySummaryProvider` / `logEntriesProvider`.
  await showLogEntrySheet(context, food: food, existing: entry);
}

/// A flat skeleton block sized to a final widget's height. T-08 — render a
/// shape that matches the layout the consumer will see, not a centered
/// spinner.
///
/// Flag for lift: once `lib/widgets/skeleton.dart` lands (architecture §3),
/// this should be replaced by the canonical `Skeleton` widget. Until then
/// the feature folder ships its own minimal version.
class TodaySkeleton extends StatelessWidget {
  const TodaySkeleton({
    required this.height,
    this.width,
    this.semanticsLabel,
    super.key,
  });

  final double height;
  final double? width;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = BorderRadius.circular(context.radius.r3);

    return Semantics(
      label: semanticsLabel,
      liveRegion: false,
      child: Container(
        height: height,
        width: width,
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border.all(color: colors.line),
          borderRadius: radius,
        ),
        clipBehavior: Clip.antiAlias,
        child: const _ShimmerStripe(),
      ),
    );
  }
}

class _ShimmerStripe extends StatelessWidget {
  const _ShimmerStripe();

  @override
  Widget build(BuildContext context) {
    // Static decoration — a true shimmer animation requires an
    // AnimationController which adds state we'd rather not own here.
    // The token-driven block tint is enough to communicate "loading" per
    // T-08 without inviting a spinner.
    final colors = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: <Color>[
            colors.line2,
            colors.bg,
            colors.line2,
          ],
          stops: const <double>[0.0, 0.5, 1.0],
        ),
      ),
    );
  }
}

/// Inline error card used in place of a snackbar inside the
/// stream-of-widgets body. T-11 — surface failures inline, not modal.
class TodayErrorCard extends StatelessWidget {
  const TodayErrorCard({required this.message, super.key});
  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: colors.dangerSoft,
        border: Border.all(color: colors.danger.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(context.radius.r3),
      ),
      padding: EdgeInsets.all(context.space.x4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.error_outline, color: colors.danger, size: 18),
          SizedBox(width: context.space.x2),
          Expanded(
            child: Text(
              "We couldn't load your day. $message",
              style: context.text.meta.copyWith(color: colors.ink),
            ),
          ),
        ],
      ),
    );
  }
}
