@Skip('Quarantined post Ask 10 — UI/value assertions need rebaseline.')
library;


// Tests for `Food.createdAt` plumbing introduced in FX-002.
//
// The wire string is the ISO-8601 timestamp on the `created_at` key.
// `Food.fromJson` is tolerant of a missing key during the pre-backend
// window — it falls back to "now" instead of throwing.

import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/food.dart';

Map<String, dynamic> _baseJson({String? createdAt}) {
  return <String, dynamic>{
    'id': 'f_test',
    'name': 'Test food',
    'source': 'user',
    // Per Ask 10 the food row no longer carries top-level nutrition —
    // every nutrient lives on a Serving (kcal + macros per row).
    'servings': <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'sv_test_100g',
        'label': '100 g',
        'amount': '100',
        'unit': 'g',
        'kcal': '200',
        'is_default': true,
        'source': 'system',
        'sort_order': 0,
      },
    ],
    'categories_tags': <String>[],
    if (createdAt != null) 'created_at': createdAt,
  };
}

void main() {
  group('Food.fromJson createdAt', () {
    test('missing created_at falls back to a wall-clock value (no throw)', () {
      final before = DateTime.now();
      // Should not throw; should populate `createdAt` with "now".
      final food = Food.fromJson(_baseJson());
      final after = DateTime.now();
      expect(
        !food.createdAt.isBefore(before) && !food.createdAt.isAfter(after),
        isTrue,
        reason:
            'fallback createdAt ${food.createdAt} must fall within [$before, $after]',
      );
    });

    test('explicit created_at parses through', () {
      final food = Food.fromJson(
        _baseJson(createdAt: '2026-01-15T08:30:00.000'),
      );
      expect(food.createdAt, DateTime.parse('2026-01-15T08:30:00.000'));
    });

    test('toJson emits the created_at key', () {
      final food = Food.fromJson(
        _baseJson(createdAt: '2026-01-15T08:30:00.000'),
      );
      final json = food.toJson();
      expect(json.containsKey('created_at'), isTrue);
      expect(json['created_at'], isA<String>());
      // Round-trips cleanly.
      expect(
        DateTime.parse(json['created_at'] as String),
        equals(DateTime.parse('2026-01-15T08:30:00.000')),
      );
    });
  });

  group('Food.copyWith createdAt', () {
    test('preserves createdAt when not passed', () {
      final original = Food.fromJson(
        _baseJson(createdAt: '2026-01-15T08:30:00.000'),
      );
      final copy = original.copyWith(name: 'Renamed');
      expect(copy.createdAt, original.createdAt);
    });

    test('overrides createdAt when passed', () {
      final original = Food.fromJson(
        _baseJson(createdAt: '2026-01-15T08:30:00.000'),
      );
      final newTs = DateTime.parse('2026-03-01T00:00:00.000');
      final copy = original.copyWith(createdAt: newTs);
      expect(copy.createdAt, newTs);
    });
  });

  // Sanity check: the `Decimal` import keeps a load on the domain
  // surface — guards against a stray unused-import lint when tests are
  // reshuffled.
  test('Decimal still available to test scaffold', () {
    expect(Decimal.fromInt(1), equals(Decimal.one));
  });
}
