import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';

import '../data/api_client.dart';
import '../data/outbox/log_outbox_notifier.dart';
import '../domain/day_summary.dart';
import '../domain/log_entry.dart';
import '../domain/meal.dart';
import '../domain/quick_add.dart';
import '../domain/serving.dart';
import '_fixtures.dart' as fx;
import 'food_repository.dart';
import 'goal_repository.dart';

/// Read + write surface for the food log. Mirrors `/log` and
/// `/days/{date}/summary` from the OpenAPI doc.
///
/// **Fixture mode (Ask 10).** When [kUseFixtures] is true (the
/// `food_repository.dart` const that gates the whole reshape), this
/// repository serves an in-memory list of log entries seeded from
/// [fx.buildSeedLogEntries]. Writes mutate the list; reads project
/// from it. The live-API code paths are preserved verbatim modulo
/// type updates so we can flip the const back to false once the BE
/// emits the new wire shape.
class LogRepository {
  LogRepository({
    required ApiClient api,
    required FoodRepository foodRepository,
    required GoalRepository goalRepository,
    LogOutboxNotifier? outbox,
    bool useFixtures = kUseFixtures,
  })  : _api = api,
        _foodRepo = foodRepository,
        _goalRepo = goalRepository,
        _outbox = outbox,
        _useFixtures = useFixtures {
    if (_useFixtures) _seedFixtureStore();
  }

  /// Per-instance fixture-mode flag. Tests pass `useFixtures: false`
  /// to exercise the live-API decoders against a mocked Dio adapter.
  final bool _useFixtures;

  final ApiClient _api;
  final FoodRepository _foodRepo;
  // ignore: unused_field — kept for parity with the eventual real client.
  final GoalRepository _goalRepo;

  final LogOutboxNotifier? _outbox;

  /// In-memory store under [kUseFixtures]. Mirrors what the server's
  /// `food_log_entries` table would return.
  final List<LogEntry> _store = <LogEntry>[];

  void _seedFixtureStore() {
    if (_store.isNotEmpty) return;
    final foods = fx.buildSeedFoods();
    _store.addAll(fx.buildSeedLogEntries(foods));
  }

  Future<List<LogEntry>> entriesForDate(DateTime date) async {
    if (_useFixtures) {
      final out = _store
          .where((e) =>
              e.consumedOn.year == date.year &&
              e.consumedOn.month == date.month &&
              e.consumedOn.day == date.day)
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return out;
    }
    final iso = _isoDate(date);
    final res = await _api.dio.get<Map<String, dynamic>>(
      '/log',
      queryParameters: <String, dynamic>{'from': iso, 'to': iso},
    );
    final body = res.data ?? const <String, dynamic>{};
    final results = (body['results'] as List<dynamic>? ?? const <dynamic>[])
        .cast<Map<String, dynamic>>();
    final entries =
        results.map(_decodeEntryWithDenorm).toList(growable: false);
    entries.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return entries;
  }

  Future<DaySummary> daySummary(DateTime date) async {
    if (_useFixtures) {
      final entries = await entriesForDate(date);
      // Goal is left null here — the day-view falls back to the
      // active goal's targets via its own provider chain.
      return fx.buildDaySummary(
        date: date,
        entriesOnDate: entries,
        activeGoal: null,
      );
    }
    final iso = _isoDate(date);
    final res = await _api.dio.get<Map<String, dynamic>>(
      '/days/$iso/summary',
    );
    final body = res.data ?? const <String, dynamic>{};
    return DaySummary.fromJson(body);
  }

