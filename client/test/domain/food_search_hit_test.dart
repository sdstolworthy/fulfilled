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
}
