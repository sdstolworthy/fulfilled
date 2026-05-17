import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/data/api_client.dart';
import 'package:fulfilled/domain/goal.dart';
import 'package:fulfilled/repositories/goal_repository.dart';

import '../data/fake_dio_adapter.dart';

/// Unit tests for `GoalRepository` against a [FakeDioAdapter]. The
/// real `Dio` runs end-to-end (transformers, headers, error mapping)
/// — only the byte-level fetch is replaced. This mirrors the pattern
/// in `test/data/auth_token_test.dart`.
void main() {
  ApiClient buildClient(FakeDioAdapter adapter) {
    final dio = Dio(
      BaseOptions(
        baseUrl: 'https://test.example/api/v1',
        headers: <String, String>{
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        },
      ),
    );
    dio.httpClientAdapter = adapter;
    return ApiClient(dio, baseUrl: 'https://test.example/api/v1');
  }

  Map<String, dynamic> goalWire({
    String id = 'g_1',
    String startsOn = '2026-05-01',
    String? endsOn,
    String? startWeightKg = '80.50',
    String? targetWeightKg = '75.00',
    String? weeklyRateKg = '-0.50',
    int? dailyCalorieTarget = 2000,
    String? proteinG = '150.00',
    String? carbsG = '200.00',
    String? fatG = '60.00',
    String createdAt = '2026-05-01T08:00:00Z',
    String updatedAt = '2026-05-01T08:00:00Z',
  }) =>
      <String, dynamic>{
        'id': id,
        'starts_on': startsOn,
        'ends_on': endsOn,
        'start_weight_kg': startWeightKg,
        'target_weight_kg': targetWeightKg,
        'weekly_rate_kg': weeklyRateKg,
        'daily_calorie_target': dailyCalorieTarget,
        'protein_g_target': proteinG,
        'carbs_g_target': carbsG,
        'fat_g_target': fatG,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  group('active()', () {
    test('GET /goals/active?on=YYYY-MM-DD; stamps isActive=true and '
        'decodes decimals via Decimal.parse(value.toString())', () async {
      final adapter = FakeDioAdapter(
        (_) => jsonResponse(200, goalWire(id: 'g_active', endsOn: null)),
      );
      final api = buildClient(adapter);
      final repo = GoalRepository(api);

      final goal = await repo.active(on: DateTime(2026, 5, 16));

      expect(adapter.requests, hasLength(1));
      final req = adapter.requests.single;
      expect(req.method, equalsIgnoringCase('GET'));
      expect(req.path, equals('/goals/active'));
      expect(req.queryParameters['on'], equals('2026-05-16'));

      expect(goal.id, equals('g_active'));
      expect(goal.isActive, isTrue);
      expect(goal.startWeightKg, equals(Decimal.parse('80.50')));
      expect(goal.weeklyRateKg, equals(Decimal.parse('-0.50')));
      expect(goal.dailyCalorieTarget, equals(2000));
      expect(goal.proteinTargetG, equals(Decimal.parse('150.00')));
    });

    test('404 maps to GoalNotFoundError (the no-active-goal path that '
        '`LogRepository` swallows to null)', () async {
      final adapter = FakeDioAdapter((_) => emptyResponse(404));
      final repo = GoalRepository(buildClient(adapter));

      await expectLater(
        () => repo.active(on: DateTime(2026, 5, 16)),
        throwsA(isA<GoalNotFoundError>()),
      );
    });

    test('non-404 errors propagate as DioException', () async {
      final adapter = FakeDioAdapter((_) => emptyResponse(500));
      final repo = GoalRepository(buildClient(adapter));

      await expectLater(
        () => repo.active(on: DateTime(2026, 5, 16)),
        throwsA(isA<DioException>()),
      );
    });
  });

  group('all()', () {
    test('GET /goals returns flat array; sorted newest-first with '
        'isActive stamped onto whichever row covers today', () async {
      final today = DateTime.now();
      String fmt(DateTime d) =>
          '${d.year.toString().padLeft(4, "0")}-'
          '${d.month.toString().padLeft(2, "0")}-'
          '${d.day.toString().padLeft(2, "0")}';
      final older = goalWire(
        id: 'g_old',
        startsOn: '2025-01-01',
        endsOn: '2025-12-31',
      );
      final current = goalWire(
        id: 'g_now',
        startsOn: fmt(today.subtract(const Duration(days: 10))),
        endsOn: null,
      );
      // The live wire returns a flat JSON array (not the openapi
      // paginated envelope), so encode bytes directly — `jsonResponse`
      // only handles maps.
      final adapter = FakeDioAdapter((_) {
        final bytes = utf8.encode(
          jsonEncode(<Map<String, dynamic>>[older, current]),
        );
        return ResponseBody.fromBytes(
          bytes,
          200,
          headers: <String, List<String>>{
            Headers.contentTypeHeader: <String>[
              'application/json; charset=utf-8',
            ],
          },
        );
      });
      final repo = GoalRepository(buildClient(adapter));

      final goals = await repo.all();

      expect(adapter.requests.single.path, equals('/goals'));
      expect(goals, hasLength(2));
      // Newest started first.
      expect(goals.first.id, equals('g_now'));
      expect(goals.last.id, equals('g_old'));
      // Today-covering row carries isActive=true.
      expect(goals.first.isActive, isTrue);
      expect(goals.last.isActive, isFalse);
    });
  });

  group('create()', () {
    test('POST /goals with JSON body; returns decoded goal with '
        'isActive=true when ends_on is null', () async {
      Map<String, dynamic>? captured;
      final adapter = FakeDioAdapter((req) {
        captured = req.data as Map<String, dynamic>;
        return jsonResponse(201, goalWire(id: 'g_new', endsOn: null));
      });
      final repo = GoalRepository(buildClient(adapter));

      final goal = await repo.create(GoalCreate(
        startsOn: DateTime(2026, 5, 17),
        startWeightKg: Decimal.parse('80.5'),
        targetWeightKg: Decimal.parse('75.0'),
        weeklyRateKg: Decimal.parse('-0.5'),
        dailyCalorieTarget: 2000,
        proteinTargetG: Decimal.parse('150'),
        carbsTargetG: Decimal.parse('200'),
        fatTargetG: Decimal.parse('60'),
      ));

      expect(adapter.requests.single.method, equalsIgnoringCase('POST'));
      expect(adapter.requests.single.path, equals('/goals'));
      expect(captured, isNotNull);
      expect(captured!['starts_on'], equals('2026-05-17'));
      expect(captured!['start_weight_kg'], equals('80.5'));
      expect(captured!['weekly_rate_kg'], equals('-0.5'));
      expect(captured!['daily_calorie_target'], equals(2000));

      expect(goal.id, equals('g_new'));
      expect(goal.isActive, isTrue);
    });
  });

  group('update()', () {
    test('PATCH /goals/{id} with the editable fields; preserves '
        'caller isActive on the result', () async {
      Map<String, dynamic>? captured;
      final adapter = FakeDioAdapter((req) {
        captured = req.data as Map<String, dynamic>;
        return jsonResponse(200, goalWire(id: 'g_edit'));
      });
      final repo = GoalRepository(buildClient(adapter));

      final input = Goal(
        id: 'g_edit',
        startedOn: DateTime(2026, 5, 1),
        endedOn: null,
        startWeightKg: Decimal.parse('80'),
        targetWeightKg: Decimal.parse('74.5'),
        weeklyRateKg: Decimal.parse('-0.5'),
        dailyCalorieTarget: 1950,
        proteinTargetG: Decimal.parse('155'),
        carbsTargetG: Decimal.parse('190'),
        fatTargetG: Decimal.parse('60'),
        isActive: true,
        createdAt: DateTime(2026, 5, 1),
        updatedAt: DateTime(2026, 5, 1),
      );

      final out = await repo.update(input);

      expect(adapter.requests.single.method, equalsIgnoringCase('PATCH'));
      expect(adapter.requests.single.path, equals('/goals/g_edit'));
      expect(captured!['starts_on'], equals('2026-05-01'));
      expect(captured!['target_weight_kg'], equals('74.5'));
      expect(captured!['daily_calorie_target'], equals(1950));
      // ends_on omitted because input.endedOn is null.
      expect(captured!.containsKey('ends_on'), isFalse);

      expect(out.id, equals('g_edit'));
      // Preserved from the caller, since the wire doesn't carry it.
      expect(out.isActive, isTrue);
    });

    test('404 maps to GoalNotFoundError', () async {
      final adapter = FakeDioAdapter((_) => emptyResponse(404));
      final repo = GoalRepository(buildClient(adapter));

      final input = Goal(
        id: 'g_missing',
        startedOn: DateTime(2026, 5, 1),
        isActive: false,
        createdAt: DateTime(2026, 5, 1),
        updatedAt: DateTime(2026, 5, 1),
      );

      await expectLater(
        () => repo.update(input),
        throwsA(isA<GoalNotFoundError>()),
      );
    });
  });

  group('delete()', () {
    test('DELETE /goals/{id}; 204 returns normally', () async {
      final adapter = FakeDioAdapter((_) => emptyResponse(204));
      final repo = GoalRepository(buildClient(adapter));

      await repo.delete('g_1');

      expect(adapter.requests.single.method, equalsIgnoringCase('DELETE'));
      expect(adapter.requests.single.path, equals('/goals/g_1'));
    });

    test('404 maps to GoalNotFoundError', () async {
      final adapter = FakeDioAdapter((_) => emptyResponse(404));
      final repo = GoalRepository(buildClient(adapter));

      await expectLater(
        () => repo.delete('g_missing'),
        throwsA(isA<GoalNotFoundError>()),
      );
    });
  });
}
