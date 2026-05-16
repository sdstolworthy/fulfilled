import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

import '../connectivity.dart';
import 'outbox_entry.dart';

/// Hive box name. Opened from `main.dart` before runApp.
const String outboxBoxName = 'outbox_log';

/// Backoff schedule from architecture §5: 1 s, 4 s, then 16 s, then surface.
const List<Duration> _backoffs = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 4),
  Duration(seconds: 16),
];

/// Max attempts before flipping the entry to a terminal "failed" state.
const int maxOutboxAttempts = 3;

/// The pluggable `POST /log` call. The food/log repository injects the real
/// implementation; the notifier stays decoupled from Dio and from
/// presentation models.
///
/// Returns the **server-confirmed** `LogEntry` id (which may differ from
/// the client-generated id — conflict policy: server wins).
typedef LogPostFn = Future<String> Function(Map<String, dynamic> payload);

/// Status the day-view UI projects per entry (T-22: pending sync is visible,
/// not silent). The food row reads from a merged provider that combines
/// server entries with `pending` and `failed` outbox entries.
enum OutboxEntryStatus { pending, failed }

/// View of the outbox the UI consumes — a list of entry/status pairs, plus
/// a top-level flag for the bottom-tab dot.
class OutboxState {
  const OutboxState({
    required this.entries,
    required this.failedCount,
  });

  final List<OutboxEntryWithStatus> entries;
  final int failedCount;

  bool get hasPending => entries.any((e) => e.status == OutboxEntryStatus.pending);
  bool get isEmpty => entries.isEmpty;

  static const OutboxState empty = OutboxState(entries: <OutboxEntryWithStatus>[], failedCount: 0);
}

class OutboxEntryWithStatus {
  const OutboxEntryWithStatus(this.entry, this.status);
  final OutboxEntry entry;
  final OutboxEntryStatus status;
}

/// Mobile-only `POST /log` outbox. T-22 / PM Risk 6.
///
/// **Form-factor gate** — the notifier itself does **not** enforce the
/// `FormFactor.isCompact` gate. The gate happens at the call site
/// (`log_repository.dart` for now, screen agents later): on compact, route
/// the write through the outbox; on medium/expanded, surface errors inline
/// per architecture §5. This is intentional — keeping the gate at the call
/// site keeps the notifier testable without a `MediaQuery`.
///
/// **Persistence** — Hive box `outbox_log`, opened in `main.dart`. Entries
/// are stored as JSON strings keyed by their UUID. The notifier reads the
/// box once at construction and keeps an in-memory snapshot; mutations
/// write through.
///
/// **Drain policy** — exponential backoff per entry: attempts 0/1/2 wait
/// 1 s / 4 s / 16 s before retry; attempt 3 flips the entry to a terminal
/// "failed" state and the UI surfaces a retry affordance. Drain is serial
/// (one entry at a time, FIFO) so the server sees a deterministic order.
///
/// **Conflicts** — the server is authoritative. After a successful POST the
/// caller hands us the server-side id; we drop the queued entry and the
/// optimistic row's nutrition snapshot is replaced by the server response
/// (the merge happens in `log_repository`, not here).
class LogOutboxNotifier extends StateNotifier<OutboxState> {
  LogOutboxNotifier({
    required Box<String> box,
    required LogPostFn postLog,
    Uuid? uuid,
  })  : _box = box,
        _postLog = postLog,
        _uuid = uuid ?? const Uuid(),
        super(OutboxState.empty) {
    _hydrate();
  }

  final Box<String> _box;
  final LogPostFn _postLog;
  final Uuid _uuid;

  bool _draining = false;
  final Map<String, Timer> _retryTimers = <String, Timer>{};

  void _hydrate() {
    final entries = <OutboxEntryWithStatus>[];
    var failed = 0;
    for (final key in _box.keys) {
      final raw = _box.get(key);
      if (raw == null) continue;
      try {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        final entry = OutboxEntry.fromJson(json);
        final status = entry.attempt >= maxOutboxAttempts
            ? OutboxEntryStatus.failed
            : OutboxEntryStatus.pending;
        if (status == OutboxEntryStatus.failed) failed += 1;
        entries.add(OutboxEntryWithStatus(entry, status));
      } catch (_) {
        // A corrupt row is dropped silently — better than crashing the boot.
        // The UI surface for "log was dropped" lives at terminal-failure
        // time; pre-app-boot corruption is rare enough that there's no
        // visible recovery path.
      }
    }
    state = OutboxState(entries: entries, failedCount: failed);
  }

  /// Enqueue a new `POST /log` payload. Returns the client-generated
  /// outbox id so callers can correlate the queued row (the same value
  /// is also stored as [OutboxEntry.optimisticId] by default and is
  /// what `LogRepository.isPendingSync` queries against — see LU-001).
  ///
  /// [optimisticId] lets the log-entry sheet pass the exact same string
  /// it just stamped onto its optimistic `LogEntry.id`
  /// (`'optimistic_${microsecondsSinceEpoch}'`). When omitted, the
  /// outbox falls back to using its UUID for both fields, matching
  /// pre-LU-001 behaviour.
  ///
  /// Idempotent only by client id — callers must not retry by re-enqueuing.
  Future<String> enqueue({
    required Map<String, dynamic> payload,
    String? optimisticId,
    DateTime? now,
  }) async {
    final id = _uuid.v4();
    final entry = OutboxEntry(
      id: id,
      optimisticId: optimisticId ?? id,
      payload: payload,
      queuedAt: now ?? DateTime.now(),
    );
    await _box.put(id, jsonEncode(entry.toJson()));
    _appendToState(entry, OutboxEntryStatus.pending);
    // Fire-and-forget drain; the notifier's call-site contract is "enqueue
    // returns immediately; flush happens on the next connectivity tick or
    // explicit `drain()`."
    unawaited(drain());
    return id;
  }

