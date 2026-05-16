import '../data/api_client.dart';
import '../domain/goal.dart';
import '_fixtures.dart';
import '_mock_latency.dart';

/// Read + write surface for `Goal`. Mirrors `/goals*` paths in the
/// OpenAPI doc.
///
/// **Active-goal-on-date semantics.** `GET /goals/active?on=YYYY-MM-DD`
/// returns the goal whose `(starts_on, ends_on)` range covers the date.
/// The mock repository mirrors that — `active(on: date)` walks all
/// goals and returns the one currently in force; `active()` without an
/// arg means "today".
class GoalRepository {
  GoalRepository(this._api);

  // ignore: unused_field — kept for parity with the eventual real client.
  final ApiClient _api;

  /// In-memory goals. The active one is stamped `isActive: true`; the
  /// others are historical (have `endedOn`). Mutations preserve the
  /// invariant: exactly one goal has `isActive == true`.
  static List<Goal>? _goals;

  static int _seq = 0;

  List<Goal> get _state {
    final cached = _goals;
    if (cached != null) return cached;
    final list = <Goal>[buildSeedPreviousGoal(), buildSeedActiveGoal()];
    _goals = list;
    return list;
  }

  /// Goal active on a given date — defaults to today. Throws
  /// [GoalNotFoundError] when no goal covers the date. Match the
  /// OpenAPI `404` shape so screen agents can render a "Set a goal"
  /// affordance.
  Future<Goal> active({DateTime? on}) async {
    await mockLatency();
    final d = on ?? DateTime.now();
    final day = DateTime(d.year, d.month, d.day);
    for (final g in _state) {
      if (!_covers(g, day)) continue;
      return g.copyWith(isActive: true);
    }
    throw GoalNotFoundError(day);
  }

  bool _covers(Goal g, DateTime day) {
    final start = DateTime(g.startedOn.year, g.startedOn.month, g.startedOn.day);
    if (day.isBefore(start)) return false;
    final end = g.endedOn;
    if (end == null) return true;
    final endDay = DateTime(end.year, end.month, end.day);
    // The OpenAPI semantics treat `ends_on` as inclusive — the goal is
    // active through the end date.
    return !day.isAfter(endDay);
  }

  /// Every goal the caller owns, newest started first. Screen 07's
  /// history list filters client-side per architect §9 ("filter history
  /// client-side as `endedOn != null OR id != active.id`").
  Future<List<Goal>> all() async {
    await mockLatency();
    final out = <Goal>[..._state]
      ..sort((a, b) => b.startedOn.compareTo(a.startedOn));
    return out;
  }

  /// Create a new goal. The new row becomes active "from today"; any
  /// previously-active row gets its `endedOn` stamped to yesterday so
  /// the active invariant holds. Mirrors what the server does on
  /// `POST /goals` for a contiguous goal stream.
  Future<Goal> create(GoalCreate data) async {
    await mockLatency();
    final id = 'g_new_${_seq++}_${DateTime.now().microsecondsSinceEpoch}';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    // Close out any currently-active row by stamping `endedOn = yesterday`.
    final yesterday = today.subtract(const Duration(days: 1));
    for (var i = 0; i < _state.length; i++) {
      final g = _state[i];
      if (g.isActive) {
        _state[i] = g.copyWith(isActive: false, endedOn: yesterday);
      }
    }

    final created = Goal(
      id: id,
      startedOn: data.startsOn,
      endedOn: data.endsOn,
      startWeightKg: data.startWeightKg,
      targetWeightKg: data.targetWeightKg,
      weeklyRateKg: data.weeklyRateKg,
      dailyCalorieTarget: data.dailyCalorieTarget,
      proteinTargetG: data.proteinTargetG,
      carbsTargetG: data.carbsTargetG,
      fatTargetG: data.fatTargetG,
      isActive: data.endsOn == null,
      createdAt: now,
      updatedAt: now,
    );
    _state.add(created);
    return created;
  }

  /// Promote a historical goal to active. Mostly relevant for the
  /// "restore a prior goal" affordance — not directly mocked in the UI
  /// but the screen 07 agent's `goalRepositoryProvider` contract names
  /// it, so it's here.
  Future<Goal> makeActive(String id) async {
    await mockLatency();
    Goal? target;
    for (var i = 0; i < _state.length; i++) {
      if (_state[i].id == id) {
        target = _state[i];
      }
    }
    if (target == null) throw GoalNotFoundError(null);

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));

    for (var i = 0; i < _state.length; i++) {
      final g = _state[i];
      if (g.id == target.id) {
        _state[i] = g.copyWith(
          isActive: true,
          endedOn: null,
          updatedAt: now,
        );
      } else if (g.isActive) {
        _state[i] = g.copyWith(isActive: false, endedOn: yesterday);
      }
    }

    return _state.firstWhere((g) => g.id == target!.id);
  }

  // Test seam — restore the seed.
  static void resetForTesting() {
    _goals = <Goal>[buildSeedPreviousGoal(), buildSeedActiveGoal()];
    _seq = 0;
  }
}

/// Thrown by [GoalRepository.active] / [GoalRepository.makeActive] when
/// no goal covers the date / when the id is unknown.
class GoalNotFoundError implements Exception {
  GoalNotFoundError(this.on);
  final DateTime? on;

  @override
  String toString() => on == null
      ? 'GoalNotFoundError: no goal with that id'
      : 'GoalNotFoundError: no active goal on $on';
}