  Future<LogEntry> create(LogCreate data) async {
    if (_useFixtures) {
      final isQuickAdd = data.foodId == quickAddFoodId;
      final food = await _foodRepo.get(data.foodId);
      Serving serving;
      if (isQuickAdd) {
        // Quick-add stores user-typed kcal directly. Build a one-off
        // serving overlay so the snapshot computes to the right kcal.
        serving = food.servings.first.copyWith(
          kcal: data.quantity,
        );
      } else {
        serving = food.servings.firstWhere((s) => s.id == data.servingId);
      }
      final id = 'le_${DateTime.now().microsecondsSinceEpoch}';
      final entry = fx.computeLogEntry(
        id: id,
        food: food,
        serving: serving,
        consumedOn: data.consumedOn,
        meal: data.meal,
        // Quick-add always logs "1 of the (custom-kcal) serving."
        quantity: isQuickAdd ? Decimal.one : data.quantity,
        createdAt: DateTime.now(),
        note: data.note,
      ).copyWith(
        enteredAmount: data.enteredAmount,
        enteredUnit: data.enteredUnit,
      );
      _store.add(entry);
      return entry;
    }

    final isQuickAdd = data.foodId == quickAddFoodId;
    final Map<String, dynamic> body;
    final String path;
    if (isQuickAdd) {
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

    final res = await _api.dio.post<Map<String, dynamic>>(path, data: body);
    final decoded = _decodeEntryWithDenorm(
      res.data ?? const <String, dynamic>{},
    );
    return decoded;
  }

  Future<LogEntry> update(String entryId, LogPatch patch) async {
    if (_useFixtures) {
      final i = _store.indexWhere((e) => e.id == entryId);
      if (i < 0) throw LogEntryNotFoundError(entryId);
      final original = _store[i];

      // Re-resolve serving + food if the patch carries a new serving id.
      final newServingId = patch.servingId ?? original.servingId!;
      final newQuantity = patch.quantity ?? original.quantity;
      final food = await _foodRepo.get(original.foodId);
      final serving =
          food.servings.firstWhere((s) => s.id == newServingId);
      final consumedOn = patch.consumedOn ?? original.consumedOn;
      final meal = patch.meal ?? original.meal;
      final note = patch.clearNote ? null : (patch.note ?? original.note);

      final updated = fx
          .computeLogEntry(
            id: original.id,
            food: food,
            serving: serving,
            consumedOn: consumedOn,
            meal: meal,
            quantity: newQuantity,
            createdAt: original.createdAt,
            note: note,
          )
          .copyWith(
            enteredAmount: patch.enteredAmount ?? original.enteredAmount,
            enteredUnit: patch.enteredUnit ?? original.enteredUnit,
            updatedAt: DateTime.now(),
          );
      _store[i] = updated;
      return updated;
    }

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

  bool isPendingSync(String entryId) {
    final ox = _outbox;
    if (ox == null) return false;
    return ox.isUnsynced(entryId);
  }

  Future<void> delete(String entryId) async {
    if (_useFixtures) {
      final i = _store.indexWhere((e) => e.id == entryId);
      if (i < 0) throw LogEntryNotFoundError(entryId);
      _store.removeAt(i);
      return;
    }
    try {
      await _api.dio.delete<void>('/log/$entryId');
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        throw LogEntryNotFoundError(entryId);
      }
      rethrow;
    }
  }

  void adoptOptimistic(LogEntry entry) {
    if (_useFixtures) {
      _store.add(entry);
    }
  }

  Future<List<LogEntry>> copyDay({
    required DateTime sourceDate,
    required DateTime targetDate,
    List<Meal>? meals,
  }) async {
    if (_useFixtures) {
      final src = await entriesForDate(sourceDate);
      final filtered = meals == null
          ? src
          : src.where((e) => meals.contains(e.meal)).toList();
      final out = <LogEntry>[];
      for (final e in filtered) {
        final food = await _foodRepo.get(e.foodId);
        final serving = food.servings.firstWhere(
          (s) => s.id == e.servingId,
          orElse: () => food.defaultServing,
        );
        final id = 'le_${DateTime.now().microsecondsSinceEpoch}_${out.length}';
        final copied = fx
            .computeLogEntry(
              id: id,
              food: food,
              serving: serving,
              consumedOn: targetDate,
              meal: e.meal,
              quantity: e.quantity,
              createdAt: DateTime.now(),
              note: e.note,
            )
            .copyWith(
              enteredAmount: e.enteredAmount,
              enteredUnit: e.enteredUnit,
            );
        _store.add(copied);
        out.add(copied);
      }
      return out;
    }

    final fromIso = _isoDate(sourceDate);
    final toIso = _isoDate(targetDate);

    final mealList = meals;
    final List<Map<String, dynamic>> bodies;
    if (mealList == null) {
      bodies = <Map<String, dynamic>>[
        <String, dynamic>{'from_date': fromIso, 'to_date': toIso},
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
      }
    }
    return created;
  }

  Future<int> weeklyLogDayCount({DateTime? now}) async {
    final clockNow = now ?? DateTime.now();
    final weekStart = _mondayOfWeek(clockNow);
    final weekEndInclusive = weekStart.add(const Duration(days: 6));
    if (_useFixtures) {
      final days = <String>{};
      for (final e in _store) {
        if (e.consumedOn.isBefore(weekStart)) continue;
        if (e.consumedOn.isAfter(weekEndInclusive)) continue;
        days.add(_isoDate(e.consumedOn));
      }
      return days.length;
    }

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
  /// from the local food catalog. The new wire shape carries
  /// `food_name` / `serving_name` natively (Ask 9 / Ask 10c), but the
  /// fallback path stays defensive against rows whose food was deleted
  /// between log-time and now.
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

  DateTime _mondayOfWeek(DateTime now) {
    final daysSinceMonday = now.weekday - 1;
    return DateTime(now.year, now.month, now.day - daysSinceMonday);
  }

  /// Per-instance reset for fixture-mode tests.
  void resetInstanceForTesting() {
    _store.clear();
    if (_useFixtures) _seedFixtureStore();
  }

  /// No-op static reset retained for source compat with the pre-Ask-10
  /// `test/repositories/_harness.dart`. Fixture state is per-instance.
  static void resetForTesting() {}
}

String _isoDate(DateTime d) {
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}
