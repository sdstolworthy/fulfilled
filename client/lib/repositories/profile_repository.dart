import 'package:dio/dio.dart';

import '../data/api_client.dart';
import '../domain/user.dart';

/// Read + write surface for the authenticated user's profile. Mirrors
/// `GET /me` and `PATCH /me`.
///
/// **No derived fields here.** Earlier revisions baked
/// `currentWeightKg` (latest weight entry) and `customFoodCount`
/// (count of `source == user` foods) onto the returned `User` by
/// calling sibling repositories. That meant every weight or food
/// write had to invalidate `meProvider` — a cross-tier dependency
/// that exists only to keep a snapshot fresh. Those derivations now
/// live in dedicated providers (`currentWeightKgProvider`,
/// `customFoodCountProvider`) that widgets watch directly; this
/// class is back to a pure wire client.
///
/// **Pre-backend window.** `weight_unit` / `height_unit` are not yet on
/// the wire (PR #2 / BE-001 / BE-004). The decode path in
/// [User.fromJson] tolerates the missing keys and defaults to
/// `WeightUnit.kg` / `HeightUnit.cm`. See the `TODO BE-001/BE-004
/// merge:` marker on the decode path.
class ProfileRepository {
  ProfileRepository({required ApiClient api}) : _api = api;

  final ApiClient _api;

  /// The current user. Wire shape: `GET /me` → `User` schema (openapi
  /// `#/components/schemas/User`). The dev deploy currently omits
  /// `weight_unit` / `height_unit` keys; [User.fromJson] defaults
  /// them to `kg` / `cm` until the BE merge lands.
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
    return User.fromJson(resp.data as Map<String, dynamic>);
  }

  /// Patch the user. Only the fields set on [data] are applied; nothing
  /// else changes. Returns the post-update wire model.
  ///
  /// Wire shape: `PATCH /me` with the `ProfilePatch` schema body
  /// (openapi `#/components/schemas/ProfilePatch`). Server returns the
  /// updated `User`.
  ///
  /// `@invalidates`
  /// - `meProvider` — the user record changed; every dependent
  ///   provider (`weightUnitProvider`, `heightUnitProvider`, etc.)
  ///   re-derives automatically via `ref.watch(meProvider)` per T-18.
  Future<User> update(UserPatch data) async {
    final Response<dynamic> resp;
    try {
      resp = await _api.dio.patch<dynamic>('/me', data: data.toJson());
    } on DioException catch (e) {
      throw _mapDioError(e);
    }
    return User.fromJson(resp.data as Map<String, dynamic>);
  }

  // Spec-naming note: the openapi schema names the PATCH body
  // `ProfilePatch`; the client's symbol is `UserPatch`. The same data
  // class, the same wire shape — only the name differs.

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
