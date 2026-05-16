import 'package:decimal/decimal.dart';
import 'package:uuid/uuid.dart';

import '../data/api_client.dart';
import '../domain/drafts.dart';
import '../domain/enums.dart';
import '../domain/food.dart';
import '../domain/food_patch.dart';
import '../domain/serving.dart';
import '_fixtures.dart' show buildSeedFoods, quickAddFoodId;
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
  ///
  /// `@invalidates`
  /// - `foodDetailProvider(foodId)` — the food's serving list grew.
  ///
  /// Call sites are responsible for invalidating per T-18 (minimal +
  /// explicit); this list is the **contract** the call site reads. A
  /// new dependent provider is added by editing this list and the call
  /// sites in the same PR.
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
  ///
  /// `@invalidates`
  /// - `myFoodsProvider` — the new row joins the custom-food library.
  /// - `customFoodCountProvider` — the `source == user` count ticked.
  /// - `meProvider` — `User.customFoodCount` is derived from the count
  ///   in some contexts and must repaint.
  ///
  /// Call sites are responsible for invalidating per T-18 (minimal +
  /// explicit); this list is the **contract** the call site reads. A
  /// new dependent provider is added by editing this list and the call
  /// sites in the same PR.
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

  /// Patch a custom food. Mirrors the planned `PATCH /foods/{id}` —
  /// sparse-by-null shape so callers (the edit screen) can send only the
  /// fields that actually changed. `food_id` is immutable in edit mode;
  /// the patch class refuses to model one, and the JSON guard below
  /// catches anyone constructing the map directly via a subclass.
  ///
  /// Only `source == user` foods are editable. OFF / USDA rows are
  /// read-only — throws [StateError] when the resolved food is
  /// non-user. The screen gates at the UI level; this is
  /// defence-in-depth.
  ///
  /// Throws [FoodNotFoundError] when [foodId] is unknown.
  ///
  /// `@invalidates`
  /// - `foodDetailProvider(foodId)` — the food's fields and serving
  ///   list may have shifted.
  /// - `myFoodsProvider` — the row's display fields (name, brand)
  ///   surface in the library list.
  /// - `customFoodCountProvider` — the count is stable in practice,
  ///   but the provider reads through the same catalog list that just
  ///   mutated; invalidate for symmetry with `createCustom`.
  /// - `meProvider` — `User.customFoodCount` is derived from the count
  ///   in some contexts; keep paired with `customFoodCountProvider`.
  ///
  /// Call sites are responsible for invalidating per T-18 (minimal +
  /// explicit); this list is the **contract** the call site reads. A
  /// new dependent provider is added by editing this list and the call
  /// sites in the same PR.
  Future<Food> updateCustom(String foodId, FoodPatch patch) async {
    // Defence-in-depth against a caller smuggling in an id swap. The
    // PM ruling is unambiguous: edit mode never re-keys the food.
    // `FoodPatch` enforces this at the wire level by not modelling a
    // `food_id` field, so the JSON guard below catches anyone
    // constructing the map directly.
    if (patch.toJson().containsKey('food_id')) {
      throw StateError(
        'FoodPatch must not contain food_id — id is immutable on edit.',
      );
    }
    await mockLatency();
    // TODO(food-edit-wire): replace mock with ApiClient.patch
    // ('/foods/$foodId', patch.toJson())
    final idx = _foods.indexWhere((f) => f.id == foodId);
    if (idx < 0) throw FoodNotFoundError(foodId);
    final current = _foods[idx];

    // Editing a non-user food is meaningless — OFF / USDA rows are
    // read-only. The screen gates at the UI level; this is the
    // defence-in-depth backstop.
    if (current.source != FoodSource.user) {
      throw StateError(
        "Only source == user foods can be edited; got ${current.source.wire} "
        "for $foodId.",
      );
    }

    final nextName = patch.name ?? current.name;
    final String? nextBrand;
    if (patch.brand != null) {
      nextBrand = patch.brand;
    } else if (patch.clearBrand) {
      nextBrand = null;
    } else {
      nextBrand = current.brand;
    }
    final String? nextBarcode;
    if (patch.barcode != null) {
      nextBarcode = patch.barcode;
    } else if (patch.clearBarcode) {
      nextBarcode = null;
    } else {
      nextBarcode = current.barcode;
    }
    final nextNutrition = patch.nutritionPer100g ?? current.nutritionPer100g;

    // Servings: replace the user-defined rows wholesale; preserve every
    // system row (the synthetic 100 g, T-10). When `patch.servings` is
    // null, the existing list is carried through unchanged.
    List<Serving> nextServings;
    if (patch.servings != null) {
      final preserved = current.servings
          .where((s) => s.source == ServingSource.system)
          .toList();
      // Assign sortOrder so the user rows sort beneath the system rows.
      var maxSystemSort = -1;
      for (final s in preserved) {
        if (s.sortOrder > maxSystemSort) maxSystemSort = s.sortOrder;
      }
      final userRows = <Serving>[];
      for (var i = 0; i < patch.servings!.length; i++) {
        final draft = patch.servings![i];
        userRows.add(Serving(
          id: 'sv_${_uuid.v4()}',
          name: draft.label,
          grams: draft.grams,
          isDefault: false,
          source: ServingSource.user,
          sortOrder: maxSystemSort + 1 + i,
        ));
      }
      nextServings = <Serving>[...preserved, ...userRows];
    } else {
      nextServings = current.servings;
    }

    // Use the Food constructor directly — `Food.copyWith` can't clear a
    // nullable field (the `?? this.brand` pattern falls through on null),
    // and we need an explicit-clear path to honour `clearBrand` /
    // `clearBarcode`.
    final updated = Food(
      id: current.id,
      name: nextName,
      brand: nextBrand,
      barcode: nextBarcode,
      source: current.source,
      isCustom: current.isCustom,
      qualityScore: current.qualityScore,
      nutriscore: current.nutriscore,
      nutritionPer100g: nextNutrition,
      servings: nextServings,
      categoriesTags: current.categoriesTags,
    );
    _foods[idx] = updated;
    return updated;
  }

  /// Number of `source == user` rows owned by the caller. Drives screen
  /// 08's "My foods · N" row.
  ///
  /// The synthetic Quick-add food (`quickAddFoodId`) is filed under
  /// `FoodSource.user` so the existing log-write path accepts it, but it
  /// is **not** a user-authored food — exclude it by id so the count
  /// (and the "My foods" list) match the user's mental model.
  Future<int> customCount() async {
    await mockLatency();
    return _foods
        .where((f) => f.source == FoodSource.user && f.id != quickAddFoodId)
        .length;
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
    // Exclude the synthetic Quick-add row: it lives in the catalog so
    // `LogRepository.create` can resolve `food_quick_add`, but it is
    // not a user-authored food and must never surface in "My foods".
    final hits = _foods
        .where((f) => f.source == FoodSource.user && f.id != quickAddFoodId)
        .toList();
    if (offset >= hits.length) return const <Food>[];
    final end = (offset + limit).clamp(0, hits.length);
    return hits.sublist(offset, end);
  }

  /// Internal — bump a food's "frequent" count and prepend its id to the
  /// recent list. Called by `LogRepository.create` so the
  /// recent/frequent providers reflect a freshly-logged item without a
  /// reload.
  ///
  /// `@invalidates`
  /// - `recentFoodsProvider` — `foodId` jumps to the head.
  /// - `frequentFoodsProvider` — the frequency count ticked.
  ///
  /// The caller (`LogRepository.create` / `adoptOptimistic`) owns the
  /// invalidation per T-18; these providers are already listed on
  /// those mutators' `@invalidates` blocks. This block exists so a dev
  /// who reaches `noteFoodLogged` directly sees the contract without a
  /// round-trip to the caller.
  void noteFoodLogged(String foodId) {
    // The synthetic Quick-add food (`food_quick_add`) is a generic
    // "raw calories" bucket — it doesn't represent a real food the
    // user might want to re-log later. Excluding it from recents +
    // frequents keeps those projections meaningful as food
    // suggestions instead of slowly filling with `Quick add` noise.
    if (foodId == quickAddFoodId) return;
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
