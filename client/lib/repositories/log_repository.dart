import '../data/api_client.dart';
import '../domain/day_summary.dart';
import '../domain/goal.dart';
import '../domain/log_entry.dart';
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
  })  : _api = api,
        _foodRepo = foodRepository,
        _goalRepo = goalRepository;

  // ignore: unused_field — kept for parity with the eventual real client.
  final ApiClient _api;
  final FoodRepository _foodRepo;
  final GoalRepository _goalRepo;

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
    final entry = computeLogEntry(
      id: id,
      food: food,
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

  /// Delete a log entry. The OpenAPI returns 204 — we return void.
  Future<void> delete(String entryId) async {
    await mockLatency();
    _state.removeWhere((e) => e.id == entryId);
  }

  /// Adopt a pre-built entry (used by the outbox path: optimistic insert
  /// before the server returns). Not part of the OpenAPI surface — it
  /// only exists for the mobile outbox to inject the optimistic row
  /// without re-computing the snapshot.
  void adoptOptimistic(LogEntry entry) {
    _state.add(entry);
    _foodRepo.noteFoodLogged(entry.foodId);
  }

  // Test seam — let tests reset the in-memory list to a clean seed
  // without rebuilding the whole repository.
  static void resetForTesting() {
    _entries = <LogEntry>[...buildSeedLogEntries(buildSeedFoods())];
    _seq = 0;
  }
}
