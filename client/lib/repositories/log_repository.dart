import 'package:dio/dio.dart';

import '../data/api_client.dart';
import '../data/outbox/log_outbox_notifier.dart';
import '../domain/day_summary.dart';
import '../domain/log_entry.dart';
import '../domain/meal.dart';
import '_fixtures.dart' show quickAddFoodId;
import 'food_repository.dart';
import 'goal_repository.dart';

/// Read + write surface for the food log. Mirrors `/log` and
/// `/days/{date}/summary` from the OpenAPI doc.
///
/// **T-09 anchor.** [daySummary] is the canonical "totals for a date"
/// source — the ring, the ring-summary card, the right-rail summary, and
/// the log-entry preview block all read from the same number. The
/// server's `GET /days/{date}/summary` rollup is the wire shape; the
/// returned `DaySummary` is parsed verbatim and screens go through one
/// provider.
///
/// **Outbox wire model.** The repository owns the wire calls. The mobile
/// outbox (T-22) is wired upstream (the log-entry sheet on compact
/// `enqueue`s the `LogCreate` JSON, and the outbox's `LogPostFn`
/// re-enters [create] when it drains). On success the outbox deletes its
/// queued entry; on failure (the HTTP call below throws) the outbox
/// keeps the entry for retry. Edits, deletes and copy-day never queue
/// (architect §2.5 / PM ruling) — those paths call the wire directly.
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

  final ApiClient _api;
  final FoodRepository _foodRepo;
  // ignore: unused_field — kept for parity with the eventual real client.
  // `GET /days/{date}/summary` already embeds the active goal so we don't
  // need to fetch it here; the field is retained for compatibility with
  // existing test harness constructors and any future per-date overrides.
  final GoalRepository _goalRepo;

  /// Compact-only handle on the offline outbox. Null on medium/expanded
  /// (the `repository_providers.dart` wiring decides). Read by
  /// [isPendingSync] to project pending/failed outbox rows back to the
  /// day-view. The repository itself never enqueues — the log-entry
  /// sheet owns that — so this is purely a read-side projection.
  final LogOutboxNotifier? _outbox;

  /// Entries on a given local date (the date the user is viewing — T-16).
  /// Ordering: newest `createdAt` first (within a date the day-view
  /// scrolls top-down chronologically; the meal section groups them and
  /// the FoodRow doesn't expose the timestamp).
  ///
  /// Wire shape: `GET /log?from=YYYY-MM-DD&to=YYYY-MM-DD`. The response
  /// is the `PaginatedLogEntries` envelope (`{results, total, limit,
  /// offset}`); we read `results` and ignore pagination for a single-day
  /// fetch (server returns up to 100 entries by default — well above any
  /// realistic single-day count).
  Future<List<LogEntry>> entriesForDate(DateTime date) async {
    final iso = _isoDate(date);
    final res = await _api.dio.get<Map<String, dynamic>>(
      '/log',
      queryParameters: <String, dynamic>{
        'from': iso,
        'to': iso,
      },
    );
    final body = res.data ?? const <String, dynamic>{};
    final results = (body['results'] as List<dynamic>? ?? const <dynamic>[])
        .cast<Map<String, dynamic>>();
    // The live wire shape does NOT carry `food_name` / `serving_name`
    // (Ask 9 in backend_tasks.md). Until that lands, fall back to
    // prefetching each unique food_id once per day-view render so
    // [_decodeEntryWithDenorm] can fill the names from
    // `FoodRepository.lookup` (which now reads a real instance cache).
    // The prefetch is idempotent + cached across calls — the second
    // render of the same day is a single `/log` round trip.
    final foodIds = <String>{
      for (final r in results)
        if (r['food_id'] is String) r['food_id'] as String,
    };
    if (foodIds.isNotEmpty) {
      await _foodRepo.prefetchByIds(foodIds);
    }
    final entries =
        results.map(_decodeEntryWithDenorm).toList(growable: false);
    entries.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return entries;
  }

  /// Rollup for a single calendar date. The wire endpoint already does
  /// the per-meal subtotal math + lifts the active goal's targets onto
  /// the response, so this is a single HTTP read (T-09).
  ///
  /// Wire shape: `GET /days/{YYYY-MM-DD}/summary` — note the path is a
  /// bare date, **not** an ISO-8601 datetime. The response includes a
  /// `total` block, a `by_meal` array (one subtotal per meal in canonical
  /// order, even for empty meals), and an `active_goal` block (or `null`
  /// when the day has no goal). `DaySummary.fromJson` parses all of it.
  Future<DaySummary> daySummary(DateTime date) async {
    final iso = _isoDate(date);
    final res = await _api.dio.get<Map<String, dynamic>>(
      '/days/$iso/summary',
    );
    final body = res.data ?? const <String, dynamic>{};
    return DaySummary.fromJson(body);
  }

  /// Append a log entry. Routes to `POST /log` for canonical entries and
  /// to `POST /log/quick_add` for the kcal-only quick-add path
  /// (architect §9 screen 04). The server computes the frozen nutrition
  /// snapshot from the food + serving + quantity; the client decodes the
  /// returned entry, denormalises `food_name` / `serving_name` from the
  /// local food cache, and bumps recents/frequents for the
  /// non-quick-add path so the right-rail Quick add card reflects the
  /// new ranking on the next read.
  ///
  /// **Outbox.** On compact the log-entry sheet enqueues the `LogCreate`
  /// JSON; the outbox's drain re-enters this method via its `LogPostFn`.
  /// Any thrown `DioException` propagates back to the outbox, which
  /// increments the attempt counter and either schedules a retry or
  /// flips the entry to a terminal "failed" state. On medium/expanded
  /// the call-site invokes this directly (no outbox), surfacing failures
  /// inline (architecture §5).
  ///
  /// `@invalidates`
  /// - `daySummaryProvider(consumedOn)` — the ring + summary card.
  /// - `logEntriesProvider(consumedOn)` — the meal section list.
  /// - `recentFoodsProvider` — the logged food jumps to the head.
  /// - `frequentFoodsProvider` — the food's frequency count ticked.
  /// - `weeklyLogDaysProvider` — the entry's date may flip from
  ///   zero-entries to one+, bumping the 0–7 week count (UX-110 / F10).
  ///
  /// Call sites are responsible for invalidating per T-18 (minimal +
  /// explicit); this list is the **contract** the call site reads. A
  /// new dependent provider is added by editing this list and the call
  /// sites in the same PR.
  Future<LogEntry> create(LogCreate data) async {
    final isQuickAdd = data.foodId == quickAddFoodId;

    final Map<String, dynamic> body;
    final String path;
    if (isQuickAdd) {
      // `LogCreate.quantity` is the kcal value for the quick-add sheet
      // (the synthetic `food_quick_add` food maps quantity 1:1 to kcal).
      // The wire schema is `{calories_kcal, meal, consumed_on, note?}`.
      path = '/log/quick_add';
      body = <String, dynamic>{
        'calories_kcal': data.quantity.toString(),
        'meal': data.meal.wire,
        'consumed_on': _isoDate(data.consumedOn),
        if (data.note != null) 'note': data.note,
      };
    } else {
      path = '/log';
      body = data.toJson();
    }

    final res = await _api.dio.post<Map<String, dynamic>>(
      path,
      data: body,
    );
    final decoded = _decodeEntryWithDenorm(
      res.data ?? const <String, dynamic>{},
    );

    // Skip recents/frequents bumps for quick-add: the server's quick-add
    // sentinel food is hidden from My foods anyway (per openapi
    // description); bumping its rank would leak it back into the
    // recent/frequent projections. The non-quick-add path bumps using
    // the locally-known foodId so the cached FoodRepository projections
    // update in lock-step with what we just wrote.
    if (!isQuickAdd) {
      _foodRepo.noteFoodLogged(data.foodId);
    }
    return decoded;
  }

  /// Patch a log entry. Wire shape: `PATCH /log/{id}` with a sparse JSON
  /// body that only includes the changed fields (T-17). The server
  /// recomputes the frozen nutrition snapshot from the (possibly new)
  /// serving + quantity against the food's `nutritionPer100g`; we decode
  /// its response verbatim and denormalise food/serving names from the
  /// local catalog so the day-view's `FoodRow` can render without a
  /// second fetch.
  ///
  /// `food_id` is immutable in edit mode (PM ruling). [LogPatch] already
  /// refuses to model one; the JSON guard below catches anyone
  /// constructing the map directly through a subclass.
  ///
  /// Throws [LogEntryNotFoundError] when the server returns 404.
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
  /// - `weeklyLogDaysProvider` — an update that changes `consumed_on`
  ///   could shift the week-day count (UX-110 / F10).
  ///
  /// Call sites are responsible for invalidating per T-18 (minimal +
  /// explicit); this list is the **contract** the call site reads.
  Future<LogEntry> update(String entryId, LogPatch patch) async {
    // Defence-in-depth against a caller smuggling in a food swap. The
    // PM ruling is unambiguous: edit mode never re-keys an entry to a
    // different food. `LogPatch` enforces this at the wire level by
    // not modelling a `foodId` field, so the JSON guard below catches
    // anyone constructing the map directly.
    final body = patch.toJson();
    if (body.containsKey('food_id')) {
      throw StateError(
        'LogPatch must not contain food_id — food is immutable on edit.',
      );
    }
    try {
      final res = await _api.dio.patch<Map<String, dynamic>>(
        '/log/$entryId',
        data: body,
      );
      return _decodeEntryWithDenorm(res.data ?? const <String, dynamic>{});
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        throw LogEntryNotFoundError(entryId);
      }
      rethrow;
    }
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

  /// Delete a log entry. Wire shape: `DELETE /log/{id}` returns 204.
  ///
  /// Throws [LogEntryNotFoundError] when the server returns 404.
  ///
  /// `@invalidates`
  /// - `daySummaryProvider(consumedOn)` — the ring + summary card for
  ///   the deleted entry's date.
  /// - `logEntriesProvider(consumedOn)` — the meal section list for
  ///   the deleted entry's date.
  /// - `recentFoodsProvider` — the row's food may shift rank.
  /// - `frequentFoodsProvider` — same.
  /// - `weeklyLogDaysProvider` — deleting the only entry on a date drops
  ///   that day from the week-count (UX-110 / F10).
  Future<void> delete(String entryId) async {
    try {
      await _api.dio.delete<void>('/log/$entryId');
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        throw LogEntryNotFoundError(entryId);
      }
      rethrow;
    }
  }

  /// Adopt a pre-built entry. Pre-wire this back-channeled into the
  /// in-memory mock so optimistic rows showed up on the next
  /// `entriesForDate` read; on the live wire the optimistic display is
  /// owned by the outbox layer (T-22 — the day-view merges
  /// pending/failed outbox rows with the server response). Kept on the
  /// class as a no-op-except-for-the-recents-bump so call-sites that
  /// invoked it pre-wire don't change shape.
  ///
  /// `@invalidates`
  /// - `recentFoodsProvider` — `noteFoodLogged` runs, so the food
  ///   jumps to the head of recent.
  /// - `frequentFoodsProvider` — same; the frequency count ticks.
  void adoptOptimistic(LogEntry entry) {
    _foodRepo.noteFoodLogged(entry.foodId);
  }

  /// Copy every entry from [sourceDate] to [targetDate], optionally
  /// filtered by [meals]. Wire shape: `POST /log/copy` with body
  /// `{from_date, to_date, meal?}` (`copy_log_day`, `specs/openapi.yaml`
  /// lines 668–698). The response is wrapped as `{copied: [...]}`.
  ///
  /// **Server contract.** Snapshots are recomputed from the *current*
  /// food state — the client never sends nutrition snapshots for copied
  /// entries, and a custom food edited between [sourceDate] and
  /// [targetDate] is reflected in the copy verbatim. Entries whose food
  /// is no longer visible or whose serving was deleted are silently
  /// skipped by the server; the `copied` list contains only the
  /// successfully copied entries. The UI surfaces partial-skip via
  /// `created.length < requested.length`.
  ///
  /// [meals] is `null` → copy every meal (whole-day copy). A non-null
  /// list filters the source entries: the wire accepts a single `meal`
  /// field, so we issue one `POST /log/copy` per meal in the list and
  /// concatenate the results (matching the pre-wire mock's semantics).
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
  ///   zero-entries to one+, affecting the 0–7 week count (UX-110 /
  ///   F10).
  Future<List<LogEntry>> copyDay({
    required DateTime sourceDate,
    required DateTime targetDate,
    List<Meal>? meals,
  }) async {
    final fromIso = _isoDate(sourceDate);
    final toIso = _isoDate(targetDate);

    // Single-call shape covers the common case (whole-day copy, or
    // single-meal filter). A multi-meal list fans out into N calls so
    // the per-meal subtotal lands on the target day in input order.
    final mealList = meals;
    final List<Map<String, dynamic>> bodies;
    if (mealList == null) {
      bodies = <Map<String, dynamic>>[
        <String, dynamic>{
          'from_date': fromIso,
          'to_date': toIso,
        },
      ];
    } else if (mealList.length == 1) {
      bodies = <Map<String, dynamic>>[
        <String, dynamic>{
          'from_date': fromIso,
          'to_date': toIso,
          'meal': mealList.single.wire,
        },
      ];
    } else {
      bodies = <Map<String, dynamic>>[
        for (final m in mealList)
          <String, dynamic>{
            'from_date': fromIso,
            'to_date': toIso,
            'meal': m.wire,
          },
      ];
    }

    final created = <LogEntry>[];
    for (final body in bodies) {
      final res = await _api.dio.post<Map<String, dynamic>>(
        '/log/copy',
        data: body,
      );
      final copied = ((res.data ?? const <String, dynamic>{})['copied']
              as List<dynamic>? ??
          const <dynamic>[])
          .cast<Map<String, dynamic>>();
      for (final raw in copied) {
        final entry = _decodeEntryWithDenorm(raw);
        created.add(entry);
        _foodRepo.noteFoodLogged(entry.foodId);
      }
    }
    return created;
  }

  /// Count distinct dates in the current local week (Mon–Sun) that
  /// have at least one log entry. Returns 0..7. Backs
  /// `weeklyLogDaysProvider` (UX-110 / F10 — architect §7.2).
  ///
  /// Implementation: hits `GET /log?from=<Mon>&to=<Sun>&limit=500` and
  /// counts distinct `consumed_on` values in the response. The clamp at
  /// 500 covers any realistic week (`/log`'s server-side max). A
  /// dedicated `GET /me/weekly-logging` endpoint is the future home
  /// (BE-002 in the architect doc); when it ships, this method swaps the
  /// fetch and the provider's behaviour is unchanged.
  ///
  /// The week is Monday–Sunday in the caller's local time zone (PM
  /// ruling, architect §12.2 resolution). [now] defaults to
  /// `DateTime.now()`; tests inject a fixed clock so the week boundary
  /// is deterministic.
  Future<int> weeklyLogDayCount({DateTime? now}) async {
    final clockNow = now ?? DateTime.now();
    final weekStart = _mondayOfWeek(clockNow);
    final weekEndInclusive = weekStart.add(const Duration(days: 6));

    final res = await _api.dio.get<Map<String, dynamic>>(
      '/log',
      queryParameters: <String, dynamic>{
        'from': _isoDate(weekStart),
        'to': _isoDate(weekEndInclusive),
        'limit': 500,
      },
    );
    final results = ((res.data ?? const <String, dynamic>{})['results']
            as List<dynamic>? ??
        const <dynamic>[])
        .cast<Map<String, dynamic>>();
    final days = <String>{};
    for (final raw in results) {
      final day = raw['consumed_on'] as String?;
      if (day != null) days.add(day);
    }
    return days.length;
  }

  /// Decode a wire `LogEntry` and denormalise `foodName` / `servingName`
  /// from the local food catalog. The OpenAPI shape does not include
  /// these (the wire keeps the snapshot flat), but the day-view's
  /// `FoodRow` reads them directly; resolving from the cache here means
  /// rows render without a second fetch per entry.
  LogEntry _decodeEntryWithDenorm(Map<String, dynamic> json) {
    final base = LogEntry.fromJson(json);
    if (base.foodName.isNotEmpty &&
        (base.servingName != null && base.servingName!.isNotEmpty)) {
      return base;
    }
    final cached = _foodRepo.lookup(base.foodId);
    if (cached == null) return base;
    final cachedServing = base.servingId == null
        ? null
        : cached.servings.firstWhere(
            (s) => s.id == base.servingId,
            orElse: () => cached.servings.first,
          );
    return base.copyWith(
      foodName: base.foodName.isEmpty ? cached.name : base.foodName,
      servingName: (base.servingName == null || base.servingName!.isEmpty)
          ? cachedServing?.name
          : base.servingName,
    );
  }

  /// Local midnight on the Monday of the week containing [now]. Dart's
  /// `DateTime` rolls negative `day` arguments back into the prior
  /// month/year correctly (e.g. `DateTime(2026, 1, 1 - 3)` →
  /// `DateTime(2025, 12, 29)`), so this works across month and year
  /// boundaries without special-casing.
  DateTime _mondayOfWeek(DateTime now) {
    // DateTime.weekday: Monday = 1, Sunday = 7.
    final daysSinceMonday = now.weekday - 1;
    return DateTime(now.year, now.month, now.day - daysSinceMonday);
  }

  /// Reset hook kept for source-compatibility with the harness. Pre-wire
  /// this cleared the in-memory `_state` list; the wired repository has
  /// no static state to reset, but tests that ran in mock mode still call
  /// it from `setUp`. Now a no-op.
  static void resetForTesting() {}
}

/// `YYYY-MM-DD` formatter that doesn't pull in `intl` for one call.
/// Matches the OpenAPI `date` format used on `/log` query parameters,
/// `/days/{date}/summary` paths, and `LogCreate`/`LogPatch` bodies.
String _isoDate(DateTime d) {
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}

