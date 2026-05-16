import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/user.dart';
import 'repository_providers.dart';

/// Profile-domain provider — just one read: [meProvider]. Screen 08
/// (Profile / You) and onboarding step 2's pre-fill bind here.
///
/// **Derived fields.** `User.currentWeightKg` is filled from the most
/// recent weight entry; `User.customFoodCount` is filled from the food
/// repository. After mutations to either, screens should
/// `ref.invalidate(meProvider)` so the derived fields refresh.

/// Current user, with derived fields.
final meProvider = FutureProvider<User>((ref) {
  final repo = ref.watch(profileRepositoryProvider);
  return repo.me();
});
