import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';

import '../data/api_client.dart';
import '../domain/enums.dart';
import '../domain/food.dart';
import '../domain/food_patch.dart';
import '../domain/quick_add.dart';
import '../domain/serving.dart';
import '../domain/unit.dart';
import '_fixtures.dart' as fx;

/// Ask 10 backend shipped (commit `51fd542`, deployed live). The
/// repository now goes through Dio against the real API by default.
/// Tests that need to exercise the in-memory fixture path
/// (`buildSeedFoods`) construct the repo with `useFixtures: true` —
/// the per-instance flag is preserved so the seam stays available
/// for tooling, demos, or offline development.
const bool kUseFixtures = false;

/// Read + write surface for the `Food` and `Serving` resources. Mirrors
/// the `/foods/*` + `/servings/*` paths in `specs/openapi.yaml`.
///
/// **Fixture mode (Ask 10 stopgap).** When [kUseFixtures] is true, every
/// public method short-circuits against an in-memory store seeded from
/// [fx.buildSeedFoods]. Writes mutate the store; reads return projections
/// from it. This lets the FE editor + log-entry flows run end-to-end
/// against the new per-serving shape ahead of the BE landing.
///
/// **Live-API mode.** The Dio-backed paths below are preserved verbatim
/// (modulo type updates) so we can flip the flag the moment the BE
/// emits the new shape. Pagination, decoders, error mapping all stay.
class FoodRepository {
  FoodRepository(this._api, {bool useFixtures = kUseFixtures})
      : _useFixtures = useFixtures {
    if (_useFixtures) _seedFixtureStore();
  }

  final ApiClient _api;

  /// Per-instance fixture-mode flag. Defaults to the top-level
  /// [kUseFixtures] const; tests pass `useFixtures: false` to exercise
  /// the live-API decoders against a mocked Dio adapter.
  final bool _useFixtures;

  /// In-memory store used when [kUseFixtures] is true. Mutated by
  /// writes; read by every list/get call. Reset between widget tests
  /// via [resetForTesting].
  final List<Food> _store = <Food>[];

  /// Per-instance cache populated by every successful read; consulted
  /// by [lookup]. Retained behind [kUseFixtures] so live-mode rollback
  /// remains drop-in.
  final Map<String, Food> _byIdCache = <String, Food>{};

  void _seedFixtureStore() {
    if (_store.isNotEmpty) return;
    _store.addAll(fx.buildSeedFoods());
    for (final f in _store) {
      _byIdCache[f.id] = f;
    }
  }

  void _remember(Food food) {
    _byIdCache[food.id] = food;
  }

  // -------- Reads --------

  Future<List<Food>> search(
    String query, {
    int limit = 25,
    int offset = 0,
  }) async {
    if (_useFixtures) {
      final q = query.trim().toLowerCase();
      final hits = _store
          .where((f) =>
              f.id != quickAddFoodId &&
              (q.isEmpty ||
                  f.name.toLowerCase().contains(q) ||
                  (f.brand?.toLowerCase().contains(q) ?? false)))
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      return hits.skip(offset).take(limit).toList();
    }
    final resp = await _api.dio.get<dynamic>(
      '/foods/search',
      queryParameters: <String, dynamic>{
        'q': query,
        'limit': limit,
        'offset': offset,
      },
    );
    return _decodePaginatedHits(resp.data);
  }

  Future<List<Food>> mine({int limit = 100, int offset = 0}) async {
    if (_useFixtures) {
      final hits = _store
          .where((f) => f.source == FoodSource.user && f.id != quickAddFoodId)
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return hits.skip(offset).take(limit).toList();
    }
    final resp = await _api.dio.get<dynamic>(
      '/foods/mine',
      queryParameters: <String, dynamic>{
        'limit': limit,
        'offset': offset,
      },
    );
    return _decodePaginatedHits(resp.data);
  }

  Future<List<Food>> recent({int limit = 8}) async {
    if (_useFixtures) {
      final hits = _store
          .where((f) => f.id != quickAddFoodId)
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return hits.take(limit).toList();
    }
    final resp = await _api.dio.get<dynamic>(
      '/foods/recent',
      queryParameters: <String, dynamic>{'limit': limit},
    );
    return _decodeHitArray(resp.data);
  }

