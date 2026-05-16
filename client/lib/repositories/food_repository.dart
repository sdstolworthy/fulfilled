import 'package:decimal/decimal.dart';
import 'package:uuid/uuid.dart';

import '../data/api_client.dart';
import '../domain/enums.dart';
import '../domain/food.dart';
import '../domain/serving.dart';
import '_fixtures.dart';
import '_mock_latency.dart';

/// Read + write surface for the `Food` and `Serving` resources. Mirrors
/// the `/foods/*` paths in `specs/openapi.yaml` — screen agents call
/// methods on this class; HTTP arrives in a later sprint.
///
/// **Custom-food count source of truth.** The custom-food count screen
/// 08 reads is the number of `source == user` rows in the catalog. Both
/// the in-memory list and the public method ([customCount]) are kept in
/// sync by the repository — never count `source == user` rows yourself.
class FoodRepository {
  FoodRepository(this._api);

  // ignore: unused_field — kept for parity with the eventual real client.
  final ApiClient _api;

  // Mock state — a mutable list seeded once. Static so multiple repository
  // instances share it (matches the singleton lifetime an injected Dio
  // gives a real client). Deletable when the real API lands.
  static final List<Food> _foods = <Food>[...buildSeedFoods()];

  /// Recency log. Each `logRecent` push moves the food to the head;
  /// `recent` returns the head N. This is the mock equivalent of the
  /// server's "logged most recently" query.
  static final List<String> _recentIds = <String>[
    'f_oatmeal_rolled',
    'f_greek_yogurt_plain',
    'f_chicken_breast',
    'f_brown_rice',
    'f_apple_raw',
    'f_almonds',
    'f_salmon_atlantic',
    'f_pasta_penne',
  ];

  /// Frequency log: count of times a food has been logged. `frequent`
  /// returns the top N by count. The seed mirrors realistic usage so
  /// the QuickChipRow has data on first paint.
  static final Map<String, int> _frequencyById = <String, int>{
    'f_greek_yogurt_plain': 18,
    'f_oatmeal_rolled': 15,
    'f_chicken_breast': 12,
    'f_apple_raw': 10,
    'f_brown_rice': 9,
    'f_almonds': 7,
    'f_almond_milk': 6,
    'f_protein_bar': 5,
  };

  /// Substring search over name + brand. Case-insensitive. Returns the
  /// first `limit` hits past `offset`.
  Future<List<Food>> search(
    String query, {
    int limit = 25,
    int offset = 0,
  }) async {
    await mockLatency();
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const <Food>[];

    bool matches(Food f) {
      final hay = StringBuffer(f.name.toLowerCase());
      if (f.brand != null) hay.write(' ');
      if (f.brand != null) hay.write(f.brand!.toLowerCase());
      // Multi-word query: every whitespace-separated word must hit.
      for (final word in q.split(RegExp(r'\s+'))) {
        if (!hay.toString().contains(word)) return false;
      }
      return true;
    }

    final hits = _foods.where(matches).toList();
    if (offset >= hits.length) return const <Food>[];
    final end = (offset + limit).clamp(0, hits.length);
    return hits.sublist(offset, end);
  }

  /// Recent foods, head-of-list. Returns the most recent N in
  /// recency-order (newest first).
  Future<List<Food>> recent({int limit = 8}) async {
    await mockLatency();
    final out = <Food>[];
    for (final id in _recentIds) {
      if (out.length >= limit) break;
      for (final f in _foods) {
        if (f.id == id) {
          out.add(f);
          break;
        }
      }
    }
    return out;
  }

  /// Frequent foods, ordered by descending count.
  Future<List<Food>> frequent({int limit = 8}) async {
    await mockLatency();
    final ranked = <MapEntry<String, int>>[..._frequencyById.entries]
      ..sort((a, b) => b.value.compareTo(a.value));
    final out = <Food>[];
    for (final entry in ranked) {
      if (out.length >= limit) break;
      for (final f in _foods) {
        if (f.id == entry.key) {
          out.add(f);
          break;
        }
      }
    }
    return out;
  }

