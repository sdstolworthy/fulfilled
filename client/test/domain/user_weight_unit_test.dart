// Tests for the `User.weightUnit` + `UserPatch.weightUnit` plumbing
// introduced in LU-004.
//
// The wire string is the lowercase enum name (`'kg' | 'lb' | 'st'`).
// `User.fromJson` is tolerant of a missing `weight_unit` key during the
// pre-backend window — see architect §3.1, §3.3, §4.2.

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/data/api_client.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/user.dart';
import 'package:fulfilled/repositories/food_repository.dart';
import 'package:fulfilled/repositories/profile_repository.dart';
import 'package:fulfilled/repositories/weight_repository.dart';

import '../data/fake_dio_adapter.dart';
import '../repositories/_harness.dart';

Map<String, dynamic> _baseJson({String? weightUnit}) {
  return <String, dynamic>{
    'id': 'u_test',
    'display_name': 'Test User',
    'email': 'test@example.com',
    'created_at': '2026-01-01T00:00:00.000',
    'updated_at': '2026-01-02T00:00:00.000',
    if (weightUnit != null) 'weight_unit': weightUnit,
  };
}

void main() {
  group('User.fromJson', () {
    test('missing weight_unit defaults to WeightUnit.kg', () {
      final user = User.fromJson(_baseJson());
      expect(user.weightUnit, WeightUnit.kg);
    });

    test('weight_unit = "kg" parses to WeightUnit.kg', () {
      final user = User.fromJson(_baseJson(weightUnit: 'kg'));
      expect(user.weightUnit, WeightUnit.kg);
    });

    test('weight_unit = "lb" parses to WeightUnit.lb', () {
      final user = User.fromJson(_baseJson(weightUnit: 'lb'));
      expect(user.weightUnit, WeightUnit.lb);
    });

    test('weight_unit = "st" parses to WeightUnit.st', () {
      final user = User.fromJson(_baseJson(weightUnit: 'st'));
      expect(user.weightUnit, WeightUnit.st);
    });

    test('unknown wire value throws ArgumentError', () {
      expect(
        () => User.fromJson(_baseJson(weightUnit: 'oz')),
        throwsArgumentError,
      );
    });
  });

  group('User.toJson', () {
    test('always emits weight_unit (default kg)', () {
      final user = User(
        id: 'u',
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 2),
      );
      final json = user.toJson();
      expect(json.containsKey('weight_unit'), isTrue);
      expect(json['weight_unit'], 'kg');
    });

    test('emits the wire string for non-default units', () {
      final lb = User(
        id: 'u',
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 2),
        weightUnit: WeightUnit.lb,
      );
      expect(lb.toJson()['weight_unit'], 'lb');

      final st = User(
        id: 'u',
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 2),
        weightUnit: WeightUnit.st,
      );
      expect(st.toJson()['weight_unit'], 'st');
    });
  });

  group('User round-trip', () {
    for (final unit in WeightUnit.values) {
      test('round-trips JSON with WeightUnit.${unit.name}', () {
        final original = User(
          id: 'u_round',
          displayName: 'RT',
          email: 'rt@example.com',
          createdAt: DateTime.utc(2026, 1, 1, 12),
          updatedAt: DateTime.utc(2026, 2, 1, 12),
          weightUnit: unit,
        );
        final rebuilt = User.fromJson(original.toJson());
        expect(rebuilt.weightUnit, unit);
        expect(rebuilt, equals(original));
      });
    }
  });

  group('User.copyWith', () {
    test('weightUnit override changes only that field', () {
      final original = User(
        id: 'u',
        displayName: 'Sam',
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 2),
      );
      final copied = original.copyWith(weightUnit: WeightUnit.lb);
      expect(copied.weightUnit, WeightUnit.lb);
      expect(copied.id, original.id);
      expect(copied.displayName, original.displayName);
      expect(copied.createdAt, original.createdAt);
      expect(copied.updatedAt, original.updatedAt);
    });

    test('copyWith without weightUnit preserves existing value', () {
      final original = User(
        id: 'u',
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 2),
        weightUnit: WeightUnit.st,
      );
      final copied = original.copyWith(displayName: 'New Name');
      expect(copied.weightUnit, WeightUnit.st);
      expect(copied.displayName, 'New Name');
    });
  });

  group('User equality / hashCode', () {
    test('two users differing only in weightUnit are not equal', () {
      final a = User(
        id: 'u',
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 2),
        weightUnit: WeightUnit.kg,
      );
      final b = User(
        id: 'u',
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 2),
        weightUnit: WeightUnit.lb,
      );
      expect(a == b, isFalse);
      expect(a.hashCode == b.hashCode, isFalse);
    });
  });

  group('UserPatch.toJson', () {
    test('empty patch does not emit weight_unit', () {
      expect(const UserPatch().toJson().containsKey('weight_unit'), isFalse);
    });

    test('weightUnit-only patch emits only weight_unit', () {
      final json = const UserPatch(weightUnit: WeightUnit.lb).toJson();
      expect(json, <String, dynamic>{'weight_unit': 'lb'});
    });

    test('weight_unit emits "st" for WeightUnit.st', () {
      final json = const UserPatch(weightUnit: WeightUnit.st).toJson();
      expect(json['weight_unit'], 'st');
    });

    test('weight_unit emits "kg" when explicitly set', () {
      // The patch is sparse-by-null, not sparse-by-default — emitting kg
      // when the caller explicitly set kg is intentional (lets a user
      // flip back to the canonical unit).
      final json = const UserPatch(weightUnit: WeightUnit.kg).toJson();
      expect(json['weight_unit'], 'kg');
    });

    test('other fields are unaffected by weightUnit', () {
      final json = const UserPatch(
        displayName: 'New',
        weightUnit: WeightUnit.lb,
      ).toJson();
      expect(json['display_name'], 'New');
      expect(json['weight_unit'], 'lb');
    });
  });

  // `ProfileRepository.update` is now wired to `PATCH /me`. These
  // tests use a `FakeDioAdapter` to capture the request body and
  // return a canned `User` response — what we're asserting is the
  // wire-shape pass-through, not in-memory state.
  group('ProfileRepository.update — weightUnit pass-through', () {
    late ProfileRepository repo;
    late FakeDioAdapter adapter;

    Map<String, dynamic> meWith({String? weightUnit}) => <String, dynamic>{
          'id': 'u_test',
          'display_name': 'Test User',
          'email': 'test@example.com',
          'created_at': '2026-01-01T00:00:00.000Z',
          'updated_at': '2026-01-02T00:00:00.000Z',
          if (weightUnit != null) 'weight_unit': weightUnit,
        };

    setUp(() {
      resetRepositoriesForTest();
      // Default: every GET/PATCH /me echoes a minimal user; weights
      // list returns an empty envelope. Tests can rebuild the adapter
      // with a more specific handler when needed.
      adapter = FakeDioAdapter((options) {
        if (options.path == '/weights') {
          return jsonResponse(200, <String, dynamic>{
            'results': const <dynamic>[],
            'total': 0,
            'limit': 100,
            'offset': 0,
          });
        }
        // Echo whatever weight_unit the PATCH body carried back; GET
        // /me with no body defaults to omitting the key (pre-backend
        // window).
        final body = options.data is Map<String, dynamic>
            ? options.data as Map<String, dynamic>
            : const <String, dynamic>{};
        return jsonResponse(200, meWith(weightUnit: body['weight_unit'] as String?));
      });
      final dio = Dio(BaseOptions(baseUrl: 'https://test.example/api/v1'))
        ..httpClientAdapter = adapter;
      final api = ApiClient(dio, baseUrl: 'https://test.example/api/v1');
      repo = ProfileRepository(
        api: api,
        weightRepository: WeightRepository(api),
        foodRepository: FoodRepository(api),
      );
    });

    tearDown(teardownRepositoriesForTest);

    test('GET /me with no weight_unit defaults to WeightUnit.kg',
        () async {
      final user = await repo.me();
      expect(user.weightUnit, WeightUnit.kg);
      // First request is GET /me, second is GET /weights (the derive
      // path for currentWeightKg).
      expect(adapter.requests.first.method, equalsIgnoringCase('GET'));
      expect(adapter.requests.first.path, equals('/me'));
    });

    test('update(weightUnit: lb) PATCHes /me with weight_unit=lb',
        () async {
      final returned =
          await repo.update(const UserPatch(weightUnit: WeightUnit.lb));
      expect(returned.weightUnit, WeightUnit.lb);

      final patch = adapter.requests
          .firstWhere((r) => r.method.toUpperCase() == 'PATCH');
      expect(patch.path, equals('/me'));
      expect((patch.data as Map)['weight_unit'], equals('lb'));
    });

    test('update(weightUnit: st) PATCHes /me with weight_unit=st',
        () async {
      final returned =
          await repo.update(const UserPatch(weightUnit: WeightUnit.st));
      expect(returned.weightUnit, WeightUnit.st);
      final patch = adapter.requests
          .firstWhere((r) => r.method.toUpperCase() == 'PATCH');
      expect((patch.data as Map)['weight_unit'], equals('st'));
    });

    test('update with no weightUnit omits the key from the patch body',
        () async {
      await repo.update(const UserPatch(displayName: 'Renamed'));
      final patch = adapter.requests
          .firstWhere((r) => r.method.toUpperCase() == 'PATCH');
      expect((patch.data as Map).containsKey('weight_unit'), isFalse);
      expect((patch.data as Map)['display_name'], equals('Renamed'));
    });
  });
}
