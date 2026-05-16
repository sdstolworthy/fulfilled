import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../domain/log_entry.dart';
import '../../domain/meal.dart';
import '../../routing/routes.dart';
import '../../theme/context_extensions.dart';

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

/// Push a relative day route. Today is always the canonical `/today` path
/// — addressing it as `/today/2026-05-15` would work but the route table
/// reserves the bare path for "today right now".
void navigateDay(BuildContext context, DateTime current, int delta) {
  final target = DateTime(current.year, current.month, current.day + delta);
  final now = DateTime.now();
  final isToday = target.year == now.year &&
      target.month == now.month &&
      target.day == now.day;
  if (isToday) {
    context.go(Routes.todayPath);
    return;
  }
  final y = target.year.toString().padLeft(4, '0');
  final m = target.month.toString().padLeft(2, '0');
  final d = target.day.toString().padLeft(2, '0');
  context.go('${Routes.todayPath}/$y-$m-$d');
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