  /// Get a food by id. Throws [FoodNotFoundError] when missing — match
  /// the OpenAPI `404 not_found` semantics so screen agents can render a
  /// consistent error state.
  Future<Food> get(String id) async {
    await mockLatency();
    for (final f in _foods) {
      if (f.id == id) return f;
    }
    throw FoodNotFoundError(id);
  }

  /// Resolve a food by barcode. Throws [FoodNotFoundError] when unknown.
  /// Used by screen 02's barcode scan flow; on 404 the architect's brief
  /// has the caller redirect to `/foods/new?barcode=...`.
  Future<Food> byBarcode(String barcode) async {
    await mockLatency();
    for (final f in _foods) {
      if (f.barcode == barcode) return f;
    }
    throw FoodNotFoundError(barcode);
  }

  /// Append a user-defined serving to an existing food. Mirrors the
  /// OpenAPI `POST /foods/{id}/servings` description.
  ///
  /// Used by screen 05's save flow: after `createCustom` returns the new
  /// `Food` (which only carries the auto-seeded 100 g system serving),
  /// the screen iterates the draft's `userServings` and calls this once
  /// per row so they actually persist. The architecture's
  /// silent-correctness fix for T-007.
  ///
  /// Throws [FoodNotFoundError] when [foodId] is unknown — matches
  /// `get()`'s shape so callers can render a consistent error.
  Future<Serving> addServing(String foodId, ServingCreate input) async {
    await mockLatency();
    for (var i = 0; i < _foods.length; i++) {
      final food = _foods[i];
      if (food.id != foodId) continue;

      // sortOrder: max(existing) + 1 so the new row sorts beneath the
      // synthetic 100 g (which stays at sortOrder 0 per T-10's
      // "synthetic always visible at the top" rule).
      var maxSort = -1;
      for (final s in food.servings) {
        if (s.sortOrder > maxSort) maxSort = s.sortOrder;
      }

      final serving = Serving(
        id: 'sv_${_uuid.v4()}',
        name: input.label,
        grams: input.grams,
        isDefault: input.isDefault,
        source: input.source ?? ServingSource.user,
        sortOrder: input.sortOrder ?? (maxSort + 1),
      );

      _foods[i] = food.copyWith(servings: <Serving>[...food.servings, serving]);
      return serving;
    }
    throw FoodNotFoundError(foodId);
  }

  static const Uuid _uuid = Uuid();

  /// Create a custom food. Returns the created row with `source == user`
  /// and a synthetic 100 g serving auto-seeded — mirroring the OpenAPI
  /// `POST /foods` description.
  Future<Food> createCustom(FoodCreate data) async {
    await mockLatency();
    final id = 'f_custom_${DateTime.now().microsecondsSinceEpoch}';
    final servings = <Serving>[
      Serving(
        id: 'sv_${id}_100g',
        name: '100 g',
        grams: Decimal.fromInt(100),
        isDefault: true,
        source: ServingSource.system,
        sortOrder: 0,
      ),
    ];
    final food = Food(
      id: id,
      name: data.name,
      brand: data.brand,
      barcode: data.barcode,
      source: FoodSource.user,
      isCustom: true,
      qualityScore: null,
      nutriscore: data.nutriscore,
      nutritionPer100g: data.nutrition,
      servings: servings,
      categoriesTags: data.categoriesTags,
    );
    _foods.add(food);
    return food;
  }

  /// Number of `source == user` rows owned by the caller. Drives screen
  /// 08's "My foods · N" row.
  Future<int> customCount() async {
    await mockLatency();
    return _foods.where((f) => f.source == FoodSource.user).length;
  }

