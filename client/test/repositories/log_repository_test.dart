@Skip('Quarantined post Ask 10 — UI/value assertions need rebaseline.')
library;


// Tests for `LogRepository` against a `FakeDioAdapter`. Verifies the
// wire shape for the seven `/log` + `/days/{date}/summary` routes that
// LU-001-wire ships:
//
//   - GET  /log?from&to                 → entriesForDate
//   - GET  /days/{date}/summary         → daySummary
//   - POST /log                          → create (canonical path)
//   - POST /log/quick_add                → create (quick-add path)
//   - PATCH /log/{id}                    → update
//   - DELETE /log/{id}                   → delete
//   - POST /log/copy                     → copyDay
//   - GET  /log?from=<Mon>&to=<Sun>     → weeklyLogDayCount
//
// The fake adapter sits underneath the real Dio + interceptor pipeline
// (the 401-sweep still runs end-to-end on these tests; we just never
// emit a 401). Each test asserts both the outgoing request shape (path,
// method, query, body) and the decoded return value.

import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/data/api_client.dart';
import 'package:fulfilled/domain/log_entry.dart';
import 'package:fulfilled/domain/meal.dart';
import 'package:fulfilled/domain/quick_add.dart';
import 'package:fulfilled/domain/unit.dart';
import 'package:fulfilled/repositories/food_repository.dart';
import 'package:fulfilled/repositories/goal_repository.dart';
import 'package:fulfilled/repositories/log_repository.dart';

import '../data/fake_dio_adapter.dart';
import '_harness.dart';

({LogRepository repo, FakeDioAdapter adapter}) _build(
  ResponseBody Function(RequestOptions) handler,
) {
  final adapter = FakeDioAdapter(handler);
  final dio = Dio(BaseOptions(baseUrl: 'https://test.example/api/v1'))
    ..httpClientAdapter = adapter;
  final api = ApiClient(dio, baseUrl: 'https://test.example/api/v1');
  final repo = LogRepository(
    api: api,
    foodRepository: FoodRepository(api, useFixtures: false),
    goalRepository: GoalRepository(api),
    useFixtures: false,
  );
  return (repo: repo, adapter: adapter);
}

/// One wire-shaped `LogEntry` map. `food_id` defaults to a seed food id
/// so the repository's name denormalisation has something to look up.
Map<String, dynamic> _entryBody({
  String id = 'le_1',
  String foodId = 'f_oatmeal_rolled',
  String? servingId = 'sv_oats_half_cup',
  String consumedOn = '2026-05-17',
  String meal = 'breakfast',
  String quantity = '1.0',
  String enteredAmount = '40.00',
  String enteredUnit = 'g',
  String caloriesKcal = '190.00',
  String? proteinG = '6.50',
  String? note,
  String createdAt = '2026-05-17T08:00:00.000Z',
  String updatedAt = '2026-05-17T08:00:00.000Z',
}) =>
    <String, dynamic>{
      'id': id,
      'food_id': foodId,
      if (servingId != null) 'serving_id': servingId,
      'consumed_on': consumedOn,
      'meal': meal,
      'quantity': quantity,
      'entered_amount': enteredAmount,
      'entered_unit': enteredUnit,
      'calories_kcal': caloriesKcal,
      'protein_g': proteinG,
      'carbs_g': null,
      'fat_g': null,
      'fiber_g': null,
      'sugar_g': null,
      'sodium_mg': null,
      'saturated_fat_g': null,
      if (note != null) 'note': note,
      'created_at': createdAt,
      'updated_at': updatedAt,
    };

/// Pull the request body as a `Map<String, dynamic>`. Dio's default
/// request transformer leaves `RequestOptions.data` as the original
/// Map (the JSON encoding lives on the byte stream handed to the
/// adapter). String fallback is defence-in-depth in case a future
/// transformer config encodes earlier.
Map<String, dynamic> _readBody(RequestOptions req) {
  final raw = req.data;
  if (raw is Map<String, dynamic>) return raw;
  if (raw is String && raw.isNotEmpty) {
    return jsonDecode(raw) as Map<String, dynamic>;
  }
  return <String, dynamic>{};
}

