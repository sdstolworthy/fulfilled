// Tests for `FoodSearchHit.fromJson` kcal decoding under the F1
// contract drift between the BE and FE.
//
// Background: the BE used to nest the per-serving kcal exclusively
// under `default_serving.kcal`, while the FE contract (and F1-T1)
// promotes a top-level `calories_per_serving` field. Until F1-T1 is
// deployed everywhere, the decoder needs to accept either shape —
// preferring the top-level field when both are present.
//
// See `feature_tickets.md` §F1-T2 for the exact decoder contract.
//
// F5-T3 extends this file with cases for the three log-history fields
// (`last_logged_at`, `log_count`, `last_serving_id`) and the
// `isPreviouslyLogged` getter. The `last_logged_at` wire shape is a
// bare `"YYYY-MM-DD"` date string (not an ISO-8601 instant) per
// `feature_tickets_f5.md` "Wire-shape decisions" §2.

import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/food.dart';

Map<String, dynamic> _baseHit({
  Object? topLevelKcal = _absent,
  Object? nestedKcal = _absent,
}) {
  final defServing = <String, dynamic>{
    'id': 'sv_test',
    'label': '1 serving',
    'amount': '1',
    'unit': 'serving',
  };
  if (nestedKcal != _absent) {
    defServing['kcal'] = nestedKcal;
  }
  final json = <String, dynamic>{
    'id': 'f_test',
    'name': 'Test food',
    'source': 'user',
    'default_serving': defServing,
  };
  if (topLevelKcal != _absent) {
    json['calories_per_serving'] = topLevelKcal;
  }
  return json;
}

const Object _absent = Object();

void main() {
  group('FoodSearchHit.fromJson kcal fallback', () {
    test('top-level calories_per_serving wins over nested default_serving.kcal',
        () {
      final hit = FoodSearchHit.fromJson(
        _baseHit(topLevelKcal: '180', nestedKcal: '999'),
      );
      expect(hit.caloriesPerServing, Decimal.fromInt(180));
    });

    test(
        'falls back to nested default_serving.kcal when top-level is absent',
        () {
      final hit = FoodSearchHit.fromJson(
        _baseHit(nestedKcal: '180'),
      );
      expect(hit.caloriesPerServing, Decimal.fromInt(180));
    });

    test('returns null when neither top-level nor nested kcal is present', () {
      final hit = FoodSearchHit.fromJson(_baseHit());
      expect(hit.caloriesPerServing, isNull);
    });
  });

  group('FoodSearchHit.fromJson F5 log-history fields', () {
    test(
        'all three fields present → decoded; isPreviouslyLogged == true; '
        'date is local midnight from bare YYYY-MM-DD', () {
      final hit = FoodSearchHit.fromJson(<String, dynamic>{
        ..._baseHit(),
        'last_logged_at': '2026-05-14',
        'log_count': 4,
        'last_serving': <String, dynamic>{
          'id': 'sv_last',
          'label': '1 slice',
          'amount': '1',
          'unit': 'serving',
          'kcal': '296',
        },
      });
      expect(hit.lastLoggedAt, isNotNull);
      expect(hit.lastLoggedAt!.year, 2026);
      expect(hit.lastLoggedAt!.month, 5);
      expect(hit.lastLoggedAt!.day, 14);
      expect(hit.lastLoggedAt!.hour, 0);
      expect(hit.lastLoggedAt!.minute, 0);
      expect(hit.lastLoggedAt!.isUtc, isFalse);
      expect(hit.logCount, 4);
      expect(hit.lastServingId, 'sv_last');
      expect(hit.lastServingLabel, '1 slice');
      expect(hit.lastServingKcal.toString(), '296');
      expect(hit.isPreviouslyLogged, isTrue);
    });

    test(
        'all three fields absent → all null; isPreviouslyLogged == false',
        () {
      final hit = FoodSearchHit.fromJson(_baseHit());
      expect(hit.lastLoggedAt, isNull);
      expect(hit.logCount, isNull);
      expect(hit.lastServingId, isNull);
      expect(hit.lastServingKcal, isNull);
      expect(hit.isPreviouslyLogged, isFalse);
    });

    test('explicit nulls decode the same as absent fields', () {
      final hit = FoodSearchHit.fromJson(<String, dynamic>{
        ..._baseHit(),
        'last_logged_at': null,
        'log_count': null,
        'last_serving': null,
      });
      expect(hit.lastLoggedAt, isNull);
      expect(hit.logCount, isNull);
      expect(hit.lastServingId, isNull);
      expect(hit.lastServingKcal, isNull);
      expect(hit.isPreviouslyLogged, isFalse);
    });

    test(
        'log_count == 0 with null last_logged_at → isPreviouslyLogged == false '
        '(BE-default zero-state regression)', () {
      final hit = FoodSearchHit.fromJson(<String, dynamic>{
        ..._baseHit(),
        'log_count': 0,
      });
      expect(hit.logCount, 0);
      expect(hit.lastLoggedAt, isNull);
      expect(hit.isPreviouslyLogged, isFalse);
    });

    test('fromJson → toJson round-trip preserves log-history fields', () {
      final json = <String, dynamic>{
        ..._baseHit(topLevelKcal: '180'),
        'last_logged_at': '2026-05-14',
        'log_count': 7,
        'last_serving': <String, dynamic>{
          'id': 'sv_last',
          'label': '1 slice',
          'amount': '1',
          'unit': 'serving',
          'kcal': '296',
        },
      };
      final hit = FoodSearchHit.fromJson(json);
      final round = hit.toJson();
      expect(round['last_logged_at'], '2026-05-14');
      expect(round['log_count'], 7);
      final ls = round['last_serving'] as Map<String, dynamic>;
      expect(ls['id'], 'sv_last');
      expect(ls['label'], '1 slice');
      expect(ls['kcal'], '296');
      // Decoding the re-encoded payload yields an equal `FoodSearchHit`.
      expect(FoodSearchHit.fromJson(round), hit);
    });
  });
}