  void _appendToState(OutboxEntry entry, OutboxEntryStatus status) {
    final next = <OutboxEntryWithStatus>[...state.entries, OutboxEntryWithStatus(entry, status)];
    state = OutboxState(
      entries: next,
      failedCount: next.where((e) => e.status == OutboxEntryStatus.failed).length,
    );
  }

  /// Drain the queue. Walks pending entries FIFO; respects per-entry
  /// backoff. Idempotent — safe to call from connectivity changes,
  /// lifecycle changes, and user retry taps.
  Future<void> drain() async {
    if (_draining) return;
    _draining = true;
    try {
      // Snapshot at start; new entries enqueued mid-drain get picked up on
      // the next call (their own `enqueue` already schedules one).
      final pending = state.entries
          .where((e) => e.status == OutboxEntryStatus.pending)
          .map((e) => e.entry)
          .toList();
      for (final entry in pending) {
        await _attempt(entry);
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _attempt(OutboxEntry entry) async {
    final current = _findCurrent(entry.id);
    if (current == null) return;
    if (current.entry.attempt >= maxOutboxAttempts) return;

    try {
      await _postLog(current.entry.payload);
      await _box.delete(current.entry.id);
      _removeFromState(current.entry.id);
    } catch (e) {
      final nextAttempt = current.entry.attempt + 1;
      final updated = current.entry.copyWith(
        attempt: nextAttempt,
        lastError: e.toString(),
      );
      await _box.put(updated.id, jsonEncode(updated.toJson()));

      final reachedTerminal = nextAttempt >= maxOutboxAttempts;
      _replaceInState(
        updated,
        reachedTerminal ? OutboxEntryStatus.failed : OutboxEntryStatus.pending,
      );

      if (!reachedTerminal) {
        _scheduleRetry(updated.id, nextAttempt);
      }
    }
  }

  OutboxEntryWithStatus? _findCurrent(String id) {
    for (final entry in state.entries) {
      if (entry.entry.id == id) return entry;
    }
    return null;
  }

  void _scheduleRetry(String id, int attemptNumber) {
    _retryTimers[id]?.cancel();
    // attemptNumber is 1-based after the increment above; backoff is indexed
    // by the failed-attempts count we've just recorded.
    final index = (attemptNumber - 1).clamp(0, _backoffs.length - 1);
    final delay = _backoffs[index];
    _retryTimers[id] = Timer(delay, () {
      _retryTimers.remove(id);
      unawaited(drain());
    });
  }

  void _removeFromState(String id) {
    final next = state.entries.where((e) => e.entry.id != id).toList();
    state = OutboxState(
      entries: next,
      failedCount: next.where((e) => e.status == OutboxEntryStatus.failed).length,
    );
  }

  void _replaceInState(OutboxEntry entry, OutboxEntryStatus status) {
    final next = state.entries
        .map((e) => e.entry.id == entry.id ? OutboxEntryWithStatus(entry, status) : e)
        .toList();
    state = OutboxState(
      entries: next,
      failedCount: next.where((e) => e.status == OutboxEntryStatus.failed).length,
    );
  }

  /// User-initiated retry of a failed entry. Resets attempt count to 0 so
  /// the entry rejoins the normal drain loop.
  Future<void> retry(String id) async {
    final current = _findCurrent(id);
    if (current == null) return;
    final reset = current.entry.copyWith(attempt: 0, lastError: null);
    await _box.put(reset.id, jsonEncode(reset.toJson()));
    _replaceInState(reset, OutboxEntryStatus.pending);
    unawaited(drain());
  }

  /// User-initiated discard. Drops the entry; the optimistic row vanishes
  /// (callers must invalidate the day-summary provider).
  Future<void> discard(String id) async {
    await _box.delete(id);
    _retryTimers.remove(id)?.cancel();
    _removeFromState(id);
  }

  @override
  void dispose() {
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    super.dispose();
  }
}

/// Stub `LogPostFn` so the provider compiles before `log_repository` lands.
/// Always throws; the food/log screen agent replaces this in the call site
/// (`logRepositoryProvider`-equivalent) before wiring real screens.
Future<String> _stubPostLog(Map<String, dynamic> payload) async {
  throw UnimplementedError(
    'LogOutboxNotifier requires a real LogPostFn from log_repository. '
    'The food/log screen agent wires this up when implementing screen 04.',
  );
}

/// The notifier provider. Screen agents override `logPostFnProvider` once a
/// real repository exists; until then it points at the throwing stub so the
/// app boots.
final logPostFnProvider = Provider<LogPostFn>((ref) => _stubPostLog);

final outboxBoxProvider = Provider<Box<String>>((ref) {
  throw UnimplementedError(
    'outboxBoxProvider must be overridden in main.dart after Hive opens '
    'the box. See main.dart for the override.',
  );
});

final logOutboxProvider =
    StateNotifierProvider<LogOutboxNotifier, OutboxState>((ref) {
  final box = ref.watch(outboxBoxProvider);
  final postLog = ref.watch(logPostFnProvider);
  final notifier = LogOutboxNotifier(box: box, postLog: postLog);

  // Drain on every online transition. The stream may emit `false` then
  // `true` rapidly during cellular bounces — drain() is idempotent.
  final connSub = ref.listen<AsyncValue<bool>>(
    connectivityProvider,
    (prev, next) {
      final online = next.asData?.value ?? false;
      if (online) unawaited(notifier.drain());
    },
  );
  ref.onDispose(connSub.close);

  return notifier;
});
