import '../data/api_client.dart';
import '../data/outbox/log_outbox_notifier.dart';
import '../domain/day_summary.dart';
import '../domain/goal.dart';
import '../domain/log_entry.dart';
import '../domain/meal.dart';
import 'food_repository.dart';
import '_fixtures.dart';
import '_mock_latency.dart';
import 'goal_repository.dart';

/// Read + write surface for the food log. Mirrors `/log` and
/// `/days/{date}/summary` from the OpenAPI doc.
///
/// **T-09 anchor.** [daySummary] is the canonical "totals for a date"
/// source — the ring, the ring-summary card, the right-rail summary, and
/// the log-entry preview block all read from the same number. The mock
/// repository computes those totals from the same in-memory entries
/// list [entriesForDate] returns; the live client will use the
/// server's `GET /days/{date}/summary` rollup. Either way, screens go
/// through one provider.
class LogRepository {
  LogRepository({
    required ApiClient api,
    required FoodRepository foodRepository,
    required GoalRepository goalRepository,
    LogOutboxNotifier? outbox,
  })  : _api = api,
        _foodRepo = foodRepository,
        _goalRepo = goalRepository,
        _outbox = outbox;

  // ignore: unused_field — kept for parity with the eventual real client.
  final ApiClient _api;
  final FoodRepository _foodRepo;
  final GoalRepository _goalRepo;

  /// Compact-only handle on the offline outbox. Null on medium/expanded
  /// (the `repository_providers.dart` wiring decides). Read by
  /// [isPendingSync] to project pending/failed outbox rows back to the
  /// day-view. The repository itself never enqueues — the log-entry
  /// sheet owns that — so this is purely a read-side projection.
  final LogOutboxNotifier? _outbox;

  /// In-memory entries. Static so the day view and the create-log call
  /// share the same list across repository instances. Deletable when
  /// the real API lands.
  static List<LogEntry>? _entries;

  static int _seq = 0;

  List<LogEntry> get _state {
    final cached = _entries;
    if (cached != null) return cached;
    // Build seed entries against the food repository's seed catalog.
    // Lazy on first access so tests that swap the food seed before
    // boot don't get a stale snapshot.
    final seed = buildSeedLogEntries(buildSeedFoods());
    _entries = <LogEntry>[...seed];
    return _entries!;
  }

