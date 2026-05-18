// Tests for `ProfileRepository` against a `FakeDioAdapter` — verifies
// wire-shape decoding for `GET /me` and `PATCH /me`, the derive chain
// for `currentWeightKg`/`customFoodCount`, and the tolerant decode for
// the not-yet-deployed `weight_unit`/`height_unit` keys.

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/data/api_client.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/user.dart';
import 'package:fulfilled/repositories/profile_repository.dart';

import '../data/fake_dio_adapter.dart';
import '_harness.dart';

Map<String, dynamic> _meBody({
  String? weightUnit,
  String? heightUnit,
  String? heightCm,
}) =>
    <String, dynamic>{
      'id': 'u_test',
      'display_name': 'Sam Reyes',
      'email': 'sam@example.com',
      'created_at': '2026-01-01T00:00:00.000Z',
      'updated_at': '2026-01-02T00:00:00.000Z',
      if (weightUnit != null) 'weight_unit': weightUnit,
      if (heightUnit != null) 'height_unit': heightUnit,
      if (heightCm != null) 'height_cm': heightCm,
    };

Map<String, dynamic> _emptyWeightsPage() => <String, dynamic>{
      'results': const <dynamic>[],
      'total': 0,
      'limit': 100,
      'offset': 0,
    };

({ProfileRepository repo, FakeDioAdapter adapter}) _build(
  ResponseBody Function(RequestOptions) handler,
) {
  final adapter = FakeDioAdapter(handler);
  final dio = Dio(BaseOptions(baseUrl: 'https://test.example/api/v1'))
    ..httpClientAdapter = adapter;
  final api = ApiClient(dio, baseUrl: 'https://test.example/api/v1');
  final repo = ProfileRepository(api: api);
  return (repo: repo, adapter: adapter);
}

void main() {
  setUp(resetRepositoriesForTest);
  tearDown(teardownRepositoriesForTest);

  test('me() GETs /me and decodes the User envelope', () async {
    final h = _build((req) {
      if (req.path == '/me') return jsonResponse(200, _meBody());
      if (req.path == '/weights') return jsonResponse(200, _emptyWeightsPage());
      return emptyResponse(404);
    });
    final user = await h.repo.me();

    expect(user.displayName, equals('Sam Reyes'));
    expect(user.email, equals('sam@example.com'));
    expect(h.adapter.requests.first.method, equalsIgnoringCase('GET'));
    expect(h.adapter.requests.first.path, equals('/me'));
  });

  test('me() tolerates missing weight_unit and defaults to WeightUnit.kg',
      () async {
    // The deployed dev API does NOT yet emit weight_unit (PR #2 in
    // draft). `User.fromJson` must fall back to kg.
    // TODO BE-001/BE-004 merge: this test stays — it's verifying the
    // backwards-compatible tolerant decode.
    final h = _build((req) {
      if (req.path == '/me') return jsonResponse(200, _meBody());
      if (req.path == '/weights') return jsonResponse(200, _emptyWeightsPage());
      return emptyResponse(404);
    });
    final user = await h.repo.me();
    expect(user.weightUnit, equals(WeightUnit.kg));
    expect(user.heightUnit, equals(HeightUnit.cm));
  });

  test('me() honours weight_unit when present', () async {
    final h = _build((req) {
      if (req.path == '/me') {
        return jsonResponse(
            200, _meBody(weightUnit: 'lb', heightUnit: 'ft_in'));
      }
      if (req.path == '/weights') return jsonResponse(200, _emptyWeightsPage());
      return emptyResponse(404);
    });
    final user = await h.repo.me();
    expect(user.weightUnit, equals(WeightUnit.lb));
    expect(user.heightUnit, equals(HeightUnit.ftIn));
  });

  // `me() derives currentWeightKg from the latest weight entry` —
  // superseded by the derived-provider refactor. `currentWeightKg` now
  // lives on `currentWeightKgProvider`, not on the `User` envelope; the
  // /weights round-trip is exercised in `currentWeightKgProvider`'s
  // own provider test instead.

  test('update(UserPatch) PATCHes /me and returns the decoded User',
      () async {
    final h = _build((req) {
      if (req.method.toUpperCase() == 'PATCH' && req.path == '/me') {
        // Echo the body's weight_unit back so the test can assert on
        // the round-trip.
        final body = req.data as Map<String, dynamic>;
        return jsonResponse(
            200, _meBody(weightUnit: body['weight_unit'] as String?));
      }
      if (req.path == '/weights') return jsonResponse(200, _emptyWeightsPage());
      return emptyResponse(404);
    });
    final returned =
        await h.repo.update(const UserPatch(weightUnit: WeightUnit.lb));
    expect(returned.weightUnit, equals(WeightUnit.lb));

    final patch = h.adapter.requests
        .firstWhere((r) => r.method.toUpperCase() == 'PATCH');
    expect(patch.path, equals('/me'));
    expect((patch.data as Map)['weight_unit'], equals('lb'));
  });

  test('update only emits the keys present on the patch', () async {
    final h = _build((req) {
      if (req.method.toUpperCase() == 'PATCH' && req.path == '/me') {
        return jsonResponse(200, _meBody());
      }
      if (req.path == '/weights') return jsonResponse(200, _emptyWeightsPage());
      return emptyResponse(404);
    });
    await h.repo.update(const UserPatch(displayName: 'Renamed'));
    final patch = h.adapter.requests
        .firstWhere((r) => r.method.toUpperCase() == 'PATCH');
    final body = patch.data as Map;
    expect(body.containsKey('weight_unit'), isFalse);
    expect(body.containsKey('height_unit'), isFalse);
    expect(body['display_name'], equals('Renamed'));
  });
}