  Future<List<Food>> frequent({int limit = 8}) async {
    if (_useFixtures) {
      // Same projection as recent for fixture mode — the FE only cares
      // that the list renders; rank-order is irrelevant against seeds.
      return recent(limit: limit);
    }
    final resp = await _api.dio.get<dynamic>(
      '/foods/frequent',
      queryParameters: <String, dynamic>{'limit': limit},
    );
    return _decodeHitArray(resp.data);
  }

  Future<Food> get(String id) async {
    if (_useFixtures) {
      final hit = _store.where((f) => f.id == id).toList();
      if (hit.isEmpty) throw FoodNotFoundError(id);
      _remember(hit.first);
      return hit.first;
    }
    try {
      final resp = await _api.dio.get<dynamic>('/foods/$id');
      final food = Food.fromJson(resp.data as Map<String, dynamic>);
      _remember(food);
      return food;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) throw FoodNotFoundError(id);
      rethrow;
    }
  }

  Future<void> prefetchByIds(Iterable<String> ids) async {
    if (_useFixtures) {
      for (final id in ids) {
        final hit = _store.where((f) => f.id == id);
        if (hit.isNotEmpty) _remember(hit.first);
      }
      return;
    }
    final missing = ids.toSet().where((id) => !_byIdCache.containsKey(id));
    if (missing.isEmpty) return;
    await Future.wait(
      missing.map((id) async {
        try {
          await get(id);
        } on FoodNotFoundError {
          // The food was deleted between log-time and now; the row still
          // has its snapshot kcal/macros — it just won't have a name.
        } on DioException {
          // Network blip — let the next read try again.
        }
      }),
    );
  }

  Future<Food?> byBarcode(String barcode) async {
    if (_useFixtures) {
      final hit = _store.where((f) => f.barcode == barcode).toList();
      if (hit.isEmpty) return null;
      _remember(hit.first);
      return hit.first;
    }
    try {
      final resp = await _api.dio.get<dynamic>('/foods/barcode/$barcode');
      final food = Food.fromJson(resp.data as Map<String, dynamic>);
      _remember(food);
      return food;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  // -------- Writes — Food --------

  Future<Food> createCustom(FoodCreate data) async {
    if (_useFixtures) {
      final servings = <Serving>[];
      for (var i = 0; i < data.servings.length; i++) {
        final s = data.servings[i];
        servings.add(Serving(
          id: 'sv_${DateTime.now().microsecondsSinceEpoch}_$i',
          label: s.label,
          amount: s.amount,
          unit: s.unit,
          kcal: s.kcal,
          proteinG: s.proteinG,
          carbsG: s.carbsG,
          fatG: s.fatG,
          fiberG: s.fiberG,
          sugarG: s.sugarG,
          sodiumMg: s.sodiumMg,
          saturatedFatG: s.saturatedFatG,
          isDefault: s.isDefault ||
              (i == 0 && data.servings.every((x) => !x.isDefault)),
          source: ServingSource.user,
          sortOrder: i + 1,
        ));
      }
      final food = Food(
        id: 'f_${DateTime.now().microsecondsSinceEpoch}',
        createdAt: DateTime.now(),
        name: data.name,
        brand: data.brand,
        barcode: data.barcode,
        source: FoodSource.user,
        isCustom: true,
        servings: servings,
        categoriesTags: data.categoriesTags,
      );
      _store.add(food);
      _remember(food);
      return food;
    }
    final resp = await _api.dio.post<dynamic>(
      '/foods',
      data: data.toJson(),
    );
    return Food.fromJson(resp.data as Map<String, dynamic>);
  }

  Future<Food> updateCustom(String foodId, FoodPatch patch) async {
    if (_useFixtures) {
      final i = _store.indexWhere((f) => f.id == foodId);
      if (i < 0) throw FoodNotFoundError(foodId);
      final original = _store[i];
      final newServings = patch.servings == null
          ? original.servings
          : <Serving>[
              for (var k = 0; k < patch.servings!.length; k++)
                Serving(
                  id: 'sv_${DateTime.now().microsecondsSinceEpoch}_$k',
                  label: patch.servings![k].label,
                  amount: patch.servings![k].amount!,
                  unit: patch.servings![k].unit,
                  kcal: patch.servings![k].kcal!,
                  proteinG: patch.servings![k].proteinG,
                  carbsG: patch.servings![k].carbsG,
                  fatG: patch.servings![k].fatG,
                  fiberG: patch.servings![k].fiberG,
                  sugarG: patch.servings![k].sugarG,
                  sodiumMg: patch.servings![k].sodiumMg,
                  saturatedFatG: patch.servings![k].saturatedFatG,
                  isDefault: patch.servings![k].isDefault ||
                      (k == 0 &&
                          patch.servings!.every((s) => !s.isDefault)),
                  source: ServingSource.user,
                  sortOrder: k + 1,
                ),
            ];
      final updated = original.copyWith(
        name: patch.name,
        brand: patch.clearBrand ? null : (patch.brand ?? original.brand),
        barcode: patch.clearBarcode ? null : (patch.barcode ?? original.barcode),
        servings: newServings,
      );
      _store[i] = updated;
      _remember(updated);
      return updated;
    }
    final body = patch.toJson();
    if (body.containsKey('food_id')) {
      throw StateError(
        'FoodPatch must not contain food_id — id is immutable on edit.',
      );
    }
    try {
      final resp = await _api.dio.patch<dynamic>(
        '/foods/$foodId',
        data: body,
      );
      return Food.fromJson(resp.data as Map<String, dynamic>);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) throw FoodNotFoundError(foodId);
      rethrow;
    }
  }

  Future<void> deleteCustom(String id) async {
    if (_useFixtures) {
      final i = _store.indexWhere((f) => f.id == id);
      if (i < 0) throw FoodNotFoundError(id);
      _store.removeAt(i);
      _byIdCache.remove(id);
      return;
    }
    try {
      await _api.dio.delete<void>('/foods/$id');
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) throw FoodNotFoundError(id);
      rethrow;
    }
  }

  // -------- Writes — Serving --------

  Future<Serving> addServing(String foodId, ServingCreate input) async {
    if (_useFixtures) {
      final i = _store.indexWhere((f) => f.id == foodId);
      if (i < 0) throw FoodNotFoundError(foodId);
      final food = _store[i];
      final newServing = Serving(
        id: 'sv_${DateTime.now().microsecondsSinceEpoch}',
        label: input.label,
        amount: input.amount,
        unit: input.unit,
        kcal: input.kcal,
        proteinG: input.proteinG,
        carbsG: input.carbsG,
        fatG: input.fatG,
        fiberG: input.fiberG,
        sugarG: input.sugarG,
        sodiumMg: input.sodiumMg,
        saturatedFatG: input.saturatedFatG,
        isDefault: input.isDefault,
        source: ServingSource.user,
        sortOrder: food.servings.length + 1,
      );
      final updatedServings = <Serving>[
        if (input.isDefault)
          for (final s in food.servings) s.copyWith(isDefault: false)
        else
          ...food.servings,
        newServing,
      ];
      _store[i] = food.copyWith(servings: updatedServings);
      return newServing;
    }
    try {
      final resp = await _api.dio.post<dynamic>(
        '/foods/$foodId/servings',
        data: input.toJson(),
      );
      return Serving.fromJson(resp.data as Map<String, dynamic>);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) throw FoodNotFoundError(foodId);
      rethrow;
    }
  }

  Future<Serving> updateServing(String id, ServingPatch patch) async {
    if (_useFixtures) {
      for (var i = 0; i < _store.length; i++) {
        final food = _store[i];
        final si = food.servings.indexWhere((s) => s.id == id);
        if (si < 0) continue;
        final original = food.servings[si];
        final updated = original.copyWith(
          label: patch.label ?? original.label,
          amount: patch.amount ?? original.amount,
          unit: patch.unit ?? original.unit,
          kcal: patch.kcal ?? original.kcal,
          proteinG: patch.proteinG ?? original.proteinG,
          carbsG: patch.carbsG ?? original.carbsG,
          fatG: patch.fatG ?? original.fatG,
          sortOrder: patch.sortOrder ?? original.sortOrder,
        );
        final newServings = <Serving>[...food.servings]..[si] = updated;
        _store[i] = food.copyWith(servings: newServings);
        return updated;
      }
      throw FoodNotFoundError(id);
    }
    try {
      final resp = await _api.dio.patch<dynamic>(
        '/servings/$id',
        data: patch.toJson(),
      );
      return Serving.fromJson(resp.data as Map<String, dynamic>);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) throw FoodNotFoundError(id);
      rethrow;
    }
  }

  Future<void> deleteServing(String id) async {
    if (_useFixtures) {
      for (var i = 0; i < _store.length; i++) {
        final food = _store[i];
        final si = food.servings.indexWhere((s) => s.id == id);
        if (si < 0) continue;
        final newServings = <Serving>[...food.servings]..removeAt(si);
        _store[i] = food.copyWith(servings: newServings);
        return;
      }
      throw FoodNotFoundError(id);
    }
    try {
      await _api.dio.delete<void>('/servings/$id');
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) throw FoodNotFoundError(id);
      rethrow;
    }
  }

  Future<Serving> setDefaultServing(String id) async {
    if (_useFixtures) {
      for (var i = 0; i < _store.length; i++) {
        final food = _store[i];
        final si = food.servings.indexWhere((s) => s.id == id);
        if (si < 0) continue;
        final newServings = <Serving>[
          for (var k = 0; k < food.servings.length; k++)
            food.servings[k].copyWith(isDefault: k == si),
        ];
        _store[i] = food.copyWith(servings: newServings);
        return newServings[si];
      }
      throw FoodNotFoundError(id);
    }
    try {
      final resp = await _api.dio.post<dynamic>('/servings/$id/default');
      return Serving.fromJson(resp.data as Map<String, dynamic>);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) throw FoodNotFoundError(id);
      rethrow;
    }
  }

  // -------- Derived helpers --------

  Future<List<Food>> customFoods({int limit = 100, int offset = 0}) async {
    final page = await mine(limit: limit, offset: offset);
    final sorted = <Food>[...page]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return sorted;
  }

  Future<int> customCount() async {
    if (_useFixtures) {
      return _store
          .where((f) => f.source == FoodSource.user && f.id != quickAddFoodId)
          .length;
    }
    final resp = await _api.dio.get<dynamic>(
      '/foods/mine',
      queryParameters: <String, dynamic>{'limit': 0},
    );
    final body = resp.data as Map<String, dynamic>;
    final total = body['total'];
    if (total is num) return total.toInt();
    return 0;
  }

  Food? lookup(String id) => _byIdCache[id];

  /// Per-instance reset for fixture-mode tests. Clears the store +
  /// cache and re-seeds. Static-style call sites (test/_harness.dart)
  /// use [resetForTesting] (the static no-op below) — every new
  /// `FoodRepository` instance auto-seeds in its constructor, so the
  /// "between tests" semantics are preserved without needing to share
  /// a singleton instance.
  void resetInstanceForTesting() {
    _store.clear();
    _byIdCache.clear();
    if (_useFixtures) _seedFixtureStore();
  }

  /// No-op static reset retained for source compat with the pre-Ask-10
  /// `test/repositories/_harness.dart` that calls
  /// `FoodRepository.resetForTesting()`. Fixture state is now
  /// per-instance, so constructing a new repo gives a clean store —
  /// nothing to reset at the class level.
  static void resetForTesting() {}

  // -------- Live-mode decoders (dormant under kUseFixtures) --------

  List<Food> _decodePaginatedHits(Object? data) {
    if (data is! Map<String, dynamic>) return const <Food>[];
    final results = (data['results'] as List<dynamic>? ?? const <dynamic>[])
        .cast<Map<String, dynamic>>();
    final foods = <Food>[for (final h in results) _hitToFood(h)];
    for (final f in foods) {
      _remember(f);
    }
    return foods;
  }

  List<Food> _decodeHitArray(Object? data) {
    if (data is! List<dynamic>) return const <Food>[];
    final foods = <Food>[
      for (final h in data.cast<Map<String, dynamic>>()) _hitToFood(h),
    ];
    for (final f in foods) {
      _remember(f);
    }
    return foods;
  }

  /// Project a `FoodSearchHit` JSON map into a `Food`. Under the new
  /// wire shape `default_serving` carries `{id, label?, amount, unit}`
  /// plus a top-level `calories_per_serving` — we synthesize a single
  /// serving with those values + the per-serving kcal. The full nutrition
  /// only comes from `GET /foods/{id}`.
  Food _hitToFood(Map<String, dynamic> json) {
    Decimal? dec(Object? v) =>
        v == null ? null : Decimal.parse(v.toString());

    final source = FoodSource.fromWire(json['source'] as String);
    final defServing = json['default_serving'] as Map<String, dynamic>?;
    final kcalPerServing = dec(json['calories_per_serving'] ?? defServing?['kcal']);

    final servings = <Serving>[];
    if (defServing != null && kcalPerServing != null) {
      final amount = dec(defServing['amount']) ?? Decimal.one;
      final unitWire = defServing['unit'] as String?;
      servings.add(Serving(
        id: defServing['id'] as String,
        label: defServing['label'] as String?,
        amount: amount,
        unit: unitWire == null ? Unit.g : Unit.fromWire(unitWire),
        kcal: kcalPerServing,
        isDefault: true,
        source: ServingSource.system,
        sortOrder: 0,
      ));
    }

    return Food(
      id: json['id'] as String,
      name: json['name'] as String,
      brand: json['brand'] as String?,
      barcode: json['barcode'] as String?,
      source: source,
      isCustom: source == FoodSource.user,
      qualityScore: null,
      nutriscore: null,
      servings: servings,
      categoriesTags: const <String>[],
      createdAt: null,
      // Forward F5 log-history signals from the enriched hit JSON so the
      // search-result row widget can read them off the `Food` directly
      // (the row only sees a `Food`, never the raw hit). Wire shape for
      // `last_logged_at` is a bare `"YYYY-MM-DD"` date — `DateTime.parse`
      // accepts it and returns local midnight, matching F5-T4's "Today /
      // Yesterday / Tue" math.
      lastLoggedAt: json['last_logged_at'] == null
          ? null
          : DateTime.parse(json['last_logged_at'] as String),
      logCount: (json['log_count'] as num?)?.toInt(),
      // F5 last-serving preview — flattened from the nested
      // `last_serving` object so the `Food` exposes the same
      // `lastServingKcal` / `lastServingLabel` fields the search row
      // reads directly.
      lastServingId: (json['last_serving'] as Map<String, dynamic>?)?['id'] as String?,
      lastServingLabel:
          (json['last_serving'] as Map<String, dynamic>?)?['label'] as String?,
      lastServingAmount: () {
        final raw = (json['last_serving'] as Map<String, dynamic>?)?['amount'];
        return raw == null ? null : Decimal.parse(raw.toString());
      }(),
      lastServingUnit: () {
        final raw =
            (json['last_serving'] as Map<String, dynamic>?)?['unit'] as String?;
        return raw == null ? null : Unit.fromWire(raw);
      }(),
      lastServingKcal: () {
        final raw = (json['last_serving'] as Map<String, dynamic>?)?['kcal'];
        return raw == null ? null : Decimal.parse(raw.toString());
      }(),
    );
  }
}

