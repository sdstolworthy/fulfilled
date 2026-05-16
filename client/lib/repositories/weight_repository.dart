import 'package:decimal/decimal.dart';

import '../data/api_client.dart';
import '../domain/enums.dart';
import '../domain/weight.dart';
import '_fixtures.dart';
import '_mock_latency.dart';

/// Read + write surface for `WeightEntry`. Mirrors `/weights` paths in
/// the OpenAPI doc.
///
/// **Moving-avg gotcha (architect §9 screen 06).** The server returns
/// raw entries; the 7-day moving average is computed client-side. The
/// repository wraps the raw list in [series], which materializes
/// [WeightSeriesPoint]s with [WeightSeriesPoint.movingAvg7d] set for
/// every point with at least six predecessors. Math is in `Decimal`
/// (T-17) — never `double`.
///
/// **v2 follow-up.** Currently kg-only on display (PM Risk 4). When
/// `User.weight_unit` ships, gate the formatter in `lib/domain/units/`
/// on that preference — not here.
class WeightRepository {
  WeightRepository(this._api);

  // ignore: unused_field — kept for parity with the eventual real client.
  final ApiClient _api;

  static List<WeightEntry>? _entries;
  static int _seq = 0;

  List<WeightEntry> get _state {
    final cached = _entries;
    if (cached != null) return cached;
    final list = <WeightEntry>[...buildSeedWeights()]
      ..sort((a, b) => a.recordedOn.compareTo(b.recordedOn));
    _entries = list;
    return list;
  }

  /// Series for the chart, ascending by date. The range filters entries
  /// to the last N days for `1W / 1M / 3M / 1Y`, or returns the full
  /// history for `all`. Moving avg is computed over the unfiltered
  /// history so an early-range point still has a meaningful average
  /// (it sees the six prior entries even though they aren't drawn).
  Future<List<WeightSeriesPoint>> series(WeightRange range) async {
    await mockLatency();
    final full = buildWeightSeries(_state);
    final n = range.days;
    if (n == null) return full;
    if (full.length <= n) return full;
    return full.sublist(full.length - n);
  }

  /// Newest-first history list (screen 06 shows the last `limit`
  /// entries with their date / weight / delta).
  Future<List<WeightEntry>> history({int limit = 10}) async {
    await mockLatency();
    final out = <WeightEntry>[..._state]
      ..sort((a, b) => b.recordedOn.compareTo(a.recordedOn));
    if (out.length <= limit) return out;
    return out.sublist(0, limit);
  }

  /// Append a weight entry. If an entry already exists for [date], the
  /// new value replaces it — matches the OpenAPI `409 conflict` rule
  /// ("one weight per local-day") by collapsing client-side. The
  /// real client surfaces the 409 inline; the mock paves over it for
  /// the optimistic insert path the architect calls out for `POST
  /// /weights`.
  ///
  /// `@invalidates`
  /// - `weightSeriesProvider(<range>)` for every range — the active
  ///   range first per the existing call-site convention, then the
  ///   inactive ranges so a range-switch repaints fresh.
  /// - `weightHistoryProvider` — the newest-first history list.
  /// - `meProvider` — `User.currentWeightKg` is derived from the
  ///   most recent entry (see [mostRecentKg]).
  ///
  /// Call sites are responsible for invalidating per T-18 (minimal +
  /// explicit); this list is the **contract** the call site reads. A
  /// new dependent provider is added by editing this list and the call
  /// sites in the same PR.
  Future<WeightEntry> create(double weightKg, DateTime date) async {
    await mockLatency();
    final day = DateTime(date.year, date.month, date.day);
    final now = DateTime.now();
    final asDecimal = Decimal.parse(weightKg.toStringAsFixed(1));

    final existingIdx =
        _state.indexWhere((e) => _sameDay(e.recordedOn, day));
    if (existingIdx >= 0) {
      final replaced = _state[existingIdx].copyWith(
        weightKg: asDecimal,
        recordedAtLocal:
            '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}',
      );
      _state[existingIdx] = replaced;
      return replaced;
    }

    final id = 'w_new_${_seq++}_${now.microsecondsSinceEpoch}';
    final created = WeightEntry(
      id: id,
      recordedOn: day,
      recordedAtLocal:
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}',
      weightKg: asDecimal,
      createdAt: now,
    );
    _state.add(created);
    _state.sort((a, b) => a.recordedOn.compareTo(b.recordedOn));
    return created;
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// Internal — drives [ProfileRepository.me] so the user's "current
  /// weight" displays the most recent entry without two providers
  /// disagreeing.
  Decimal? mostRecentKg() {
    if (_state.isEmpty) return null;
    final sorted = <WeightEntry>[..._state]
      ..sort((a, b) => b.recordedOn.compareTo(a.recordedOn));
    return sorted.first.weightKg;
  }

  static void resetForTesting() {
    _entries = <WeightEntry>[...buildSeedWeights()]
      ..sort((a, b) => a.recordedOn.compareTo(b.recordedOn));
    _seq = 0;
  }
}
