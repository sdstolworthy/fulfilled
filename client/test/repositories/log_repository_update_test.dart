// Tests for LU-001 — `LogPatch` + `LogRepository.update`.
//
// The mock repository mirrors `PATCH /log/{id}` from the OpenAPI doc:
// sparse patches, immutable `food_id`, frozen-snapshot recomputation
// from the (possibly new) serving + quantity. These tests pin the
// shape so the future wire swap (TODO LU-001-wire) is a drop-in.

import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/log_entry.dart';
import 'package:fulfilled/domain/meal.dart';
import 'package:fulfilled/repositories/_fixtures.dart';
import 'package:fulfilled/repositories/food_repository.dart';
import 'package:fulfilled/repositories/goal_repository.dart';
import 'package:fulfilled/repositories/log_repository.dart';

import '_harness.dart';

void main() {
  late LogRepository repo;
  late FoodRepository foods;

  setUp(() {
    resetRepositoriesForTest();
    final api = buildTestApiClient();
    foods = FoodRepository(api);
    repo = LogRepository(
      api: api,
      foodRepository: foods,
      goalRepository: GoalRepository(api),
    );
  });

  tearDown(teardownRepositoriesForTest);

  group('LogPatch.toJson', () {
    test('empty patch serialises to {}', () {
      expect(const LogPatch().toJson(), <String, dynamic>{});
      expect(const LogPatch().isEmpty, isTrue);
    });

    test('omits unset, includes set', () {
      final patch = LogPatch(
        quantity: Decimal.parse('2.5'),
        meal: Meal.dinner,
      );
      expect(patch.toJson(), <String, dynamic>{
        'quantity': '2.5',
        'meal': Meal.dinner.wire,
      });
      expect(patch.isEmpty, isFalse);
    });

    test('note: "x" → emits "note": "x"', () {
      expect(const LogPatch(note: 'x').toJson(), <String, dynamic>{'note': 'x'});
    });

    test('clearNote: true with null note → emits "note": null', () {
      final json = const LogPatch(clearNote: true).toJson();
      expect(json.containsKey('note'), isTrue);
      expect(json['note'], isNull);
    });

    test('explicit note + clearNote: true → explicit note wins', () {
      expect(
        const LogPatch(note: 'x', clearNote: true).toJson(),
        <String, dynamic>{'note': 'x'},
      );
    });

    test('clearNote: false with null note → "note" key omitted', () {
      expect(const LogPatch().toJson().containsKey('note'), isFalse);
    });

    test('never emits a food_id key under any input', () {
      // Iterate the obvious permutations; no combination should leak
      // food_id since LogPatch doesn't model it.
      final patches = <LogPatch>[
        const LogPatch(),
        const LogPatch(note: 'x'),
        const LogPatch(clearNote: true),
        LogPatch(quantity: Decimal.one),
        LogPatch(meal: Meal.lunch, servingId: 'sv_x'),
        LogPatch(consumedOn: DateTime(2026, 5, 16)),
      ];
      for (final p in patches) {
        expect(
          p.toJson().containsKey('food_id'),
          isFalse,
          reason: 'food_id leaked in $p',
        );
      }
    });

    test('consumed_on is ISO YYYY-MM-DD', () {
      final p = LogPatch(consumedOn: DateTime(2026, 5, 16));
      expect(p.toJson()['consumed_on'], '2026-05-16');
    });

    test('isEmpty is false when only clearNote is set', () {
      expect(const LogPatch(clearNote: true).isEmpty, isFalse);
    });
  });

  group('LogRepository.update — mock', () {
    test('update with new quantity recomputes nutritionSnapshot', () async {
      final today = await repo.entriesForDate(mockToday());
      final target = today.first;
      final originalKcal = target.nutritionSnapshot.caloriesKcal;
      final originalQty = target.quantity;
      final doubled = originalQty * Decimal.fromInt(2);

      final updated = await repo.update(
        target.id,
        LogPatch(quantity: doubled),
      );

      expect(updated.id, target.id);
      expect(updated.quantity, doubled);
      expect(updated.gramsTotal, target.gramsTotal * Decimal.fromInt(2));
      // Recomputed kcal should be ~2x — Decimal math, no float drift.
      expect(
        updated.nutritionSnapshot.caloriesKcal,
        originalKcal * Decimal.fromInt(2),
      );
      // updatedAt bumps; createdAt stays.
      expect(updated.createdAt, target.createdAt);
      expect(updated.updatedAt.isAfter(target.updatedAt) ||
              updated.updatedAt == target.updatedAt,
          isTrue);
    });

    test('update with new servingId picks the new serving', () async {
      // Find an oatmeal entry — its food has multiple servings in the
      // fixture so we can flip between them.
      final today = await repo.entriesForDate(mockToday());
      final oatmeal = today.firstWhere(
        (e) => e.foodId == 'f_oatmeal_rolled',
        orElse: () => today.first,
      );
      final food = foods.lookup(oatmeal.foodId)!;
      // Pick any serving other than the current one.
      final otherServing = food.servings.firstWhere(
        (s) => s.id != oatmeal.servingId,
        orElse: () => food.servings.first,
      );

      final updated = await repo.update(
        oatmeal.id,
        LogPatch(servingId: otherServing.id),
      );

      expect(updated.servingId, otherServing.id);
      expect(updated.servingName, otherServing.name);
      // grams_total should reflect the new serving's grams * quantity.
      expect(updated.gramsTotal, otherServing.grams * oatmeal.quantity);
    });

    test('update with new consumedOn moves entry to new day', () async {
      final originalDate = mockToday();
      final newDate = originalDate.subtract(const Duration(days: 30));

      final before = await repo.entriesForDate(originalDate);
      final target = before.first;
      final beforeCount = before.length;

      await repo.update(target.id, LogPatch(consumedOn: newDate));

      final afterOriginal = await repo.entriesForDate(originalDate);
      final afterNew = await repo.entriesForDate(newDate);

      expect(afterOriginal.any((e) => e.id == target.id), isFalse,
          reason: 'entry should no longer appear on the original date');
      expect(afterNew.any((e) => e.id == target.id), isTrue,
          reason: 'entry should appear on the new date');
      expect(afterOriginal.length, beforeCount - 1);
    });

    test('update on missing id throws LogEntryNotFoundError', () async {
      expect(
        () => repo.update('le_does_not_exist', LogPatch(meal: Meal.snack)),
        throwsA(isA<LogEntryNotFoundError>()),
      );
    });

    test('update applies note → null when clearNote is true', () async {
      // Find an entry with a non-null note (today's oatmeal has one).
      final today = await repo.entriesForDate(mockToday());
      final withNote = today.firstWhere((e) => e.note != null);

      final updated =
          await repo.update(withNote.id, const LogPatch(clearNote: true));
      expect(updated.note, isNull);
    });

    test('update with explicit note overrides existing note', () async {
      final today = await repo.entriesForDate(mockToday());
      final target = today.first;

      final updated =
          await repo.update(target.id, const LogPatch(note: 'fresh note'));
      expect(updated.note, 'fresh note');
    });

    test('update with no fields is a no-op recompute (same id, same data)',
        () async {
      final today = await repo.entriesForDate(mockToday());
      final target = today.first;

      final updated = await repo.update(target.id, const LogPatch());
      expect(updated.id, target.id);
      expect(updated.quantity, target.quantity);
      expect(updated.meal, target.meal);
      expect(updated.consumedOn, target.consumedOn);
      expect(updated.servingId, target.servingId);
    });

    test('update preserves food_id — patches that try to smuggle one in '
        'throw StateError', () async {
      // The LogPatch class doesn't model foodId, but a hypothetical
      // subclass could. Construct one inline to exercise the guard.
      final today = await repo.entriesForDate(mockToday());
      final target = today.first;
      expect(
        () => repo.update(target.id, _PatchWithFoodId(foodId: 'f_other')),
        throwsA(isA<StateError>()),
      );
      // And the entry's food_id is untouched.
      final after = await repo.entriesForDate(mockToday());
      expect(
        after.firstWhere((e) => e.id == target.id).foodId,
        target.foodId,
      );
    });
  });
}

/// Subclass that smuggles a `food_id` into the patch JSON, used to
/// verify the repository's defence-in-depth guard. Production code never
/// constructs one.
class _PatchWithFoodId extends LogPatch {
  const _PatchWithFoodId({required this.foodId});

  final String foodId;

  @override
  Map<String, dynamic> toJson() {
    final base = super.toJson();
    return <String, dynamic>{...base, 'food_id': foodId};
  }
}
