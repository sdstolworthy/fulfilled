import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/day_summary.dart';
import '../domain/log_entry.dart';
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
