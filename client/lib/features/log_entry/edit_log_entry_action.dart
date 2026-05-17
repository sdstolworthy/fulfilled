import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/food.dart';
import '../../domain/log_entry.dart';
import '../../domain/quick_add.dart';
import '../../providers/food_providers.dart';
import '../../providers/repository_providers.dart';
import '../quick_add/quick_add_sheet.dart';
import 'log_entry_sheet.dart';

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
/// 2. **Quick-add branch (FX-001).** Quick-add rows back the synthetic
///    `food_quick_add` food — there's no real food behind them, so the
///    food-detail-style `LogEntrySheet` is the wrong surface. We
///    short-circuit to `showQuickAddSheet(context, existing: entry)`
///    which renders the dedicated Edit quick-add UI. The food-fetch
///    gate is skipped (the synthetic food *is* in the seed catalog so
///    a fetch would resolve, but its panel is a placeholder — we just
///    don't need it). The pending-sync gate above already ran.
/// 3. **Food fetch.** The sheet body needs a full `Food` (servings +
///    nutrition); the day-view only has a denormalized name on the
///    entry. We `await ref.read(foodDetailProvider(entry.foodId)
///    .future)`. On error — most likely `FoodNotFoundError` — surface a
///    SnackBar `"Couldn't load this food — try again"` and bail. The
///    cache is usually warm here (Today views recent foods), so the
///    await typically completes in the same frame.
/// 4. **Open the sheet.** `showLogEntrySheet(context, food: food,
///    existing: entry)` — the sheet pre-seeds quantity/serving/meal
///    /date/note from `existing` and PATCHes on submit. Return value is
///    discarded; the sheet handled invalidation.
///
/// Audit finding #13: this used to live in `features/today/
/// today_internals.dart` (a kitchen drawer of widgets, format helpers
/// and skeletons). The orchestration belongs alongside `showLogEntrySheet`
/// / `showQuickAddSheet` — both day views import it from here.
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

  // Gate 2 (FX-001): Quick-add rows go to the dedicated quick-add edit
  // sheet, not the generic LogEntrySheet. Branches on the synthetic
  // food id rather than a row-side flag because that's the same key
  // `LogRepository.create` uses to mint the entry — keeping the two in
  // lock-step is one source of truth.
  if (entry.foodId == quickAddFoodId) {
    await showQuickAddSheet(context, existing: entry);
    return;
  }

  // Gate 3: food fetch. `foodDetailProvider` is a `FutureProvider.family`;
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

  // Gate 4: open the sheet in edit mode. Discard the return — the sheet
  // itself invalidates `daySummaryProvider` / `logEntriesProvider`.
  await showLogEntrySheet(context, food: food, existing: entry);
}
