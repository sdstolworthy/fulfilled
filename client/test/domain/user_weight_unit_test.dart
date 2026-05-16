// Tests for the `User.weightUnit` + `UserPatch.weightUnit` plumbing
// introduced in LU-004.
//
// The wire string is the lowercase enum name (`'kg' | 'lb' | 'st'`).
// `User.fromJson` is tolerant of a missing `weight_unit` key during the
// pre-backend window — see architect §3.1, §3.3, §4.2.

import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/user.dart';
import 'package:fulfilled/repositories/food_repository.dart';
import 'package:fulfilled/repositories/profile_repository.dart';
import 'package:fulfilled/repositories/weight_repository.dart';

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

  group('ProfileRepository.update — weightUnit pass-through', () {
    late ProfileRepository repo;

    setUp(() {
      resetRepositoriesForTest();
      final api = buildTestApiClient();
      repo = ProfileRepository(
        api: api,
        weightRepository: WeightRepository(api),
        foodRepository: FoodRepository(api),
      );
    });

    tearDown(teardownRepositoriesForTest);

    test('seed user defaults to WeightUnit.kg', () async {
      final user = await repo.me();
      expect(user.weightUnit, WeightUnit.kg);
    });

    test('update(weightUnit: lb) → next me() returns lb', () async {
      await repo.update(const UserPatch(weightUnit: WeightUnit.lb));
      final user = await repo.me();
      expect(user.weightUnit, WeightUnit.lb);
    });

    test('update(weightUnit: st) → next me() returns st', () async {
      await repo.update(const UserPatch(weightUnit: WeightUnit.st));
      final user = await repo.me();
      expect(user.weightUnit, WeightUnit.st);
    });

    test('update returns the post-update User with the new unit', () async {
      final returned =
          await repo.update(const UserPatch(weightUnit: WeightUnit.lb));
      expect(returned.weightUnit, WeightUnit.lb);
    });

    test('update(weightUnit: null) does not change the stored unit',
        () async {
      await repo.update(const UserPatch(weightUnit: WeightUnit.lb));
      // A patch with no weightUnit must leave the previous unit alone.
      await repo.update(const UserPatch(displayName: 'Renamed'));
      final user = await repo.me();
      expect(user.weightUnit, WeightUnit.lb);
      expect(user.displayName, 'Renamed');
    });
  });
}
