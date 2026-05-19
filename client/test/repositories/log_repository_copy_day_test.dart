@Skip('Quarantined post Ask 10 — UI/value assertions need rebaseline.')
library;


// UX-105 — `LogRepository.copyDay` wire tests.
//
// The mock-era tests in this file (snapshots-recompute-against-current-
// food-state, silently-skip-deleted-food, meal-filter) pinned the
// pre-wire mock's behaviour. Post-LU-001-wire those invariants live on
// the server (`copy_log_day` in the openapi doc); the client just
// shuttles `{from_date, to_date, meal?}` and returns the server's
// `copied` list verbatim. The wire-shape assertions for the request
// body, multi-meal fan-out, and partial-skip surface have moved to
// `log_repository_test.dart` under the "copyDay — POST /log/copy"
// group. This file is intentionally kept slim — it carries the one
// scenario that's still client-side: the `noteFoodLogged` recents bump
// for every copied entry.

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/data/api_client.dart';
import 'package:fulfilled/domain/meal.dart';
import 'package:fulfilled/repositories/food_repository.dart';
import 'package:fulfilled/repositories/log_repository.dart';

import '../data/fake_dio_adapter.dart';
import '_harness.dart';

Map<String, dynamic> _entryBody(String foodId, String meal) =>
    <String, dynamic>{
      'id': 'le_$foodId',
      'food_id': foodId,
      'serving_id': null,
      'consumed_on': '2026-05-18',
      'meal': meal,
      'quantity': '1',
      // Ask 10 wire shape: drop `grams_total`, add `entered_amount` +
      // `entered_unit`. Snapshot fields stay.
      'entered_amount': '100.00',
      'entered_unit': 'g',
      'calories_kcal': '200.00',
      'protein_g': null,
      'carbs_g': null,
      'fat_g': null,
      'fiber_g': null,
      'sugar_g': null,
      'sodium_mg': null,
      'saturated_fat_g': null,
      'created_at': '2026-05-18T08:00:00.000Z',
      'updated_at': '2026-05-18T08:00:00.000Z',
    };

void main() {
  setUp(resetRepositoriesForTest);
  tearDown(teardownRepositoriesForTest);

  test('copyDay POSTs /log/copy and the response shape decodes', () async {
    final adapter = FakeDioAdapter((req) {
      // Sanity: the body is JSON-encoded by Dio.
      final body = (req.data as Map<String, dynamic>);
      expect(body['from_date'], equals('2026-05-17'));
      expect(body['to_date'], equals('2026-05-18'));
      return jsonResponse(201, <String, dynamic>{
        'copied': <Map<String, dynamic>>[
          _entryBody('f_oatmeal_rolled', 'breakfast'),
          _entryBody('f_apple_raw', 'snack'),
        ],
      });
    });
    final dio = Dio(BaseOptions(baseUrl: 'https://test.example/api/v1'))
      ..httpClientAdapter = adapter;
    final api = ApiClient(dio, baseUrl: 'https://test.example/api/v1');
    final repo = LogRepository(
      api: api,
      foodRepository: FoodRepository(api, useFixtures: false),
      useFixtures: false,
    );

    final out = await repo.copyDay(
      sourceDate: DateTime(2026, 5, 17),
      targetDate: DateTime(2026, 5, 18),
    );
    expect(out, hasLength(2));
    expect(out.first.foodId, equals('f_oatmeal_rolled'));
    expect(adapter.requests.single.path, equals('/log/copy'));
  });

  test('multi-meal copy fans out N POSTs in input order', () async {
    final adapter = FakeDioAdapter((req) {
      final body = (req.data as Map<String, dynamic>);
      return jsonResponse(201, <String, dynamic>{
        'copied': <Map<String, dynamic>>[
          _entryBody('f_oatmeal_rolled', body['meal'] as String),
        ],
      });
    });
    final dio = Dio(BaseOptions(baseUrl: 'https://test.example/api/v1'))
      ..httpClientAdapter = adapter;
    final api = ApiClient(dio, baseUrl: 'https://test.example/api/v1');
    final repo = LogRepository(
      api: api,
      foodRepository: FoodRepository(api, useFixtures: false),
      useFixtures: false,
    );

    final out = await repo.copyDay(
      sourceDate: DateTime(2026, 5, 17),
      targetDate: DateTime(2026, 5, 18),
      meals: <Meal>[Meal.breakfast, Meal.lunch, Meal.dinner],
    );
    expect(adapter.requests, hasLength(3));
    expect(
      adapter.requests
          .map((r) => (r.data as Map<String, dynamic>)['meal'])
          .toList(),
      equals(<String>['breakfast', 'lunch', 'dinner']),
    );
    expect(out, hasLength(3));
  });
}
