import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';

import '../data/api_client.dart';
import '../domain/user.dart';
import 'food_repository.dart';
import 'weight_repository.dart';

/// Read + write surface for the authenticated user's profile. Mirrors
/// `GET /me` and `PATCH /me`.
///
/// **Derived fields.** `currentWeightKg` is not on the wire; it's the
/// most recent weight entry (fetched from [WeightRepository.latest]).
/// `customFoodCount` is the count of `source == user` foods. Both are
/// computed at read time from sibling repositories — never store them
/// on this class.
///
/// **Pre-backend window.** `weight_unit` / `height_unit` are not yet on
/// the wire (PR #2 / BE-001 / BE-004). The decode path in
/// [User.fromJson] tolerates the missing keys and defaults to
/// `WeightUnit.kg` / `HeightUnit.cm`. See the `TODO BE-001/BE-004
/// merge:` marker on the decode path.
class ProfileRepository {
  ProfileRepository({
    required ApiClient api,
    required WeightRepository weightRepository,
    required FoodRepository foodRepository,
  })  : _api = api,
        _weights = weightRepository,
        _foods = foodRepository;

  final ApiClient _api;
  final WeightRepository _weights;
  final FoodRepository _foods;

  /// The current user, with derived fields filled.
  ///
  /// Wire shape: `GET /me` → `User` schema (openapi `#/components/schemas/User`).
  /// The dev deploy currently omits `weight_unit` / `height_unit` keys;
  /// [User.fromJson] defaults them to `kg` / `cm` until the BE merge
  /// lands.
  /// TODO BE-001/BE-004 merge: drop the defaults once openapi User
  /// schema lands the fields on the wire.
  Future<User> me() async {
    final Response<dynamic> resp;
    try {
      resp = await _api.dio.get<dynamic>('/me');
    } on DioException catch (e) {
      // `/me` has no 404 surface — the dev-bypass auto-provisions the
      // user row on first sight. Any non-2xx is reportable: rethrow
      // so the caller (typically a FutureProvider) can surface the
      // error to the UI per T-11.
      throw _mapDioError(e);
    }
    final base = User.fromJson(resp.data as Map<String, dynamic>);

    // Derived fields. `currentWeightKg` is filled from the latest
    // weight entry; an empty history leaves it null (the seed-fixture
    // value is irrelevant once the wire is authoritative). The
    // food-count call is still mock-backed until FoodRepository is
    // wired in a later pass.
    final currentKg = await _latestWeightOrNull();
    final count = await _foods.customCount();

    return base.copyWith(
      currentWeightKg: currentKg ?? base.currentWeightKg,
      customFoodCount: count,
    );
  }

  Future<Decimal?> _latestWeightOrNull() async {
    try {
      final entry = await _weights.latest();
      return entry.weightKg;
    } on WeightNotFoundError {
      return null;
    }
  }

  /// Patch the user. Only the fields set on [data] are applied; nothing
  /// else changes. Returns the post-update presentation model.
  ///
  /// Wire shape: `PATCH /me` with the `ProfilePatch` schema body
  /// (openapi `#/components/schemas/ProfilePatch`). Server returns the
  /// updated `User`.
  ///
  /// `@invalidates`
  /// - `meProvider` — the user record changed; every dependent
  ///   provider (`weightUnitProvider`, `heightUnitProvider`, etc.)
  ///   re-derives automatically via `ref.watch(meProvider)` per T-18.
  ///
  /// Call sites are responsible for invalidating per T-18 (minimal +
  /// explicit); this list is the **contract** the call site reads. A
  /// new dependent provider is added by editing this list and the call
  /// sites in the same PR.
  Future<User> update(UserPatch data) async {
    final Response<dynamic> resp;
    try {
      resp = await _api.dio.patch<dynamic>('/me', data: data.toJson());
    } on DioException catch (e) {
      throw _mapDioError(e);
    }
    final base = User.fromJson(resp.data as Map<String, dynamic>);
    // After a write we still want the derived fields filled — re-run
    // the derivation chain rather than returning the bare server
    // payload (matches the previous mock contract).
    final currentKg = await _latestWeightOrNull();
    final count = await _foods.customCount();
    return base.copyWith(
      currentWeightKg: currentKg ?? base.currentWeightKg,
      customFoodCount: count,
    );
  }

  // Spec-naming note: the openapi schema names the PATCH body
  // `ProfilePatch`; the client's symbol is `UserPatch`. The same data
  // class, the same wire shape — only the name differs. No alias is
  // exposed because `_FakeProfileRepository` test doubles implement
  // this class via `implements`, and every concrete method here is
  // part of their contract.

  Exception _mapDioError(DioException e) {
    // 404 on `/me` is not modelled by the spec; on `PATCH` it would
    // signal a deleted/re-provisioning race. No bespoke profile
    // not-found type exists today; rethrow so the caller surfaces a
    // generic error.
    return e;
  }

  /// No-op kept for test-harness parity with the previous mock-backed
  /// implementation. Real state lives on the server; nothing to reset.
  static void resetForTesting() {}
}
