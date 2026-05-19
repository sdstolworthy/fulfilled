// MOCK ONLY — deletable with the rest of the seed fixtures.

import '../domain/enums.dart';
import '../domain/user.dart';
import '_clock.dart';

const String mockUserId = 'u_sam_reyes';

User buildSeedUser({
  WeightUnit weightUnit = WeightUnit.kg,
}) {
  return User(
    id: mockUserId,
    displayName: 'Sam Reyes',
    email: 'sam@example.com',
    sex: Sex.male,
    birthDate: DateTime(1993, 4, 12),
    heightCm: dec('178'),
    activityLevel: ActivityLevel.moderate,
    createdAt: DateTime(2026, 1, 5, 9, 0),
    updatedAt: DateTime(2026, 5, 12, 8, 30),
    weightUnit: weightUnit,
  );
}
