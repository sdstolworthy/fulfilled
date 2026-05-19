// LU-001 — optimistic-id reconciliation between the log-entry sheet and
// the outbox.
//
// Before LU-001 the log-entry sheet stamped its optimistic
// `LogEntry.id` with `'optimistic_${microsecondsSinceEpoch}'` and the
// outbox separately rolled a UUID for its persistence key. The two
// strings were unrelated, so `LogRepository.isPendingSync(entryId)`
// had no key to look against (architect §2.6).
//
// This test pins the new contract: `LogOutboxNotifier.enqueue` accepts
// an `optimisticId` parameter; whatever string the sheet uses for the
// optimistic row's id is stored on the outbox record. The repository's
// `isPendingSync` predicate then correlates them.

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/data/api_client.dart';
import 'package:fulfilled/data/outbox/log_outbox_notifier.dart';
import 'package:fulfilled/repositories/food_repository.dart';
import 'package:fulfilled/repositories/goal_repository.dart';
import 'package:fulfilled/repositories/log_repository.dart';
import 'package:hive/hive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory hiveDir;
  late Box<String> box;

  setUp(() async {
    hiveDir =
        await Directory.systemTemp.createTemp('fulfilled-optimistic-id-');
    Hive.init(hiveDir.path);
    box = await Hive.openBox<String>(outboxBoxName);
  });

  tearDown(() async {
    await Hive.close();
    if (hiveDir.existsSync()) {
      hiveDir.deleteSync(recursive: true);
    }
  });

  /// Mirror the log-entry sheet's id stamp pattern
  /// (`log_entry_sheet.dart:321`). Centralised here so the test breaks
  /// loudly if anyone drifts the pattern.
  String buildOptimisticId(DateTime at) =>
      'optimistic_${at.microsecondsSinceEpoch}';

  /// Stub `LogPostFn` that hangs forever — we don't want the drain
  /// loop completing during these tests because the outbox would
  /// delete the entry before we can assert on its state. Hanging (vs.
  /// throwing) also avoids re-entering the box after the test has
  /// torn down Hive.
  Future<String> hangsForever(Map<String, dynamic> payload) {
    return Completer<String>().future;
  }

  group('enqueue stores optimisticId', () {
    test('enqueue with optimisticId stores it verbatim on the record', () async {
      final notifier = LogOutboxNotifier(box: box, postLog: hangsForever);
      final optimisticId = buildOptimisticId(DateTime.now());

      await notifier.enqueue(
        payload: <String, dynamic>{'food_id': 'f_x', 'quantity': '1'},
        optimisticId: optimisticId,
      );

      final stored = notifier.state.entries.single;
      expect(stored.entry.optimisticId, optimisticId);
      // The outbox row's `id` is a UUID — distinct from the optimistic
      // id, but the optimistic id is what we'll correlate against.
      expect(stored.entry.id, isNot(optimisticId));
      notifier.dispose();
    });

    test('the stored optimisticId matches what the sheet would stamp '
        'into the resulting LogEntry.id', () async {
      // The sheet's contract: it calls `enqueue(optimisticId: id)` and
      // pops with a `LogEntry` whose `id` is the same string. We
      // exercise the seam: the same string we hand to enqueue is the
      // string the predicate would later look up.
      final notifier = LogOutboxNotifier(box: box, postLog: hangsForever);
      final now = DateTime.now();
      final optimisticId = buildOptimisticId(now);

      await notifier.enqueue(
        payload: <String, dynamic>{'food_id': 'f_x', 'quantity': '1'},
        optimisticId: optimisticId,
      );

      // The sheet's eventual `LogEntry.id` will be exactly this string.
      expect(notifier.state.entries.single.entry.optimisticId, optimisticId);
      notifier.dispose();
    });

    test('enqueue without optimisticId falls back to the outbox id '
        '(pre-LU-001 behaviour)', () async {
      final notifier = LogOutboxNotifier(box: box, postLog: hangsForever);

      await notifier.enqueue(
        payload: <String, dynamic>{'food_id': 'f_x', 'quantity': '1'},
      );

      final stored = notifier.state.entries.single;
      expect(stored.entry.optimisticId, stored.entry.id);
      notifier.dispose();
    });
  });

  group('isPendingSync', () {
    test('returns true for an entry whose optimisticId matches a pending '
        'outbox record', () async {
      final notifier = LogOutboxNotifier(box: box, postLog: hangsForever);
      final optimisticId = buildOptimisticId(DateTime.now());
      await notifier.enqueue(
        payload: <String, dynamic>{'food_id': 'f_x', 'quantity': '1'},
        optimisticId: optimisticId,
      );

      final api = ApiClient(Dio(), baseUrl: 'about:invalid');
      final repo = LogRepository(
        api: api,
        foodRepository: FoodRepository(api),
        goalRepository: GoalRepository(api),
        outbox: notifier,
      );

      expect(repo.isPendingSync(optimisticId), isTrue);
      expect(repo.isPendingSync('some_other_id'), isFalse);
      notifier.dispose();
    });

    test('returns false on a null outbox (medium/expanded wiring)', () {
      final api = ApiClient(Dio(), baseUrl: 'about:invalid');
      final repo = LogRepository(
        api: api,
        foodRepository: FoodRepository(api),
        goalRepository: GoalRepository(api),
        // outbox: null — the medium/expanded wiring.
      );

      expect(repo.isPendingSync('anything'), isFalse);
      expect(repo.isPendingSync(''), isFalse);
    });

    test('returns true for a failed entry (max attempts reached)', () async {
      // Pre-seed the box with a record that's already at the terminal
      // failure threshold so hydration classifies it as `failed`.
      final optimisticId = buildOptimisticId(DateTime.now());
      // Construct the record JSON by hand to bypass the drain loop.
      // Same shape as `OutboxEntry.toJson`.
      const failed = '{'
          '"id":"outbox-uuid-1",'
          '"optimisticId":"<<ID>>",'
          '"payload":{},'
          '"queuedAt":"2026-05-15T12:00:00.000",'
          '"attempt":3,'
          '"lastError":"server 500"'
          '}';
      await box.put(
        'outbox-uuid-1',
        failed.replaceAll('<<ID>>', optimisticId),
      );

      final notifier = LogOutboxNotifier(box: box, postLog: hangsForever);
      // Hydration runs in the constructor; the record should be
      // classified as `failed`.
      expect(notifier.state.failedCount, 1);

      final api = ApiClient(Dio(), baseUrl: 'about:invalid');
      final repo = LogRepository(
        api: api,
        foodRepository: FoodRepository(api),
        goalRepository: GoalRepository(api),
        outbox: notifier,
      );
      expect(repo.isPendingSync(optimisticId), isTrue);
      notifier.dispose();
    });
  });

  group('OutboxEntry.fromJson back-compat', () {
    test('records persisted before LU-001 (no optimisticId key) hydrate '
        'with optimisticId == id', () async {
      // Pre-LU-001 JSON had no `optimisticId` key.
      const legacy = '{'
          '"id":"outbox-legacy-1",'
          '"payload":{},'
          '"queuedAt":"2026-05-15T12:00:00.000",'
          '"attempt":0'
          '}';
      await box.put('outbox-legacy-1', legacy);

      final notifier = LogOutboxNotifier(box: box, postLog: hangsForever);
      final entry = notifier.state.entries.single.entry;
      expect(entry.id, 'outbox-legacy-1');
      expect(entry.optimisticId, 'outbox-legacy-1');
      notifier.dispose();
    });
  });
}
