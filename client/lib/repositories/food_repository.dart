import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';

import '../data/api_client.dart';
import '../domain/enums.dart';
import '../domain/food.dart';
import '../domain/food_patch.dart';
import '../domain/nutrition.dart';
import '../domain/serving.dart';

/// Read + write surface for the `Food` and `Serving` resources. Mirrors
/// the `/foods/*` + `/servings/*` paths in `specs/openapi.yaml`.
///
/// **List endpoints return `FoodSearchHit`, callers expect `Food`.** The
/// openapi `/foods/search`, `/foods/mine`, `/foods/recent`,
/// `/foods/frequent` endpoints return the slim `FoodSearchHit` shape
/// (id + name + brand + barcode + default_serving preview + per-serving
/// kcal). Every list-bound widget reads `Food`, so this repository
/// projects each hit into a [Food] with a single synthetic default
/// serving and an [NutritionPer100g] back-computed so
/// [Food.caloriesPerDefaultServing] reproduces the wire
/// `calories_per_serving` value. Screens that need full nutrition or the
/// full serving list re-fetch via [get] (→ `foodDetailProvider`).
///
/// **Pagination envelope.** `/foods/search` and `/foods/mine` use the
/// `PaginatedFoodSearchHits` envelope (`{results, total, limit,
/// offset}`); `/foods/recent` and `/foods/frequent` are flat arrays.
/// Per the Ask 6 watch-out, callers advance `offset` by
/// `results.length` rather than by the requested `limit`.
///
/// **`byBarcode` returns `Food?`.** A 404 from `/foods/barcode/{barcode}`
/// is the "no food known for that barcode" path — expected, not
/// exceptional — and surfaces as `null`. Other resource-not-found errors
/// (`get`, `updateCustom`, `addServing`) keep the throw-an-exception
/// shape via [FoodNotFoundError].
class FoodRepository {
  FoodRepository(this._api);

  final ApiClient _api;

  // -------- Reads --------

  /// `GET /foods/search?q=...&limit=&offset=`. Returns the decoded
  /// `results` page. The server clamps `limit` above 500 and rejects an
  /// empty `q` with 400.
  Future<List<Food>> search(
    String query, {
    int limit = 25,
    int offset = 0,
  }) async {
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

  /// `GET /foods/mine` — the caller's `source == user` foods.
  Future<List<Food>> mine({int limit = 100, int offset = 0}) async {
    final resp = await _api.dio.get<dynamic>(
      '/foods/mine',
      queryParameters: <String, dynamic>{
        'limit': limit,
        'offset': offset,
      },
    );
    return _decodePaginatedHits(resp.data);
  }

  /// `GET /foods/recent?limit=`. Wire returns a flat JSON array of
  /// [FoodSearchHit]s — no pagination envelope on this endpoint.
  Future<List<Food>> recent({int limit = 8}) async {
    final resp = await _api.dio.get<dynamic>(
      '/foods/recent',
      queryParameters: <String, dynamic>{'limit': limit},
    );
    return _decodeHitArray(resp.data);
  }

  /// `GET /foods/frequent?limit=`. Wire is a flat array; same shape as
  /// `recent`.
  Future<List<Food>> frequent({int limit = 8}) async {
    final resp = await _api.dio.get<dynamic>(
      '/foods/frequent',
      queryParameters: <String, dynamic>{'limit': limit},
    );
    return _decodeHitArray(resp.data);
  }

  /// `GET /foods/{id}` — full `FoodDetail` including the per-100 g
  /// nutrition panel and the complete serving list. Throws
  /// [FoodNotFoundError] on 404.
  Future<Food> get(String id) async {
    try {
      final resp = await _api.dio.get<dynamic>('/foods/$id');
      return Food.fromJson(resp.data as Map<String, dynamic>);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) throw FoodNotFoundError(id);
      rethrow;
    }
  }