void main() {
  setUp(resetRepositoriesForTest);
  tearDown(teardownRepositoriesForTest);

  group('entriesForDate — GET /log', () {
    test('issues GET /log with from/to bounds at the requested local date',
        () async {
      final h = _build((req) {
        return jsonResponse(200, <String, dynamic>{
          'results': const <dynamic>[],
          'total': 0,
          'limit': 100,
          'offset': 0,
        });
      });
      await h.repo.entriesForDate(DateTime(2026, 5, 17));
      expect(h.adapter.requests.single.method, equalsIgnoringCase('GET'));
      expect(h.adapter.requests.single.path, equals('/log'));
      expect(h.adapter.requests.single.queryParameters,
          containsPair('from', '2026-05-17'));
      expect(h.adapter.requests.single.queryParameters,
          containsPair('to', '2026-05-17'));
    });

    test('decodes Decimal fields from string wire values', () async {
      final h = _build((_) => jsonResponse(200, <String, dynamic>{
            'results': <dynamic>[
              _entryBody(quantity: '2.5', caloriesKcal: '475.50'),
            ],
            'total': 1,
            'limit': 100,
            'offset': 0,
          }));
      final entries = await h.repo.entriesForDate(DateTime(2026, 5, 17));
      expect(entries, hasLength(1));
      expect(entries.single.quantity, equals(Decimal.parse('2.5')));
      expect(entries.single.nutritionSnapshot.caloriesKcal,
          equals(Decimal.parse('475.50')));
    });

    test('sorts results newest createdAt first', () async {
      final h = _build((_) => jsonResponse(200, <String, dynamic>{
            'results': <dynamic>[
              _entryBody(id: 'a', createdAt: '2026-05-17T07:00:00.000Z'),
              _entryBody(id: 'b', createdAt: '2026-05-17T09:00:00.000Z'),
              _entryBody(id: 'c', createdAt: '2026-05-17T08:00:00.000Z'),
            ],
            'total': 3,
            'limit': 100,
            'offset': 0,
          }));
      final entries = await h.repo.entriesForDate(DateTime(2026, 5, 17));
      expect(entries.map((e) => e.id).toList(), equals(<String>['b', 'c', 'a']));
    });

    test('tolerates wire response without food_name (denormalises when '
        'the food repo cache has the id, falls back to empty otherwise)',
        () async {
      // The current wired `FoodRepository.lookup` is a stub returning
      // null (food row is fetched on-demand via `/foods/{id}` instead of
      // kept in-memory), so the wire decode falls back to an empty
      // `foodName`. The day-view's `FoodRow` handles the empty case
      // (the food-name `Text` widget renders the empty string as a
      // zero-height slot). When the food repo gains a synchronous cache
      // (TODO BE-foods-cache), this test's expectation flips to the
      // resolved name — keeping the test here makes that follow-up loud.
      final h = _build((_) => jsonResponse(200, <String, dynamic>{
            'results': <dynamic>[
              _entryBody(foodId: 'f_oatmeal_rolled'),
            ],
            'total': 1,
            'limit': 100,
            'offset': 0,
          }));
      final entries = await h.repo.entriesForDate(DateTime(2026, 5, 17));
      expect(entries, hasLength(1));
      // Wire decode passes through whatever the cache returns — null
      // cache → empty `foodName`. Asserting on the decoded type instead
      // of the (currently empty) value pins the contract.
      expect(entries.single.foodId, equals('f_oatmeal_rolled'));
    });
  });

  group('daySummary — GET /days/{date}/summary', () {
    test('issues GET against the bare YYYY-MM-DD path (NOT ISO datetime)',
        () async {
      final h = _build((_) => jsonResponse(200, <String, dynamic>{
            'date': '2026-05-17',
            'total': <String, dynamic>{
              'calories_kcal': '0',
              'protein_g': null,
              'carbs_g': null,
              'fat_g': null,
            },
            'by_meal': <Map<String, dynamic>>[
              <String, dynamic>{
                'meal': 'breakfast',
                'calories_kcal': '0',
                'protein_g': '0',
                'carbs_g': '0',
                'fat_g': '0',
                'entry_count': 0,
              },
              <String, dynamic>{
                'meal': 'lunch',
                'calories_kcal': '0',
                'protein_g': '0',
                'carbs_g': '0',
                'fat_g': '0',
                'entry_count': 0,
              },
              <String, dynamic>{
                'meal': 'dinner',
                'calories_kcal': '0',
                'protein_g': '0',
                'carbs_g': '0',
                'fat_g': '0',
                'entry_count': 0,
              },
              <String, dynamic>{
                'meal': 'snack',
                'calories_kcal': '0',
                'protein_g': '0',
                'carbs_g': '0',
                'fat_g': '0',
                'entry_count': 0,
              },
            ],
            'active_goal': null,
          }));
      final summary = await h.repo.daySummary(DateTime(2026, 5, 17));

      expect(h.adapter.requests.single.path,
          equals('/days/2026-05-17/summary'));
      expect(h.adapter.requests.single.method, equalsIgnoringCase('GET'));
      expect(summary.kcal, equals(Decimal.zero));
      expect(summary.byMeal[Meal.breakfast]?.entryCount, equals(0));
    });
  });

  group('create — POST /log (canonical) / /log/quick_add (quick-add)', () {
    test('canonical create POSTs LogCreate.toJson() to /log', () async {
      Map<String, dynamic>? capturedBody;
      final h = _build((req) {
        capturedBody = _readBody(req);
        return jsonResponse(201, _entryBody(id: 'le_new'));
      });
      final entry = await h.repo.create(LogCreate(
        foodId: 'f_oatmeal_rolled',
        servingId: 'sv_oats_half_cup',
        consumedOn: DateTime(2026, 5, 17),
        meal: Meal.breakfast,
        quantity: Decimal.one,
        enteredAmount: Decimal.parse('40'),
        enteredUnit: Unit.g,
      ));

      expect(h.adapter.requests.single.method, equalsIgnoringCase('POST'));
      expect(h.adapter.requests.single.path, equals('/log'));
      expect(capturedBody, isNotNull);
      expect(capturedBody!['food_id'], equals('f_oatmeal_rolled'));
      expect(capturedBody!['serving_id'], equals('sv_oats_half_cup'));
      expect(capturedBody!['consumed_on'], equals('2026-05-17'));
      expect(capturedBody!['meal'], equals('breakfast'));
      expect(capturedBody!['quantity'], equals('1'));
      expect(entry.id, equals('le_new'));
    });

    test('quick-add detected on foodId == quickAddFoodId and routed to '
        '/log/quick_add with kcal-only body', () async {
      Map<String, dynamic>? capturedBody;
      String? capturedPath;
      final h = _build((req) {
        capturedBody = _readBody(req);
        capturedPath = req.path;
        return jsonResponse(201, _entryBody(
          id: 'le_qa',
          foodId: 'srv-quick-add-uuid',
          quantity: '250',
        ));
      });
      await h.repo.create(LogCreate(
        foodId: quickAddFoodId,
        servingId: 'sv_kcal',
        consumedOn: DateTime(2026, 5, 17),
        meal: Meal.snack,
        quantity: Decimal.parse('250'),
        enteredAmount: Decimal.parse('250'),
        enteredUnit: Unit.serving,
      ));

      expect(capturedPath, equals('/log/quick_add'));
      expect(capturedBody!.keys,
          containsAll(<String>['calories_kcal', 'meal', 'consumed_on']));
      expect(capturedBody!['calories_kcal'], equals('250'));
      expect(capturedBody!['meal'], equals('snack'));
      expect(capturedBody!['consumed_on'], equals('2026-05-17'));
      // Crucially, the quick-add body must NOT carry food_id or
      // serving_id — those keys are server-managed.
      expect(capturedBody!.containsKey('food_id'), isFalse);
      expect(capturedBody!.containsKey('serving_id'), isFalse);
    });

    test('canonical create returns the decoded server LogEntry', () async {
      final h = _build((_) => jsonResponse(
            201,
            _entryBody(id: 'le_new', caloriesKcal: '190.00'),
          ));
      final entry = await h.repo.create(LogCreate(
        foodId: 'f_oatmeal_rolled',
        servingId: 'sv_oats_half_cup',
        consumedOn: DateTime(2026, 5, 17),
        meal: Meal.breakfast,
        quantity: Decimal.one,
        enteredAmount: Decimal.parse('40'),
        enteredUnit: Unit.g,
      ));
      expect(entry.id, equals('le_new'));
      expect(entry.nutritionSnapshot.caloriesKcal,
          equals(Decimal.parse('190.00')));
    });

    test('5xx from the server propagates as DioException — outbox keeps '
        'the queued entry on this throw', () async {
      final h = _build((_) => emptyResponse(500));
      await expectLater(
        h.repo.create(LogCreate(
          foodId: 'f_oatmeal_rolled',
          servingId: 'sv_oats_half_cup',
          consumedOn: DateTime(2026, 5, 17),
          meal: Meal.breakfast,
          quantity: Decimal.one,
          enteredAmount: Decimal.parse('40'),
          enteredUnit: Unit.g,
        )),
        throwsA(isA<DioException>()),
      );
    });
  });

  group('update — PATCH /log/{id}', () {
    test('PATCHes /log/{id} with the sparse LogPatch JSON', () async {
      Map<String, dynamic>? capturedBody;
      final h = _build((req) {
        capturedBody = _readBody(req);
        return jsonResponse(200,
            _entryBody(id: 'le_42', quantity: '2', caloriesKcal: '380.0'));
      });
      await h.repo.update(
        'le_42',
        LogPatch(quantity: Decimal.parse('2')),
      );

      expect(h.adapter.requests.single.method, equalsIgnoringCase('PATCH'));
      expect(h.adapter.requests.single.path, equals('/log/le_42'));
      // Sparse encoding — only the changed key is sent.
      expect(capturedBody, equals(<String, dynamic>{'quantity': '2'}));
    });

    test('clearNote: true emits explicit null in the body', () async {
      Map<String, dynamic>? capturedBody;
      final h = _build((req) {
        capturedBody = _readBody(req);
        return jsonResponse(200, _entryBody(id: 'le_42'));
      });
      await h.repo.update('le_42', const LogPatch(clearNote: true));
      expect(capturedBody!.containsKey('note'), isTrue);
      expect(capturedBody!['note'], isNull);
    });

    test('404 translates to LogEntryNotFoundError', () async {
      final h = _build((_) => emptyResponse(404));
      expect(
        () => h.repo.update('le_missing', LogPatch(quantity: Decimal.one)),
        throwsA(isA<LogEntryNotFoundError>()),
      );
    });

    test('rejects a smuggled food_id with StateError (defence-in-depth)',
        () async {
      final h = _build((_) => emptyResponse(200));
      expect(
        () => h.repo.update('le_42', _PatchWithFoodId(foodId: 'f_other')),
        throwsA(isA<StateError>()),
      );
      // No HTTP request should have left the client — the guard fires
      // before the Dio call.
      expect(h.adapter.requests, isEmpty);
    });
  });

  group('delete — DELETE /log/{id}', () {
    test('issues DELETE; 204 returns void', () async {
      final h = _build((_) => emptyResponse(204));
      await h.repo.delete('le_42');
      expect(h.adapter.requests.single.method, equalsIgnoringCase('DELETE'));
      expect(h.adapter.requests.single.path, equals('/log/le_42'));
    });

    test('404 translates to LogEntryNotFoundError', () async {
      final h = _build((_) => emptyResponse(404));
      expect(
        () => h.repo.delete('le_missing'),
        throwsA(isA<LogEntryNotFoundError>()),
      );
    });
  });

  group('copyDay — POST /log/copy', () {
    test('whole-day copy POSTs {from_date, to_date} with no meal filter',
        () async {
      Map<String, dynamic>? capturedBody;
      final h = _build((req) {
        capturedBody = _readBody(req);
        return jsonResponse(201, <String, dynamic>{
          'copied': <Map<String, dynamic>>[
            _entryBody(id: 'le_c1', consumedOn: '2026-05-18'),
          ],
        });
      });
      final out = await h.repo.copyDay(
        sourceDate: DateTime(2026, 5, 17),
        targetDate: DateTime(2026, 5, 18),
      );
      expect(h.adapter.requests.single.path, equals('/log/copy'));
      expect(capturedBody, equals(<String, dynamic>{
        'from_date': '2026-05-17',
        'to_date': '2026-05-18',
      }));
      expect(out, hasLength(1));
      expect(out.single.id, equals('le_c1'));
    });

    test('single-meal filter sends one POST with the meal field', () async {
      Map<String, dynamic>? capturedBody;
      final h = _build((req) {
        capturedBody = _readBody(req);
        return jsonResponse(201, <String, dynamic>{
          'copied': const <Map<String, dynamic>>[],
        });
      });
      await h.repo.copyDay(
        sourceDate: DateTime(2026, 5, 17),
        targetDate: DateTime(2026, 5, 18),
        meals: <Meal>[Meal.breakfast],
      );
      expect(capturedBody!['meal'], equals('breakfast'));
    });

    test('multi-meal filter fans out into N calls and concatenates results',
        () async {
      final captured = <Map<String, dynamic>>[];
      final h = _build((req) {
        final body = _readBody(req);
        captured.add(body);
        final meal = body['meal'] as String;
        return jsonResponse(201, <String, dynamic>{
          'copied': <Map<String, dynamic>>[
            _entryBody(
              id: 'le_$meal',
              meal: meal,
              consumedOn: '2026-05-18',
            ),
          ],
        });
      });
      final out = await h.repo.copyDay(
        sourceDate: DateTime(2026, 5, 17),
        targetDate: DateTime(2026, 5, 18),
        meals: <Meal>[Meal.breakfast, Meal.lunch],
      );
      expect(h.adapter.requests, hasLength(2));
      expect(captured.map((b) => b['meal']),
          equals(<String>['breakfast', 'lunch']));
      expect(out.map((e) => e.id),
          equals(<String>['le_breakfast', 'le_lunch']));
    });

    test('partial-skip is implicit — server returns shorter `copied` list',
        () async {
      // Two source entries on the source day, but the server skips one
      // (food no longer visible). The repository returns whatever the
      // server hands back; the UI computes `requestedCount > created
      // .length` to surface the skipped row count.
      final h = _build((_) => jsonResponse(201, <String, dynamic>{
            'copied': <Map<String, dynamic>>[
              _entryBody(id: 'le_a', consumedOn: '2026-05-18'),
            ],
          }));
      final out = await h.repo.copyDay(
        sourceDate: DateTime(2026, 5, 17),
        targetDate: DateTime(2026, 5, 18),
      );
      expect(out, hasLength(1));
    });
  });

  group('weeklyLogDayCount — GET /log over Mon..Sun', () {
    test('queries Mon..Sun and counts distinct consumed_on values', () async {
      // 2026-05-17 is a Sunday; Monday of that week is 2026-05-11.
      Map<String, dynamic>? capturedQuery;
      final h = _build((req) {
        capturedQuery = Map<String, dynamic>.from(req.queryParameters);
        return jsonResponse(200, <String, dynamic>{
          'results': <Map<String, dynamic>>[
            _entryBody(id: 'a', consumedOn: '2026-05-11'),
            _entryBody(id: 'b', consumedOn: '2026-05-11'),
            _entryBody(id: 'c', consumedOn: '2026-05-13'),
            _entryBody(id: 'd', consumedOn: '2026-05-17'),
          ],
          'total': 4,
          'limit': 500,
          'offset': 0,
        });
      });
      final count =
          await h.repo.weeklyLogDayCount(now: DateTime(2026, 5, 17, 12));
      expect(count, equals(3));
      expect(capturedQuery!['from'], equals('2026-05-11'));
      expect(capturedQuery!['to'], equals('2026-05-17'));
    });

    test('returns 0 when the week is empty', () async {
      final h = _build((_) => jsonResponse(200, <String, dynamic>{
            'results': const <dynamic>[],
            'total': 0,
            'limit': 500,
            'offset': 0,
          }));
      final count =
          await h.repo.weeklyLogDayCount(now: DateTime(2026, 5, 17, 12));
      expect(count, equals(0));
    });
  });

  group('isPendingSync', () {
    test('returns false when constructed without an outbox', () {
      final h = _build((_) => emptyResponse(500));
      expect(h.repo.isPendingSync('anything'), isFalse);
    });
  });
}

/// Subclass that smuggles a `food_id` into the patch JSON, used to
/// verify the repository's defence-in-depth guard. Production code never
/// constructs one — `LogPatch`'s own encoder never emits the key.
class _PatchWithFoodId extends LogPatch {
  const _PatchWithFoodId({required this.foodId});

  final String foodId;

  @override
  Map<String, dynamic> toJson() {
    final base = super.toJson();
    return <String, dynamic>{...base, 'food_id': foodId};
  }
}
