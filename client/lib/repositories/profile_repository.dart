import '../data/api_client.dart';
import '../domain/user.dart';
import 'food_repository.dart';
import '_fixtures.dart';
import '_mock_latency.dart';
import 'weight_repository.dart';

/// Read + write surface for the authenticated user's profile. Mirrors
/// `GET /me` and `PATCH /me`.
///
/// **Derived fields.** `currentWeightKg` is not on the wire; it's the
/// most recent weight entry. `customFoodCount` is the count of
/// `source == user` foods. Both are computed at read time from sibling
/// repositories — never store them on this class.
class ProfileRepository {
  ProfileRepository({
    required ApiClient api,
    required WeightRepository weightRepository,
    required FoodRepository foodRepository,
  })  : _api = api,
        _weights = weightRepository,
        _foods = foodRepository;

  // ignore: unused_field — kept for parity with the eventual real client.
  final ApiClient _api;
  final WeightRepository _weights;
  final FoodRepository _foods;

  static User? _user;

  User get _state {
    final cached = _user;
    if (cached != null) return cached;
    final seed = buildSeedUser();
    _user = seed;
    return seed;
  }

  /// The current user, with derived fields filled.
  Future<User> me() async {
    await mockLatency();
    final base = _state;
    final currentKg = _weights.mostRecentKg() ?? base.currentWeightKg;
    final count = await _foods.customCount();
    return base.copyWith(
      currentWeightKg: currentKg,
      customFoodCount: count,
    );
  }

  /// Patch the user. Only the fields set on [data] are applied; nothing
  /// else changes. Returns the post-update presentation model.
  Future<User> update(UserPatch data) async {
    await mockLatency();
    var u = _state;
    if (data.displayName != null) u = u.copyWith(displayName: data.displayName);
    if (data.email != null) u = u.copyWith(email: data.email);
    if (data.sex != null) u = u.copyWith(sex: data.sex);
    if (data.birthDate != null) u = u.copyWith(birthDate: data.birthDate);
    if (data.heightCm != null) u = u.copyWith(heightCm: data.heightCm);
    if (data.activityLevel != null) {
      u = u.copyWith(activityLevel: data.activityLevel);
    }
    if (data.weightUnit != null) u = u.copyWith(weightUnit: data.weightUnit);
    u = u.copyWith(updatedAt: DateTime.now());
    _user = u;
    return me();
  }

  static void resetForTesting() {
    _user = buildSeedUser();
  }
}
