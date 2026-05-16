import 'package:decimal/decimal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/day_summary.dart';
import '../domain/log_entry.dart';
import '../domain/meal.dart';
import 'repository_providers.dart';

/// Log-domain providers. The day-view (screen 01), the log-entry sheet
/// (screen 04), and the right-rail summary card all bind here.
///
/// **T-09 anchor — one summary per date.** Every "today total" surface in
/// the UI reads from [daySummaryProvider]. Screen agents must NOT compute
/// totals out of band by summing [logEntriesProvider]; the day summary
/// already does that math and supplies the macro targets too.
///
/// **Invalidation after mutation.** After `POST /log` (or a delete), the
/// log-entry sheet does:
///
/// ```dart
/// ref.invalidate(daySummaryProvider(date));
/// ref.invalidate(logEntriesProvider(date));
/// ref.invalidate(recentFoodsProvider);
/// ref.invalidate(frequentFoodsProvider);
/// ```
///
/// The mock repository mutates shared in-memory state, so the next read
/// reflects the change. With the live API the `invalidate` triggers a
/// re-fetch — same call sites, same behaviour.

/// Per-day rollup (totals, per-meal subtotals, daily targets lifted from
/// the active goal). Drives the ring, the macro bars, the meal section
/// counts, and the right-rail summary.
final daySummaryProvider =
    FutureProvider.family<DaySummary, DateTime>((ref, date) {
  final repo = ref.watch(logRepositoryProvider);
  return repo.daySummary(date);
});

/// Entries for the day. Sorted newest-first by `createdAt`. Drives the
/// meal-section list on screen 01 and the "logged-today preview" on
/// screen 04.
final logEntriesProvider =
    FutureProvider.family<List<LogEntry>, DateTime>((ref, date) {
  final repo = ref.watch(logRepositoryProvider);
  return repo.entriesForDate(date);
});

/// Cheap preview value for `CopyDaySheet` — entry count + total kcal
/// for a given `(sourceDate, meals)` combination. Reads the same
/// in-memory entries the day view does, so the preview updates in
/// lock-step with any source-date scrub or meal-scope chip toggle.
class CopyDayPreview {
  const CopyDayPreview({required this.count, required this.totalKcal});

  /// Number of source entries that match the meal filter. Equals the
  /// `requestedCount` the sheet snapshots at submit time and compares
  /// against `created.length` for partial-skip detection.
  final int count;

  /// Sum of `entry.kcal` (frozen snapshot) across the matched source
  /// entries. The preview line renders this via `formatKcal`. Note: the
  /// post-copy total on the *target* day may differ when a custom
  /// food's `nutritionPer100g` has been edited between source and
  /// target — the wire contract is "recompute against current food
  /// state" and `LogRepository.copyDay` mirrors that. The preview is
  /// a UX hint, not a guarantee, and the partial-skip path makes the
  /// drift visible.
  final Decimal totalKcal;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CopyDayPreview &&
          other.count == count &&
          other.totalKcal == totalKcal;

  @override
  int get hashCode => Object.hash(count, totalKcal);
}

/// Family key for [copyDayPreviewProvider]. `meals == null` means
/// "every meal" (whole-day copy); a non-null list keys by content
/// equality so the family's per-key memoisation is stable across
/// rebuilds when the chip set is unchanged.
class CopyDayPreviewKey {
  const CopyDayPreviewKey({required this.sourceDate, this.meals});

  final DateTime sourceDate;
  final List<Meal>? meals;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! CopyDayPreviewKey) return false;
    if (sourceDate != other.sourceDate) return false;
    final a = meals;
    final b = other.meals;
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    final m = meals;
    return Object.hash(
      sourceDate,
      m == null ? null : Object.hashAll(m),
    );
  }
}

/// Days with at least one log entry in the current local week
/// (Mon–Sun). F10 from `architect_ux_pack.md` §7 — backs the
/// `_WeekProgressPill` inside `RingSummaryCard`.
///
/// Returns `0..7`. The pill is hidden at 0; renders
/// `"This week · N/7 days logged"` for 1..6 in `ink2`; renders in
/// `accent` at 7.
///
/// **Invalidation.** Every `LogRepository` mutator (`create`, `update`,
/// `delete`, `copyDay`, `adoptOptimistic`) lists this provider in its
/// `@invalidates` block — log entries appearing or disappearing can
/// shift the week-day count. Call sites invalidate per T-18.
///
/// **Local-now dependency.** `weeklyLogDayCount` reads
/// `DateTime.now()` at request time, so a long-lived provider would
/// stale across midnight. In practice the foreground-resume path that
/// invalidates `daySummaryProvider` will be extended (v1.1) to
/// invalidate this provider too. For v1 the pill re-ticks on every
/// mutation, which dominates user-perceived freshness.
final weeklyLogDaysProvider = FutureProvider<int>((ref) {
  final repo = ref.watch(logRepositoryProvider);
  return repo.weeklyLogDayCount();
});

/// Drives the live "N entries · M kcal" line in `CopyDaySheet`. The
/// family is re-keyed on every source-date scrub or chip toggle; the
/// preview re-runs and the sheet rebuilds. Reading existing in-memory
/// entries is cheap (≤ ~100 rows for any user's recent days).
final copyDayPreviewProvider =
    FutureProvider.family<CopyDayPreview, CopyDayPreviewKey>(
  (ref, key) async {
    final repo = ref.watch(logRepositoryProvider);
    final entries = await repo.entriesForDate(key.sourceDate);
    final filtered = key.meals == null
        ? entries
        : entries.where((e) => key.meals!.contains(e.meal));
    var total = Decimal.zero;
    var count = 0;
    for (final e in filtered) {
      total = total + e.kcal;
      count += 1;
    }
    return CopyDayPreview(count: count, totalKcal: total);
  },
);