  /// Custom-food library — every `source == user` row in the catalog. Used
  /// by the `/foods/mine` screen (T-006) so the user can browse the foods
  /// they've created. Order is fixture-list order (newest custom foods are
  /// appended via [createCustom], which means freshly-saved foods land at
  /// the tail naturally). The screen reads them through `myFoodsProvider`.
  ///
  // TODO(T-006-followup): replace fixture-order sort with `createdAt`
  // once the field lands on `Food`.
  Future<List<Food>> customFoods({int limit = 100, int offset = 0}) async {
    await mockLatency();
    final hits = _foods.where((f) => f.source == FoodSource.user).toList();
    if (offset >= hits.length) return const <Food>[];
    final end = (offset + limit).clamp(0, hits.length);
    return hits.sublist(offset, end);
  }

  /// Internal — bump a food's "frequent" count and prepend its id to the
  /// recent list. Called by `LogRepository.create` so the
  /// recent/frequent providers reflect a freshly-logged item without a
  /// reload.
  void noteFoodLogged(String foodId) {
    _frequencyById[foodId] = (_frequencyById[foodId] ?? 0) + 1;
    _recentIds.remove(foodId);
    _recentIds.insert(0, foodId);
  }

  // Test seam — let tests reset the in-memory list to a clean seed
  // without rebuilding the whole repository.
  static void resetForTesting() {
    _foods
      ..clear()
      ..addAll(buildSeedFoods());
    _recentIds
      ..clear()
      ..addAll(<String>[
        'f_oatmeal_rolled',
        'f_greek_yogurt_plain',
        'f_chicken_breast',
        'f_brown_rice',
        'f_apple_raw',
        'f_almonds',
        'f_salmon_atlantic',
        'f_pasta_penne',
      ]);
    _frequencyById
      ..clear()
      ..addAll(<String, int>{
        'f_greek_yogurt_plain': 18,
        'f_oatmeal_rolled': 15,
        'f_chicken_breast': 12,
        'f_apple_raw': 10,
        'f_brown_rice': 9,
        'f_almonds': 7,
        'f_almond_milk': 6,
        'f_protein_bar': 5,
      });
  }

  /// Internal — used by `LogRepository` to enrich an entry with the
  /// food + serving without leaking the static `_foods` list.
  Food? lookup(String id) {
    for (final f in _foods) {
      if (f.id == id) return f;
    }
    return null;
  }
}

/// Outgoing `POST /foods/{id}/servings` payload — screen 05 builds one
/// per user-defined serving in the draft and the repository POSTs each
/// one through [FoodRepository.addServing].
///
/// Plain Dart value class on purpose: no Freezed / json_serializable
/// codegen. A prior attempt at T-007 referenced an undefined
/// `ServingCreate` type which broke the build; this file is the
/// single source of truth.
///
/// Mirrors the OpenAPI `ServingCreate` schema (`label`, `grams`,
/// optional `is_default`, `source`, `sort_order`). The draft side
/// (`DraftServing`) carries `label` + `grams`; the repository fills in
/// the remaining fields with sensible defaults (`source: user`,
/// `sortOrder: max+1`).
class ServingCreate {
  const ServingCreate({
    required this.label,
    required this.grams,
    this.isDefault = false,
    this.source,
    this.sortOrder,
  });

  /// Display label — e.g. "1 container (170 g)", "1 cup". Maps to the
  /// OpenAPI `label` field.
  final String label;
  final Decimal grams;
  final bool isDefault;

  /// Defaults to [ServingSource.user] in the repository when null —
  /// matching the OpenAPI default.
  final ServingSource? source;

  /// When null, the repository assigns `max(existing.sortOrder) + 1` so
  /// the new row sorts beneath the auto-seeded synthetic 100 g.
  final int? sortOrder;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'label': label,
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

/// Thrown by [FoodRepository.get] / [FoodRepository.byBarcode] when the
/// id or barcode is unknown. Screen agents catch this to render the
/// "not found" affordance; the real client will raise an equivalent
/// from a 404 response.
class FoodNotFoundError implements Exception {
  FoodNotFoundError(this.lookupKey);
  final String lookupKey;

  @override
  String toString() => 'FoodNotFoundError: $lookupKey';
}