/// Outgoing `PATCH /servings/{id}` payload — sparse-by-null. Toggling
/// `is_default` is **not** modelled here; the openapi spec routes that
/// through [FoodRepository.setDefaultServing] (`POST /servings/{id}/default`).
class ServingPatch {
  const ServingPatch({
    this.label,
    this.amount,
    this.unit,
    this.kcal,
    this.proteinG,
    this.carbsG,
    this.fatG,
    this.sortOrder,
  });

  final String? label;
  final Decimal? amount;
  final Unit? unit;
  final Decimal? kcal;
  final Decimal? proteinG;
  final Decimal? carbsG;
  final Decimal? fatG;
  final int? sortOrder;

  bool get isEmpty =>
      label == null &&
      amount == null &&
      unit == null &&
      kcal == null &&
      proteinG == null &&
      carbsG == null &&
      fatG == null &&
      sortOrder == null;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (label != null) 'label': label,
        if (amount != null) 'amount': amount!.toString(),
        if (unit != null) 'unit': unit!.wire,
        if (kcal != null) 'kcal': kcal!.toString(),
        if (proteinG != null) 'protein_g': proteinG!.toString(),
        if (carbsG != null) 'carbs_g': carbsG!.toString(),
        if (fatG != null) 'fat_g': fatG!.toString(),
        if (sortOrder != null) 'sort_order': sortOrder,
      };
}

/// Thrown by [FoodRepository] reads / mutators on a 404 / missing-id.
class FoodNotFoundError implements Exception {
  FoodNotFoundError(this.lookupKey);
  final String lookupKey;

  @override
  String toString() => 'FoodNotFoundError: $lookupKey';
}