  /// Entries on a given local date (the date the user is viewing — T-16).
  /// Ordering: newest `createdAt` first (within a date the day-view
  /// scrolls top-down chronologically; the meal section groups them and
  /// the FoodRow doesn't expose the timestamp).
  Future<List<LogEntry>> entriesForDate(DateTime date) async {
    await mockLatency();
    final d = DateTime(date.year, date.month, date.day);
    return _state
        .where((e) =>
            e.consumedOn.year == d.year &&
            e.consumedOn.month == d.month &&
            e.consumedOn.day == d.day)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// Rollup for a single calendar date. Computes totals + per-meal
  /// subtotals from [entriesForDate] in the mock; the real client will
  /// hit `/days/{date}/summary` (which is the server doing the same
  /// math). The day's active goal — pulled from [GoalRepository] —
  /// supplies the `*Target` fields so the ring and macro bars don't
  /// need a second read.
  Future<DaySummary> daySummary(DateTime date) async {
    final entries = await entriesForDate(date);
    final activeGoal = await _activeGoalForDateSafely(date);
    return buildDaySummary(
      date: DateTime(date.year, date.month, date.day),
      entriesOnDate: entries,
      activeGoal: activeGoal,
    );
  }

  /// Pull the day's active goal but swallow "no active goal" so the
  /// day-summary call doesn't fail on the never-had-a-goal edge case.
  /// Screens render a "Set a goal" affordance when `kcalTarget == null`.
  Future<Goal?> _activeGoalForDateSafely(DateTime date) async {
    try {
      return await _goalRepo.active(on: date);
    } on GoalNotFoundError {
      return null;
    }
  }

  /// Append a log entry. The mock computes the frozen nutrition snapshot
  /// from the food + serving + quantity exactly the way the server
  /// does (architect spec §9 screen 04). On success the food's
  /// recent/frequent counters tick, so the right-rail Quick add card
  /// reflects the new ranking on the next read.
  ///
  /// `@invalidates`
  /// - `daySummaryProvider(consumedOn)` — the ring + summary card.
  /// - `logEntriesProvider(consumedOn)` — the meal section list.
  /// - `recentFoodsProvider` — the logged food jumps to the head.
  /// - `frequentFoodsProvider` — the food's frequency count ticked.
  ///
  /// Call sites are responsible for invalidating per T-18 (minimal +
  /// explicit); this list is the **contract** the call site reads. A
  /// new dependent provider is added by editing this list and the call
  /// sites in the same PR.
  Future<LogEntry> create(LogCreate data) async {
    await mockLatency();
    final food = _foodRepo.lookup(data.foodId);
    if (food == null) throw FoodNotFoundError(data.foodId);
    final serving = food.servings.firstWhere(
      (s) => s.id == data.servingId,
      orElse: () => throw FoodNotFoundError(data.servingId),
    );
    final now = DateTime.now();
    final id = 'le_new_${_seq++}_${now.microsecondsSinceEpoch}';
    // Quick-add path: when `LogCreate.nutritionOverride` is supplied,
    // substitute it for the food's per-100 g panel before computing the
    // snapshot. The Quick-add sheet uses this to thread user-supplied
    // macros through the normal log math without inventing a new
    // endpoint. Normal log flows leave the override null and the math
    // is byte-for-byte unchanged.
    final foodForSnapshot = data.nutritionOverride == null
        ? food
        : food.copyWith(nutritionPer100g: data.nutritionOverride);
    final entry = computeLogEntry(
      id: id,
      food: foodForSnapshot,
      serving: serving,
      consumedOn:
          DateTime(data.consumedOn.year, data.consumedOn.month, data.consumedOn.day),
      meal: data.meal,
      quantity: data.quantity,
      createdAt: now,
      note: data.note,
    );
    _state.add(entry);
    _foodRepo.noteFoodLogged(food.id);
    return entry;
  }

  /// Patch a log entry. Mirrors `PATCH /log/{id}` from the OpenAPI doc
  /// (`update_log_entry`). The mock recomputes the frozen nutrition
  /// snapshot from the (possibly new) serving + quantity against the
  /// food's `nutritionPer100g`, the same way [create] does — the
  /// server runs identical math, so the day-view sees identical numbers
  /// regardless of mock-vs-live wiring (T-17, T-09).
  ///
  /// `food_id` is immutable in edit mode (PM ruling). The patch class
  /// already refuses to serialise one; if a future caller somehow sneaks
  /// one in via a subclass, the repository asserts loudly.
  ///
  /// Throws [LogEntryNotFoundError] when [entryId] is unknown.
  ///
  /// `@invalidates`
  /// - `daySummaryProvider(newConsumedOn)` — the ring + summary card.
  /// - `logEntriesProvider(newConsumedOn)` — the meal section list.
  /// - `daySummaryProvider(oldConsumedOn)` IF `consumed_on` changed —
  ///   the originating date's totals must drop the moved entry.
  /// - `logEntriesProvider(oldConsumedOn)` IF `consumed_on` changed —
  ///   the originating date's list must drop the moved entry.
  /// - `recentFoodsProvider` — the row's food may shift rank.
  /// - `frequentFoodsProvider` — same.
  ///
  /// Call sites are responsible for invalidating per T-18 (minimal +
  /// explicit); this list is the **contract** the call site reads. A
  /// new dependent provider is added by editing this list and the call
  /// sites in the same PR.
  Future<LogEntry> update(String entryId, LogPatch patch) async {
    // Defence-in-depth against a caller smuggling in a food swap. The
    // PM ruling is unambiguous: edit mode never re-keys an entry to a
    // different food. `LogPatch` enforces this at the wire level by
    // not modelling a `foodId` field, so the JSON guard below catches
    // anyone constructing the map directly.
    if (patch.toJson().containsKey('food_id')) {
      throw StateError(
        'LogPatch must not contain food_id — food is immutable on edit.',
      );
    }
    await mockLatency();
    // TODO(LU-001-wire): replace mock with ApiClient.patch
    // ('/log/$entryId', patch.toJson())
    final idx = _state.indexWhere((e) => e.id == entryId);
    if (idx < 0) throw LogEntryNotFoundError(entryId);
    final current = _state[idx];
    final food = _foodRepo.lookup(current.foodId);
    if (food == null) throw FoodNotFoundError(current.foodId);

    final nextServingId = patch.servingId ?? current.servingId;
    final serving = food.servings.firstWhere(
      (s) => s.id == nextServingId,
      orElse: () => throw FoodNotFoundError(nextServingId ?? '<no-serving>'),
    );

    final nextConsumedOn = patch.consumedOn ?? current.consumedOn;
    final nextMeal = patch.meal ?? current.meal;
    final nextQuantity = patch.quantity ?? current.quantity;

    // Note semantics mirror the wire: an explicit non-null wins, an
    // explicit `clearNote` clears, otherwise carry the prior value.
    final String? nextNote;
    if (patch.note != null) {
      nextNote = patch.note;
    } else if (patch.clearNote) {
      nextNote = null;
    } else {
      nextNote = current.note;
    }

    final now = DateTime.now();
    final recomputed = computeLogEntry(
      id: current.id,
      food: food,
      serving: serving,
      consumedOn: DateTime(
        nextConsumedOn.year,
        nextConsumedOn.month,
        nextConsumedOn.day,
      ),
      meal: nextMeal,
      quantity: nextQuantity,
      createdAt: current.createdAt,
      note: nextNote,
    ).copyWith(updatedAt: now);
    _state[idx] = recomputed;
    return recomputed;
  }

  /// True iff [entryId] has an outbox record in `pending` or `failed`
  /// state. Always false when the repository was constructed without
  /// an outbox (medium/expanded). The day-view's row tap handler uses
  /// this to suppress the edit-sheet for rows that haven't synced yet
  /// (T-22): editing a not-yet-created entry is meaningless, and the
  /// row's existing "Retry now / Discard" affordances are the right
  /// interaction for that state.
  bool isPendingSync(String entryId) {
    final ox = _outbox;
    if (ox == null) return false;
    return ox.state.entries.any((e) =>
        e.entry.optimisticId == entryId &&
        (e.status == OutboxEntryStatus.pending ||
            e.status == OutboxEntryStatus.failed));
  }

  /// Delete a log entry. The OpenAPI returns 204 — we return void.
  ///
  /// `@invalidates`
  /// - `daySummaryProvider(consumedOn)` — the ring + summary card for
  ///   the deleted entry's date.
  /// - `logEntriesProvider(consumedOn)` — the meal section list for
  ///   the deleted entry's date.
  /// - `recentFoodsProvider` — the row's food may shift rank.
  /// - `frequentFoodsProvider` — same.
  ///
  /// Call sites are responsible for invalidating per T-18 (minimal +
  /// explicit); this list is the **contract** the call site reads. A
  /// new dependent provider is added by editing this list and the call
  /// sites in the same PR.
  Future<void> delete(String entryId) async {
    await mockLatency();
    _state.removeWhere((e) => e.id == entryId);
  }

  /// Adopt a pre-built entry (used by the outbox path: optimistic insert
  /// before the server returns). Not part of the OpenAPI surface — it
  /// only exists for the mobile outbox to inject the optimistic row
  /// without re-computing the snapshot.
  ///
  /// `@invalidates`
  /// - `daySummaryProvider(entry.consumedOn)` — the ring + summary
  ///   card for the entry's date.
  /// - `logEntriesProvider(entry.consumedOn)` — the meal section list.
  /// - `recentFoodsProvider` — `noteFoodLogged` runs, so the food
  ///   jumps to the head of recent.
  /// - `frequentFoodsProvider` — same; the frequency count ticks.
  ///
  /// Call sites are responsible for invalidating per T-18 (minimal +
  /// explicit); this list is the **contract** the call site reads. A
  /// new dependent provider is added by editing this list and the call
  /// sites in the same PR.
  void adoptOptimistic(LogEntry entry) {
    _state.add(entry);
    _foodRepo.noteFoodLogged(entry.foodId);
  }

  /// Copy every entry from [sourceDate] to [targetDate], optionally
  /// filtered by [meals]. Mirrors `POST /log/copy` from the OpenAPI doc
  /// (`copy_log_day`, `specs/openapi.yaml` lines 668–698).
  ///
  /// **Server contract.** Snapshots are recomputed from the *current*
  /// food state — the client never sends nutrition snapshots for copied
  /// entries, and a custom food edited between [sourceDate] and
  /// [targetDate] is reflected in the copy verbatim. Entries whose food
  /// is no longer visible or whose serving was deleted are silently
  /// skipped; the returned list contains only the successfully copied
  /// entries. The UI surfaces partial-skip via
  /// `created.length < requested.length`.
  ///
  /// [meals] is `null` → copy every meal (whole-day copy). A non-null
  /// list filters source entries to those whose `meal` is contained.
  /// The wire accepts a single `meal` field (the union of the list);
  /// the mock implementation iterates per-meal and concatenates.
  ///
  /// The repository **does not** route through `_outbox` for `copyDay`.
  /// Per PM doc §2 F1 AC: copy is online-only; the outbox is scoped to
  /// single-entry POSTs.
  ///
  /// `@invalidates`
  /// - `daySummaryProvider(targetDate)` — the ring + summary card for
  ///   the destination day.
  /// - `logEntriesProvider(targetDate)` — the meal section list for
  ///   the destination day.
  /// - `recentFoodsProvider` — the copied foods bump rank.
  /// - `frequentFoodsProvider` — the copied foods' frequency ticks.
  /// - `weeklyLogDaysProvider` — the target day may flip from
  ///   zero-entries to one+, affecting the 0–7 week count. (Added when
  ///   UX-110 lands; the provider does not yet exist. UX-105 ships the
  ///   four other invalidations and this forward-referenced line.)
  ///
  /// Notably **not** invalidated: `daySummaryProvider(sourceDate)` /
  /// `logEntriesProvider(sourceDate)` — the source day is read-only.
  /// The wire never mutates `from_date`.
  ///
  /// Call sites are responsible for invalidating per T-18 (minimal +
  /// explicit); this list is the **contract** the call site reads. A
  /// new dependent provider is added by editing this list and the call
  /// sites in the same PR.
  Future<List<LogEntry>> copyDay({
    required DateTime sourceDate,
    required DateTime targetDate,
    List<Meal>? meals,
  }) async {
    await mockLatency();
    // Normalise to Y/M/D so caller-supplied DateTimes with non-zero
    // hour/minute fields still match the day-keyed `consumedOn`.
    final src =
        DateTime(sourceDate.year, sourceDate.month, sourceDate.day);
    final tgt =
        DateTime(targetDate.year, targetDate.month, targetDate.day);
    // 1. Filter `_state` by consumedOn == sourceDate (Y/M/D) AND
    //    meals == null || meals.contains(entry.meal).
    final filtered = _state.where((e) {
      final on = e.consumedOn;
      final sameDay = on.year == src.year &&
          on.month == src.month &&
          on.day == src.day;
      if (!sameDay) return false;
      if (meals != null && !meals.contains(e.meal)) return false;
      return true;
    }).toList();

    final now = DateTime.now();
    final created = <LogEntry>[];
    for (final source in filtered) {
      // 2. Look up the food. Missing → silently skip (wire contract).
      final food = _foodRepo.lookup(source.foodId);
      if (food == null) continue;
      // 3. Look up the serving. Missing → silently skip.
      final servingId = source.servingId;
      if (servingId == null) continue;
      final servingMatch = food.servings.where((s) => s.id == servingId);
      if (servingMatch.isEmpty) continue;
      final serving = servingMatch.first;
      // 4. Recompute the snapshot against the *current* food state
      //    (not the source entry's frozen snapshot). Same math path as
      //    `create` — `computeLogEntry` mirrors the server.
      final id = 'le_new_${_seq++}_${now.microsecondsSinceEpoch}';
      final entry = computeLogEntry(
        id: id,
        food: food,
        serving: serving,
        consumedOn: tgt,
        meal: source.meal,
        quantity: source.quantity,
        createdAt: now,
        note: source.note,
      );
      // 5. Append + bump recents/frequents.
      _state.add(entry);
      _foodRepo.noteFoodLogged(food.id);
      created.add(entry);
    }
    // 6. Return the survivors. Partial-skip is implicit in
    //    `created.length < filtered.length`; the UI computes the
    //    requested count from the source meal-filter and compares.
    return created;
  }

  // Test seam — let tests reset the in-memory list to a clean seed
  // without rebuilding the whole repository.
  static void resetForTesting() {
    _entries = <LogEntry>[...buildSeedLogEntries(buildSeedFoods())];
    _seq = 0;
  }
}
