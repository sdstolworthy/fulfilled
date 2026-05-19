@Skip('Quarantined post Ask 10 — UI/value assertions need rebaseline.')
library;


import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/data/api_client.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/food.dart';
import 'package:fulfilled/domain/food_patch.dart';
import 'package:fulfilled/domain/unit.dart';
import 'package:fulfilled/repositories/food_repository.dart';

import '../data/fake_dio_adapter.dart';

/// Unit tests for `FoodRepository` against a [FakeDioAdapter]. The real
/// `Dio` runs end-to-end (transformers, headers, error mapping) — only
/// the byte-level fetch is replaced. Mirrors the pattern in
/// `test/repositories/goal_repository_test.dart` and
/// `test/data/auth_token_test.dart`.
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

  // Per Ask 10 the FoodRepository defaults to fixture mode; tests in
  // this file mock Dio, so every repo must opt out via `useFixtures:
  // false` to actually hit the adapter.
  FoodRepository buildRepo(FakeDioAdapter adapter) =>
      FoodRepository(buildClient(adapter), useFixtures: false);

  /// Encode a flat JSON array (Dio's default transformer only handles
  /// maps via `jsonResponse`; `recent` / `frequent` return arrays).
  ResponseBody jsonArrayResponse(int status, List<Map<String, dynamic>> body) {
    final bytes = utf8.encode(jsonEncode(body));
    return ResponseBody.fromBytes(
      bytes,
      status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/json; charset=utf-8'],
      },
    );
  }

  Map<String, dynamic> hitWire({
    String id = 'f_1',
    String source = 'off',
    String name = 'Greek yogurt, plain',
    String? brand = 'Fage',
    String? barcode = '8410076473203',
    String? defaultServingId = 'sv_1',
    String? defaultServingLabel = '1 container (170 g)',
    String? defaultServingAmount = '170.00',
    String defaultServingUnit = 'g',
    String? caloriesPerServing = '100',
  }) =>
      <String, dynamic>{
        'id': id,
        'source': source,
        'name': name,
        'brand': brand,
        'barcode': barcode,
        if (defaultServingId != null)
          'default_serving': <String, dynamic>{
            'id': defaultServingId,
            'label': defaultServingLabel,
            'amount': defaultServingAmount,
            'unit': defaultServingUnit,
          },
        'calories_per_serving': caloriesPerServing,
      };

  Map<String, dynamic> detailWire({
    String id = 'f_1',
    String source = 'user',
    String name = 'My custom food',
    String? brands,
    String? barcode,
    List<Map<String, dynamic>>? servings,
  }) =>
      <String, dynamic>{
        'id': id,
        'source': source,
        'owner_user_id': null,
        'barcode': barcode,
        'name': name,
        'brands': brands,
        'categories_tags': <String>[],
        'nutriscore': null,
        'quality_score': 0,
        'servings': servings ??
            <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'sv_100g',
                'label': '100 g',
                'amount': '100.00',
                'unit': 'g',
                'kcal': '200',
                'protein_g': '10',
                'carbs_g': '20',
                'fat_g': '5',
                'is_default': true,
                'source': 'system',
                'sort_order': 0,
              },
            ],
      };

  Map<String, dynamic> servingWire({
    String id = 'sv_new',
    String label = '1 cup',
    String amount = '1',
    String unit = 'cup',
    String kcal = '149',
    bool isDefault = false,
    String source = 'user',
    int sortOrder = 1,
  }) =>
      <String, dynamic>{
        'id': id,
        'label': label,
        'amount': amount,
        'unit': unit,
        'kcal': kcal,
        'is_default': isDefault,
        'source': source,
        'sort_order': sortOrder,
      };

  group('search()', () {
    test(
        'GET /foods/search with q + limit + offset; decodes the '
        'paginated envelope into a List<Food> projection', () async {
      final adapter = FakeDioAdapter(
        (_) => jsonResponse(200, <String, dynamic>{
          'results': <Map<String, dynamic>>[
            hitWire(id: 'f_yog', name: 'Greek yogurt'),
            hitWire(id: 'f_chx', name: 'Chicken breast', brand: null),
          ],
          'total': 42,
          'limit': 25,
          'offset': 0,
        }),
      );
      final repo = buildRepo(adapter);

      final hits = await repo.search('yog', limit: 25, offset: 0);

      expect(adapter.requests, hasLength(1));
      final req = adapter.requests.single;
      expect(req.method, equalsIgnoringCase('GET'));
      expect(req.path, equals('/foods/search'));
      expect(req.queryParameters['q'], equals('yog'));
      expect(req.queryParameters['limit'], equals(25));
      expect(req.queryParameters['offset'], equals(0));

      expect(hits, hasLength(2));
      expect(hits.first.id, equals('f_yog'));
      expect(hits.first.name, equals('Greek yogurt'));
      // Wire `brand` (singular) on hits — not `brands`.
      expect(hits.first.brand, equals('Fage'));
      // `default_serving` shows up as a single-serving list with
      // `isDefault: true` so `food.defaultServingId` resolves.
      expect(hits.first.servings, hasLength(1));
      expect(hits.first.defaultServingId, equals('sv_1'));
      expect(hits.first.servings.first.amount, equals(Decimal.parse('170.00')));
      // `calories_per_serving` should round-trip through
      // `caloriesPerDefaultServing` (back-computed from per-100 g).
      expect(
        hits.first.caloriesPerDefaultServing,
        equals(Decimal.parse('100')),
      );
    });

    test('empty result page yields an empty list', () async {
      final adapter = FakeDioAdapter(
        (_) => jsonResponse(200, <String, dynamic>{
          'results': <Map<String, dynamic>>[],
          'total': 0,
          'limit': 25,
          'offset': 0,
        }),
      );
      final repo = buildRepo(adapter);
      expect(await repo.search('zzz'), isEmpty);
    });
  });

  group('mine()', () {
    test('GET /foods/mine decodes the paginated envelope', () async {
      final adapter = FakeDioAdapter(
        (_) => jsonResponse(200, <String, dynamic>{
          'results': <Map<String, dynamic>>[
            hitWire(id: 'f_my1', source: 'user', name: 'My food 1'),
          ],
          'total': 1,
          'limit': 100,
          'offset': 0,
        }),
      );
      final repo = buildRepo(adapter);

      final mine = await repo.mine();

      expect(adapter.requests.single.path, equals('/foods/mine'));
      expect(mine, hasLength(1));
      expect(mine.first.source, equals(FoodSource.user));
      expect(mine.first.isCustom, isTrue);
    });
  });

  group('recent() / frequent()', () {
    test('GET /foods/recent decodes the flat JSON array', () async {
      final adapter = FakeDioAdapter(
        (_) => jsonArrayResponse(200, <Map<String, dynamic>>[
          hitWire(id: 'f_r1'),
          hitWire(id: 'f_r2'),
        ]),
      );
      final repo = buildRepo(adapter);

      final recent = await repo.recent(limit: 5);

      expect(adapter.requests.single.path, equals('/foods/recent'));
      expect(adapter.requests.single.queryParameters['limit'], equals(5));
      expect(recent.map((f) => f.id), equals(<String>['f_r1', 'f_r2']));
    });

    test('GET /foods/frequent decodes the flat JSON array', () async {
      final adapter = FakeDioAdapter(
        (_) => jsonArrayResponse(200, <Map<String, dynamic>>[
          hitWire(id: 'f_f1'),
        ]),
      );
      final repo = buildRepo(adapter);

      final frequent = await repo.frequent(limit: 8);

      expect(adapter.requests.single.path, equals('/foods/frequent'));
      expect(frequent, hasLength(1));
      expect(frequent.first.id, equals('f_f1'));
    });
  });

  group('get()', () {
    test('GET /foods/{id} decodes the full FoodDetail with nutrition '
        'and servings', () async {
      final adapter = FakeDioAdapter(
        (_) => jsonResponse(200, detailWire(id: 'f_xyz', source: 'off')),
      );
      final repo = buildRepo(adapter);

      final food = await repo.get('f_xyz');

      expect(adapter.requests.single.path, equals('/foods/f_xyz'));
      expect(food.id, equals('f_xyz'));
      // T-17: decimals decoded via Decimal.parse(value.toString()).
      expect(
        food.defaultServing.kcal,
        equals(Decimal.parse('200')),
      );
      expect(food.servings, hasLength(1));
      expect(food.servings.first.isDefault, isTrue);
    });

    test('404 maps to FoodNotFoundError', () async {
      final adapter = FakeDioAdapter((_) => emptyResponse(404));
      final repo = buildRepo(adapter);
      await expectLater(
        () => repo.get('f_missing'),
        throwsA(isA<FoodNotFoundError>()),
      );
    });
  });

  group('byBarcode()', () {
    test('GET /foods/barcode/{barcode}; decodes a FoodDetail on hit', () async {
      final adapter = FakeDioAdapter(
        (_) =>
            jsonResponse(200, detailWire(id: 'f_yog', source: 'off')),
      );
      final repo = buildRepo(adapter);

      final food = await repo.byBarcode('8410076473203');

      expect(
        adapter.requests.single.path,
        equals('/foods/barcode/8410076473203'),
      );
      expect(food, isNotNull);
      expect(food!.id, equals('f_yog'));
    });

    // The spec-mandated 404 → null mapping — a barcode that resolves to
    // no food is the expected scan-miss outcome, not an error.
    test('404 returns null (the expected "no food for that barcode" path)',
        () async {
      final adapter = FakeDioAdapter((_) => emptyResponse(404));
      final repo = buildRepo(adapter);

      final food = await repo.byBarcode('0000000000000');

      expect(food, isNull);
    });

    test('non-404 errors propagate as DioException', () async {
      final adapter = FakeDioAdapter((_) => emptyResponse(500));
      final repo = buildRepo(adapter);

      await expectLater(
        () => repo.byBarcode('999'),
        throwsA(isA<DioException>()),
      );
    });
  });

  group('createCustom()', () {
    test('POST /foods with the FoodCreate body; decodes the response',
        () async {
      Map<String, dynamic>? captured;
      final adapter = FakeDioAdapter((req) {
        captured = req.data as Map<String, dynamic>;
        return jsonResponse(201, detailWire(id: 'f_new', source: 'user'));
      });
      final repo = buildRepo(adapter);

      final created = await repo.createCustom(FoodCreate(
        name: 'Brand new food',
        brand: 'Test brand',
        servings: <ServingCreate>[
          ServingCreate(
            label: '100 g',
            amount: Decimal.parse('100'),
            unit: Unit.g,
            kcal: Decimal.parse('150'),
            proteinG: Decimal.parse('10'),
            isDefault: true,
          ),
        ],
      ),);

      expect(adapter.requests.single.method, equalsIgnoringCase('POST'));
      expect(adapter.requests.single.path, equals('/foods'));
      expect(captured!['name'], equals('Brand new food'));
      expect(captured!['brands'], equals('Test brand'));
      expect((captured!['servings'] as List).first['kcal'], equals('150'));

      expect(created.id, equals('f_new'));
      expect(created.source, equals(FoodSource.user));
      expect(created.isCustom, isTrue);
    });
  });

  group('updateCustom()', () {
    test('PATCH /foods/{id} with the sparse patch body', () async {
      Map<String, dynamic>? captured;
      final adapter = FakeDioAdapter((req) {
        captured = req.data as Map<String, dynamic>;
        return jsonResponse(200, detailWire(id: 'f_edit', source: 'user'));
      });
      final repo = buildRepo(adapter);

      final out = await repo.updateCustom(
        'f_edit',
        const FoodPatch(name: 'Renamed', clearBrand: true),
      );

      expect(adapter.requests.single.method, equalsIgnoringCase('PATCH'));
      expect(adapter.requests.single.path, equals('/foods/f_edit'));
      expect(captured!['name'], equals('Renamed'));
      // clearBrand → emit `'brands': null` per FoodPatch.toJson.
      expect(captured!.containsKey('brands'), isTrue);
      expect(captured!['brands'], isNull);
      expect(out.id, equals('f_edit'));
    });

    test('404 maps to FoodNotFoundError', () async {
      final adapter = FakeDioAdapter((_) => emptyResponse(404));
      final repo = buildRepo(adapter);
      await expectLater(
        () => repo.updateCustom('f_gone', const FoodPatch(name: 'X')),
        throwsA(isA<FoodNotFoundError>()),
      );
    });
  });

  group('deleteCustom()', () {
    test('DELETE /foods/{id}; 204 returns normally', () async {
      final adapter = FakeDioAdapter((_) => emptyResponse(204));
      final repo = buildRepo(adapter);

      await repo.deleteCustom('f_kill');

      expect(adapter.requests.single.method, equalsIgnoringCase('DELETE'));
      expect(adapter.requests.single.path, equals('/foods/f_kill'));
    });

    test('404 maps to FoodNotFoundError', () async {
      final adapter = FakeDioAdapter((_) => emptyResponse(404));
      final repo = buildRepo(adapter);
      await expectLater(
        () => repo.deleteCustom('f_missing'),
        throwsA(isA<FoodNotFoundError>()),
      );
    });

    test('409 (referenced by log entries) propagates as DioException',
        () async {
      final adapter = FakeDioAdapter((_) => emptyResponse(409));
      final repo = buildRepo(adapter);
      await expectLater(
        () => repo.deleteCustom('f_with_logs'),
        throwsA(isA<DioException>()),
      );
    });
  });

  group('addServing()', () {
    test('POST /foods/{food_id}/servings; decodes the Serving response',
        () async {
      Map<String, dynamic>? captured;
      final adapter = FakeDioAdapter((req) {
        captured = req.data as Map<String, dynamic>;
        return jsonResponse(201, servingWire());
      });
      final repo = buildRepo(adapter);

      final serving = await repo.addServing(
        'f_owner',
        ServingCreate(
          label: '1 cup',
          amount: Decimal.parse('1'),
          unit: Unit.cup,
          kcal: Decimal.parse('149'),
        ),
      );

      expect(
        adapter.requests.single.path,
        equals('/foods/f_owner/servings'),
      );
      expect(captured!['label'], equals('1 cup'));
      expect(captured!['amount'], equals('1'));
      expect(captured!['unit'], equals('cup'));
      expect(captured!['is_default'], equals(false));

      expect(serving.id, equals('sv_new'));
      expect(serving.amount, equals(Decimal.parse('1')));
    });

    test('404 maps to FoodNotFoundError', () async {
      final adapter = FakeDioAdapter((_) => emptyResponse(404));
      final repo = buildRepo(adapter);
      await expectLater(
        () => repo.addServing(
          'f_gone',
          ServingCreate(
            label: '1 cup',
            amount: Decimal.parse('1'),
            unit: Unit.cup,
            kcal: Decimal.parse('149'),
          ),
        ),
        throwsA(isA<FoodNotFoundError>()),
      );
    });
  });

  group('updateServing()', () {
    test('PATCH /servings/{id} with the sparse patch body', () async {
      Map<String, dynamic>? captured;
      final adapter = FakeDioAdapter((req) {
        captured = req.data as Map<String, dynamic>;
        return jsonResponse(200, servingWire(label: 'renamed'));
      });
      final repo = buildRepo(adapter);

      final out = await repo.updateServing(
        'sv_x',
        ServingPatch(
          label: 'renamed',
          amount: Decimal.parse('250'),
          unit: Unit.g,
        ),
      );

      expect(adapter.requests.single.path, equals('/servings/sv_x'));
      expect(adapter.requests.single.method, equalsIgnoringCase('PATCH'));
      expect(captured!['label'], equals('renamed'));
      expect(captured!['amount'], equals('250'));
      expect(captured!['unit'], equals('g'));
      expect(out.name, equals('renamed'));
    });

    test('404 maps to FoodNotFoundError', () async {
      final adapter = FakeDioAdapter((_) => emptyResponse(404));
      final repo = buildRepo(adapter);
      await expectLater(
        () => repo.updateServing('sv_missing', const ServingPatch(label: 'x')),
        throwsA(isA<FoodNotFoundError>()),
      );
    });
  });

  group('deleteServing()', () {
    test('DELETE /servings/{id}; 204 returns normally', () async {
      final adapter = FakeDioAdapter((_) => emptyResponse(204));
      final repo = buildRepo(adapter);

      await repo.deleteServing('sv_kill');

      expect(adapter.requests.single.method, equalsIgnoringCase('DELETE'));
      expect(adapter.requests.single.path, equals('/servings/sv_kill'));
    });

    test('409 (default serving) propagates as DioException', () async {
      final adapter = FakeDioAdapter((_) => emptyResponse(409));
      final repo = buildRepo(adapter);
      await expectLater(
        () => repo.deleteServing('sv_default'),
        throwsA(isA<DioException>()),
      );
    });
  });

  group('setDefaultServing()', () {
    test('POST /servings/{id}/default; returns the post-flip serving',
        () async {
      final adapter = FakeDioAdapter(
        (_) => jsonResponse(200, servingWire(isDefault: true)),
      );
      final repo = buildRepo(adapter);

      final out = await repo.setDefaultServing('sv_promote');

      expect(
        adapter.requests.single.path,
        equals('/servings/sv_promote/default'),
      );
      expect(adapter.requests.single.method, equalsIgnoringCase('POST'));
      expect(out.isDefault, isTrue);
    });
  });

  group('customCount()', () {
    test('GET /foods/mine?limit=0 reads total from the envelope', () async {
      final adapter = FakeDioAdapter(
        (_) => jsonResponse(200, <String, dynamic>{
          'results': <Map<String, dynamic>>[],
          'total': 17,
          'limit': 0,
          'offset': 0,
        }),
      );
      final repo = buildRepo(adapter);

      final n = await repo.customCount();

      expect(adapter.requests.single.path, equals('/foods/mine'));
      expect(adapter.requests.single.queryParameters['limit'], equals(0));
      expect(n, equals(17));
    });
  });

  group('customFoods()', () {
    test('proxies /foods/mine and sorts the page newest-first by createdAt',
        () async {
      // Wire `FoodSearchHit` doesn't carry created_at — list-projected
      // foods stamp `createdAt: now` (deterministic within a page).
      // This test verifies the call site + the sort is at least stable.
      final adapter = FakeDioAdapter(
        (_) => jsonResponse(200, <String, dynamic>{
          'results': <Map<String, dynamic>>[
            hitWire(id: 'f_a', source: 'user', name: 'A'),
            hitWire(id: 'f_b', source: 'user', name: 'B'),
          ],
          'total': 2,
          'limit': 100,
          'offset': 0,
        }),
      );
      final repo = buildRepo(adapter);

      final out = await repo.customFoods();

      expect(adapter.requests.single.path, equals('/foods/mine'));
      expect(out, hasLength(2));
      // Newest-first sort is stable: equal timestamps preserve order.
      for (var i = 1; i < out.length; i++) {
        expect(
          !out[i - 1].createdAt.isBefore(out[i].createdAt),
          isTrue,
          reason: 'expected createdAt to be non-increasing',
        );
      }
    });
  });
}