  /// `GET /foods/barcode/{barcode}`. **404 → null** — there's no food
  /// known for the barcode is the expected outcome of a scan, not an
  /// error. Screen 02's barcode flow redirects to `/foods/new?barcode=…`
  /// on `null`; non-404 errors propagate as [DioException].
  Future<Food?> byBarcode(String barcode) async {
    try {
      final resp = await _api.dio.get<dynamic>('/foods/barcode/$barcode');
      return Food.fromJson(resp.data as Map<String, dynamic>);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  // -------- Writes — Food --------

  /// `POST /foods` — create a user-custom food. Server auto-seeds the
  /// synthetic 100 g system serving and returns the full [FoodDetail].
  ///
  /// `@invalidates`
  /// - `myFoodsProvider` — the new row joins the custom-food library.
  /// - `customFoodCountProvider` — the `source == user` count ticked.
  /// - `meProvider` — `User.customFoodCount` is derived from the count.
  Future<Food> createCustom(FoodCreate data) async {
    final resp = await _api.dio.post<dynamic>(
      '/foods',
      data: data.toJson(),
    );
    return Food.fromJson(resp.data as Map<String, dynamic>);
  }

  /// `PATCH /foods/{id}` — sparse-by-null update of a user-owned food.
  /// Throws [FoodNotFoundError] on 404; other DioExceptions propagate.
  ///
  /// `food_id` is never on the wire — the [FoodPatch.toJson] contract
  /// refuses to model one and the guard below catches subclasses.
  ///
  /// `@invalidates`
  /// - `foodDetailProvider(foodId)` — the food's fields and serving
  ///   list may have shifted.
  /// - `myFoodsProvider` — display fields (name, brand) surface in
  ///   the library list.
  /// - `customFoodCountProvider` / `meProvider` — count is stable, but
  ///   keep paired with `createCustom` for symmetry.
  Future<Food> updateCustom(String foodId, FoodPatch patch) async {
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

  /// `DELETE /foods/{id}`. Returns void on 204. Maps 404 → [FoodNotFoundError].
  /// Server returns 403 if the food isn't owned by the caller and 409 if
  /// log entries reference it — those propagate as [DioException] so the
  /// call site can surface a SnackBar.
  Future<void> deleteCustom(String id) async {
    try {
      await _api.dio.delete<void>('/foods/$id');
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) throw FoodNotFoundError(id);
      rethrow;
    }
  }

  // -------- Writes — Serving --------

  /// `POST /foods/{food_id}/servings` — append a serving row. Server
  /// fills in `id`, normalises `sort_order`, and assigns the requested
  /// `is_default` (the prior default is unset by the server).
  ///
  /// Throws [FoodNotFoundError] on 404.
  ///
  /// `@invalidates`
  /// - `foodDetailProvider(foodId)` — the food's serving list grew.
  Future<Serving> addServing(String foodId, ServingCreate input) async {
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

  /// `PATCH /servings/{id}`. Sparse — only the keys present on the patch
  /// are touched. The default-toggle is **not** modelled here; use
  /// [setDefaultServing] for that (it's a separate endpoint per the
  /// openapi `ServingPatch` doc comment).
  Future<Serving> updateServing(String id, ServingPatch patch) async {
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

  /// `DELETE /servings/{id}`. Returns void on 204. Server returns 409 if
  /// the serving is the default for its food — that propagates so the
  /// caller can surface a "promote another serving first" SnackBar.
  Future<void> deleteServing(String id) async {
    try {
      await _api.dio.delete<void>('/servings/$id');
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) throw FoodNotFoundError(id);
      rethrow;
    }
  }

  /// `POST /servings/{id}/default` — atomically flip the `is_default`
  /// flag onto this serving, unsetting whichever sibling held it before.
  /// Returns the serving in its post-flip state.
  Future<Serving> setDefaultServing(String id) async {
    try {
      final resp = await _api.dio.post<dynamic>('/servings/$id/default');
      return Serving.fromJson(resp.data as Map<String, dynamic>);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) throw FoodNotFoundError(id);
      rethrow;
    }
  }

  // -------- Derived helpers (back-compat surface) --------

  /// Custom-food library — every `source == user` row owned by the
  /// caller. Sorted by `created_at` descending so a freshly-saved
  /// custom food surfaces at the top of My foods (FX-002). Backed by
  /// [mine] — the server already filters to `user`-source and excludes
  /// the `__quick_add__` sentinel.
  Future<List<Food>> customFoods({int limit = 100, int offset = 0}) async {
    final page = await mine(limit: limit, offset: offset);
    final sorted = <Food>[...page]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return sorted;
  }

  /// Number of `source == user` rows owned by the caller. Drives
  /// screen 08's "My foods · N" row.
  ///
  /// The server doesn't expose a dedicated count endpoint, so this
  /// reads the `total` field from the `/foods/mine` pagination envelope
  /// with `limit=0` — cheaper than walking the page.
  Future<int> customCount() async {
    final resp = await _api.dio.get<dynamic>(
      '/foods/mine',
      queryParameters: <String, dynamic>{'limit': 0},
    );
    final body = resp.data as Map<String, dynamic>;
    final total = body['total'];
    if (total is num) return total.toInt();
    return 0;
  }

  /// Synchronous lookup used by [LogRepository._decodeEntryWithDenorm]
  /// to populate `LogEntry.foodName` / `servingName` from a local
  /// cache. On the wired path there is no in-memory cache — `null` is
  /// always returned, and the entry surfaces with the server-emitted
  /// names (which the wire now carries directly on `LogEntry`).
  Food? lookup(String id) => null;

  /// Stub kept for source compatibility with `LogRepository.create`'s
  /// optimistic path. Recent / frequent projections are server-derived
  /// (`/foods/recent`, `/foods/frequent`) and the call site already
  /// invalidates those providers, so there's no local state to nudge.
  void noteFoodLogged(String foodId) {}

  /// No-op kept for parity with the mock era — every read/write hits
  /// the wire, so there's no in-memory state to reset.
  static void resetForTesting() {}

  // -------- Decoders --------

  /// Decode a `PaginatedFoodSearchHits` envelope (`{results, total,
  /// limit, offset}`) into a `List<Food>` projection. Each hit becomes a
  /// `Food` with one synthetic default serving and a back-computed
  /// per-100 g kcal so `food.caloriesPerDefaultServing` reproduces the
  /// wire `calories_per_serving`.
  List<Food> _decodePaginatedHits(Object? data) {
    if (data is! Map<String, dynamic>) return const <Food>[];
    final results = (data['results'] as List<dynamic>? ?? const <dynamic>[])
        .cast<Map<String, dynamic>>();
    return <Food>[for (final h in results) _hitToFood(h)];
  }

  List<Food> _decodeHitArray(Object? data) {
    if (data is! List<dynamic>) return const <Food>[];
    return <Food>[
      for (final h in data.cast<Map<String, dynamic>>()) _hitToFood(h),
    ];
  }

  /// Project a `FoodSearchHit` JSON map into a `Food`. The slim hit
  /// shape carries `default_serving: {id, label, grams}` and
  /// `calories_per_serving`; everything else (full nutrition panel,
  /// alternate servings, `created_at`) is unavailable on a list call.
  /// Callers that need it round-trip through [get].
  Food _hitToFood(Map<String, dynamic> json) {
    Decimal? dec(Object? v) =>
        v == null ? null : Decimal.parse(v.toString());

    final source = FoodSource.fromWire(json['source'] as String);
    final defServing = json['default_serving'] as Map<String, dynamic>?;
    final kcalPerServing = dec(json['calories_per_serving']);

    final servings = <Serving>[];
    Decimal? per100Kcal;
    if (defServing != null) {
      final grams = Decimal.parse(defServing['grams'].toString());
      servings.add(Serving(
        id: defServing['id'] as String,
        name: defServing['label'] as String,
        grams: grams,
        // The hit's `default_serving` *is* the food's default by
        // definition — stamp it so `Food.defaultServingId` picks it up.
        isDefault: true,
        // Listing endpoints don't tell us the source; synthetic 100 g
        // rows are flagged `system`, the rest are typically `user`.
        // The detail fetch supplies the real value; for list-card
        // rendering only `id` / `label` / `grams` are read.
        source: grams == Decimal.fromInt(100)
            ? ServingSource.system
            : ServingSource.user,
        sortOrder: 0,
      ));
      // Back-compute per-100 g kcal so `caloriesPerDefaultServing`
      // recomputes to the wire's `calories_per_serving`:
      //   per100 × (grams / 100) = perServing  ⇒  per100 = perServing × 100 / grams.
      if (kcalPerServing != null && grams > Decimal.zero) {
        per100Kcal = (kcalPerServing * Decimal.fromInt(100) / grams)
            .toDecimal(scaleOnInfinitePrecision: 6);
      }
    }

    return Food(
      id: json['id'] as String,
      name: json['name'] as String,
      // `FoodSearchHit` uses `brand` (singular) on the wire, *not*
      // `brands` — the openapi schema is explicit.
      brand: json['brand'] as String?,
      barcode: json['barcode'] as String?,
      source: source,
      isCustom: source == FoodSource.user,
      qualityScore: null,
      nutriscore: null,
      nutritionPer100g: NutritionPer100g(energyKcal: per100Kcal),
      servings: servings,
      categoriesTags: const <String>[],
      // Listing endpoints don't carry `created_at`. Default to "now"
      // matches `Food.fromJson`'s pre-backend fallback and keeps
      // `customFoods()`'s newest-first sort stable across a single
      // page (every projected row gets the same timestamp).
      createdAt: null,
    );
  }
}

/// Outgoing `POST /foods/{id}/servings` payload — screen 05 builds one
/// per user-defined serving in the draft and the repository POSTs each
/// one through [FoodRepository.addServing].
///
/// Mirrors the OpenAPI `ServingCreate` schema (`label`, `grams`,
/// optional `is_default`, `source`, `sort_order`).
class ServingCreate {
  const ServingCreate({
    required this.label,
    required this.grams,
    this.isDefault = false,
    this.source,
    this.sortOrder,
  });

  final String label;
  final Decimal grams;
  final bool isDefault;
  final ServingSource? source;
  final int? sortOrder;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'label': label,
        // T-17: decimals travel as number-shaped strings so the wire
        // never inherits double drift.
        'grams': grams.toString(),
        'is_default': isDefault,
        if (source != null) 'source': source!.wire,
        if (sortOrder != null) 'sort_order': sortOrder,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ServingCreate &&
          other.label == label &&
          other.grams == grams &&
          other.isDefault == isDefault &&
          other.source == source &&
          other.sortOrder == sortOrder;

  @override
  int get hashCode =>
      Object.hash(label, grams, isDefault, source, sortOrder);
}

/// Outgoing `PATCH /servings/{id}` payload — sparse-by-null. Toggling
/// `is_default` is **not** modelled here; the openapi spec routes that
/// through [FoodRepository.setDefaultServing] (`POST /servings/{id}/default`).
class ServingPatch {
  const ServingPatch({
    this.label,
    this.grams,
    this.sortOrder,
  });

  final String? label;
  final Decimal? grams;
  final int? sortOrder;

  bool get isEmpty => label == null && grams == null && sortOrder == null;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (label != null) 'label': label,
        if (grams != null) 'grams': grams!.toString(),
        if (sortOrder != null) 'sort_order': sortOrder,
      };
}

/// Thrown by [FoodRepository.get] / [FoodRepository.updateCustom] /
/// [FoodRepository.deleteCustom] / [FoodRepository.addServing] /
/// [FoodRepository.updateServing] / [FoodRepository.deleteServing] /
/// [FoodRepository.setDefaultServing] when the server returns
/// `404 not_found`. `byBarcode` maps 404 → `null` instead (no food for
/// a scanned barcode is expected, not exceptional).
class FoodNotFoundError implements Exception {
  FoodNotFoundError(this.lookupKey);
  final String lookupKey;

  @override
  String toString() => 'FoodNotFoundError: $lookupKey';
}
