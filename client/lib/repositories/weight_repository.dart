import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';

import '../data/api_client.dart';
import '../domain/enums.dart';
import '../domain/weight.dart';
import '_fixtures.dart' show buildWeightSeries;

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

  final ApiClient _api;

  /// `GET /weights` — paginated history of the caller's weight entries,
  /// newest recorded-day first.
  ///
  /// Envelope: `{ results, total, limit, offset }` per
  /// `#/components/schemas/PaginatedWeights`. With no parameters the
  /// server returns the 100 most-recent entries across the full
  /// history (openapi.yaml line ~165). `since` / `until` map to the
  /// `from` / `to` ISO-date query params; `limit` / `offset` pass
  /// through.
  Future<List<WeightEntry>> list({
    DateTime? since,
    DateTime? until,
    int? limit,
    int? offset,
  }) async {
    final Response<dynamic> resp;
    try {
      resp = await _api.dio.get<dynamic>(
        '/weights',
        queryParameters: <String, dynamic>{
          if (since != null) 'from': _isoDate(since),
          if (until != null) 'to': _isoDate(until),
          if (limit != null) 'limit': limit,
          if (offset != null) 'offset': offset,
        },
      );
    } on DioException catch (e) {
      throw _mapDioError(e);
    }
    final body = resp.data as Map<String, dynamic>;
    final results = (body['results'] as List<dynamic>? ?? const <dynamic>[]);
    return results
        .map((r) => WeightEntry.fromJson(r as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Most-recent weight entry. No dedicated `/weights/latest` endpoint
  /// exists in the openapi spec — the server lists newest-first, so
  /// `list(limit: 1)` is equivalent. Throws [WeightNotFoundError] if
  /// the caller has no entries yet (the empty-history case).
  Future<WeightEntry> latest() async {
    final page = await list(limit: 1);
    if (page.isEmpty) {
      throw WeightNotFoundError._empty();
    }
    return page.first;
  }

  /// `POST /weights` with a `WeightCreate` body. Returns the decoded
  /// server response (id + timestamps populated by the server).
  ///
  /// The wire schema only carries `recorded_on`, `recorded_at_local`,
  /// `weight_kg`, and optional `note` — [WeightEntry.toJson] additionally
  /// emits `id` and `created_at`, but unknown keys on a create body are
  /// ignored by the server. We hand-roll the body here to keep the wire
  /// shape exactly what the server documents.
  ///
  /// `@invalidates`
  /// - `weightSeriesProvider(<range>)` for every range — the active
  ///   range first per the existing call-site convention, then the
  ///   inactive ranges so a range-switch repaints fresh.
  /// - `weightHistoryProvider` — the newest-first history list.
  /// - `meProvider` — `User.currentWeightKg` is derived from the
  ///   most recent entry (see [ProfileRepository.me]).
  ///
  /// Call sites are responsible for invalidating per T-18 (minimal +
  /// explicit); this list is the **contract** the call site reads. A
  /// new dependent provider is added by editing this list and the call
  /// sites in the same PR.
  Future<WeightEntry> createEntry(WeightEntry entry) async {
    final body = <String, dynamic>{
      'recorded_on': _isoDate(entry.recordedOn),
      if (entry.recordedAtLocal != null)
        'recorded_at_local': entry.recordedAtLocal,
      'weight_kg': entry.weightKg.toString(),
      if (entry.note != null) 'note': entry.note,
    };
    final Response<dynamic> resp;
    try {
      resp = await _api.dio.post<dynamic>('/weights', data: body);
    } on DioException catch (e) {
      throw _mapDioError(e);
    }
    return WeightEntry.fromJson(resp.data as Map<String, dynamic>);
  }

  /// Back-compat shim — the historical client surface accepts a raw
  /// `(weightKg, date)` pair. New code should call [createEntry] with a
  /// fully-formed [WeightEntry] instead.
  ///
  /// Decimal handling per T-17: parse from a one-decimal string so the
  /// JSON wire shape stays a number-shaped string and never inherits
  /// `double` drift.
  Future<WeightEntry> create(double weightKg, DateTime date) async {
    final now = DateTime.now();
    final entry = WeightEntry(
      id: '', // server assigns; the field is ignored on POST.
      recordedOn: DateTime(date.year, date.month, date.day),
      recordedAtLocal:
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}',
      weightKg: Decimal.parse(weightKg.toStringAsFixed(1)),
      createdAt: now,
    );
    return createEntry(entry);
  }

  /// `DELETE /weights/{id}`. Returns void on 204; raises
  /// [WeightNotFoundError] on 404.
  Future<void> delete(String id) async {
    try {
      await _api.dio.delete<void>('/weights/$id');
    } on DioException catch (e) {
      throw _mapDioError(e, id: id);
    }
  }

  /// Series for the chart, ascending by date. The range filters entries
  /// to the last N days for `1W / 1M / 3M / 1Y`, or returns the full
  /// history for `all`. Moving avg is computed over the unfiltered
  /// history so an early-range point still has a meaningful average
  /// (it sees the six prior entries even though they aren't drawn).
  ///
  /// Backed by [list] — the server returns newest-first; we re-sort
  /// ascending before handing to [buildWeightSeries].
  Future<List<WeightSeriesPoint>> series(WeightRange range) async {
    final raw = await list();
    final asc = <WeightEntry>[...raw]
      ..sort((a, b) => a.recordedOn.compareTo(b.recordedOn));
    final full = buildWeightSeries(asc);
    final n = range.days;
    if (n == null) return full;
    if (full.length <= n) return full;
    return full.sublist(full.length - n);
  }

  /// Newest-first history list (screen 06 shows the last `limit`
  /// entries with their date / weight / delta). Backed by [list] —
  /// the server already returns newest-first.
  Future<List<WeightEntry>> history({int limit = 10}) async {
    return list(limit: limit);
  }

  Exception _mapDioError(DioException e, {String? id}) {
    if (e.response?.statusCode == 404) {
      return WeightNotFoundError(id: id);
    }
    return e;
  }

  static String _isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// No-op kept for test-harness parity with the previous mock-backed
  /// implementation. Real state lives on the server; nothing to reset.
  static void resetForTesting() {}
}

/// Thrown by [WeightRepository.latest] when the caller has no weight
/// entries, and by [WeightRepository.delete] when the id is unknown
/// (server 404). The id is null for the empty-history case.
class WeightNotFoundError implements Exception {
  WeightNotFoundError({this.id});

  WeightNotFoundError._empty() : id = null;

  final String? id;

  @override
  String toString() => id == null
      ? 'WeightNotFoundError: no weight entries recorded'
      : 'WeightNotFoundError: no weight entry with id $id';
}
