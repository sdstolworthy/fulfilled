import 'package:dio/dio.dart';

import '../data/api_client.dart';
import '../domain/goal.dart';

/// Read + write surface for `Goal`. Mirrors `/goals*` paths in
/// `specs/openapi.yaml`.
///
/// **Active-goal-on-date semantics.** `GET /goals/active?on=YYYY-MM-DD`
/// returns the goal whose `(starts_on, ends_on)` range covers the date.
/// The server returns `404 not_found` when nothing covers it; we map
/// that to [GoalNotFoundError] so screens render a "Set a goal"
/// affordance (`LogRepository._activeGoalForDateSafely` catches the
/// throw and translates it to `null`).
///
/// **Wire-shape note.** The live `GET /goals` returns a flat JSON
/// array — not the paginated envelope that other list endpoints in the
/// openapi spec use. The openapi schema for `/goals` confirms this
/// (`type: array, items: Goal`), so this matches spec.
///
/// **`isActive` is presentation-only.** The wire `Goal` schema has no
/// `is_active` flag — it's derived from "is this the row covering
/// today?". `active()` stamps `isActive: true` on the returned row;
/// `all()` stamps `isActive: true` on whichever row covers today (and
/// `false` on the rest) so screen 07's history list can pick out the
/// active row without a second call.
class GoalRepository {
  GoalRepository(this._api);

  final ApiClient _api;

  /// Format a `DateTime` as the local-calendar `YYYY-MM-DD` string the
  /// wire expects (T-16). Using `toIso8601String()` would include a
  /// time component and risk shifting the day in the server's parse.
  static String _formatDate(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }

  /// Goal active on a given date — defaults to today. Throws
  /// [GoalNotFoundError] when the server returns `404 not_found`
  /// (no goal covers the date). Screens render a "Set a goal"
  /// affordance off the throw; the day-summary path swallows it
  /// internally (see `LogRepository._activeGoalForDateSafely`).
  Future<Goal> active({DateTime? on}) async {
    final d = on ?? DateTime.now();
    final day = DateTime(d.year, d.month, d.day);
    try {
      final res = await _api.dio.get<dynamic>(
        '/goals/active',
        queryParameters: <String, dynamic>{'on': _formatDate(day)},
      );
      final data = res.data as Map<String, dynamic>;
      // Wire has no `is_active`; stamp it true since by definition this
      // call returned a row covering `day`.
      return Goal.fromJson(data).copyWith(isActive: true);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        throw GoalNotFoundError(day);
      }
      rethrow;
    }
  }

  /// Every goal the caller owns, newest started first. Screen 07's
  /// history list filters client-side per architect §9 ("filter history
  /// client-side as `endedOn != null OR id != active.id`").
  ///
  /// Stamps `isActive` based on the (starts_on, ends_on) range covering
  /// today so the active row carries the same presentation flag the
  /// `active()` path uses.
  Future<List<Goal>> all() async {
    final res = await _api.dio.get<dynamic>('/goals');
    final list = (res.data as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .map(Goal.fromJson)
        .toList();

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final stamped = <Goal>[
      for (final g in list) g.copyWith(isActive: _covers(g, today)),
    ]..sort((a, b) => b.startedOn.compareTo(a.startedOn));
    return stamped;
  }

  bool _covers(Goal g, DateTime day) {
    final start = DateTime(g.startedOn.year, g.startedOn.month, g.startedOn.day);
    if (day.isBefore(start)) return false;
    final end = g.endedOn;
    if (end == null) return true;
    final endDay = DateTime(end.year, end.month, end.day);
    // OpenAPI `ends_on` is inclusive — the goal is active through that
    // date.
    return !day.isAfter(endDay);
  }

  /// Create a new goal. POSTs to `/goals`; server enforces the
  /// contiguous-goal invariant.
  ///
  /// `@invalidates`
  /// - `activeGoalProvider` — the new row supersedes the prior active
  ///   goal.
  /// - `goalsProvider` — the history list gains the new row.
  ///
  /// Call sites are responsible for invalidating per T-18 (minimal +
  /// explicit); this list is the **contract** the call site reads.
  /// `daySummaryProvider` is intentionally absent — for today the
  /// ring + macros derive live from
  /// `effectiveActiveGoalTargetsProvider`, which watches
  /// `activeGoalProvider` and rebuilds on its own; for past days the
  /// BE-returned value is the per-day historical snapshot we want
  /// to keep.
  Future<Goal> create(GoalCreate data) async {
    final res = await _api.dio.post<dynamic>(
      '/goals',
      data: data.toJson(),
    );
    final body = res.data as Map<String, dynamic>;
    // The newly created goal is active iff it has no `ends_on`. Stamp
    // it so screen 07 doesn't need to round-trip `active()` to render
    // the hero card after a create.
    final created = Goal.fromJson(body);
    return created.copyWith(isActive: created.endedOn == null);
  }

  /// Mutate an existing goal. Sends a PATCH against `/goals/{id}` with
  /// the editable fields lifted off [goal]. PATCH is sparse on the
  /// server (omitted fields stay unchanged); we send the full editable
  /// set because [Goal.copyWith] guarantees the caller's edits are
  /// already merged into `goal`. Throws [GoalNotFoundError] when the
  /// server returns `404 not_found`.
  ///
  /// `@invalidates`
  /// - `activeGoalProvider` — the active row's fields may have shifted.
  /// - `goalsProvider` — the history list reflects the edited row.
  ///
  /// See `create` for why `daySummaryProvider` is absent.
  Future<Goal> update(Goal goal) async {
    final patch = <String, dynamic>{
      'starts_on': _formatDate(goal.startedOn),
      if (goal.endedOn != null) 'ends_on': _formatDate(goal.endedOn!),
      if (goal.startWeightKg != null)
        'start_weight_kg': goal.startWeightKg!.toString(),
      if (goal.targetWeightKg != null)
        'target_weight_kg': goal.targetWeightKg!.toString(),
      if (goal.weeklyRateKg != null)
        'weekly_rate_kg': goal.weeklyRateKg!.toString(),
      if (goal.dailyCalorieTarget != null)
        'daily_calorie_target': goal.dailyCalorieTarget,
      if (goal.proteinTargetG != null)
        'protein_g_target': goal.proteinTargetG!.toString(),
      if (goal.carbsTargetG != null)
        'carbs_g_target': goal.carbsTargetG!.toString(),
      if (goal.fatTargetG != null)
        'fat_g_target': goal.fatTargetG!.toString(),
    };
    try {
      final res = await _api.dio.patch<dynamic>(
        '/goals/${goal.id}',
        data: patch,
      );
      final body = res.data as Map<String, dynamic>;
      final updated = Goal.fromJson(body);
      // Preserve the caller's `isActive` intent — the wire doesn't
      // carry one and the in-place edit doesn't change which row is
      // active.
      return updated.copyWith(isActive: goal.isActive);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        throw GoalNotFoundError(null);
      }
      rethrow;
    }
  }

  /// Delete a goal. Maps `404 not_found` to [GoalNotFoundError]. Other
  /// non-2xx responses propagate the [DioException] for the call site
  /// to surface.
  Future<void> delete(String id) async {
    try {
      await _api.dio.delete<dynamic>('/goals/$id');
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        throw GoalNotFoundError(null);
      }
      rethrow;
    }
  }

  /// Promote a historical goal to active. The openapi surface has no
  /// dedicated `make_active` endpoint — the architect path is "POST a
  /// new goal" (`create`) or "PATCH the target row's `ends_on` to
  /// null", relying on the server to maintain the contiguous-goal
  /// invariant. Until that wire shape is nailed down this throws so
  /// call sites fail loudly instead of silently no-op'ing.
  Future<Goal> makeActive(String id) async {
    throw UnimplementedError(
      'makeActive is not wired to the live API; see goal_repository.dart',
    );
  }

  /// Test hook retained for harness compatibility. The repository no
  /// longer keeps any in-memory state (every read/write hits the wire),
  /// so this is now a no-op — the underlying server state is reset by
  /// the test's HTTP layer (fake Dio adapter, in-memory server, etc.).
  static void resetForTesting() {}
}

/// Thrown by [GoalRepository.active] / [GoalRepository.update] /
/// [GoalRepository.delete] / [GoalRepository.makeActive] when the
/// server returns `404 not_found` (no goal covers the date, or the
/// id is unknown).
class GoalNotFoundError implements Exception {
  GoalNotFoundError(this.on);
  final DateTime? on;

  @override
  String toString() => on == null
      ? 'GoalNotFoundError: no goal with that id'
      : 'GoalNotFoundError: no active goal on $on';
}
