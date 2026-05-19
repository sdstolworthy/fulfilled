// Domain-level tests for `LogPatch.toJson`. The repository-level
// `update` wire path lives in `log_repository_test.dart` under the
// `update — PATCH /log/{id}` group; this file pins the patch encoder's
// sparse-by-null behaviour, the `food_id`-never-emitted invariant, and
// the `clearNote` semantics. They are pure unit tests against the
// domain class — no Dio, no repository.

import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/log_entry.dart';
import 'package:fulfilled/domain/meal.dart';

void main() {
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
      expect(const LogPatch(note: 'x').toJson(),
          <String, dynamic>{'note': 'x'},);
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
        const LogPatch(meal: Meal.lunch, servingId: 'sv_x'),
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
}
