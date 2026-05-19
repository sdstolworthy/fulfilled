// MOCK ONLY — deletable with the rest of the seed fixtures.

import 'package:decimal/decimal.dart';

import '../domain/goal.dart';
import '_clock.dart';

const String mockActiveGoalId = 'g_active_lose';

Goal buildSeedActiveGoal() {
  return Goal(
    id: mockActiveGoalId,
    startedOn: daysAgo(60),
    endedOn: null,
    startWeightKg: dec('82.4'),
    targetWeightKg: dec('76.0'),
    weeklyRateKg: dec('-0.5'),
    dailyCalorieTarget: 2150,
    proteinTargetG: dec('165'),
    carbsTargetG: dec('215'),
    fatTargetG: dec('70'),
    isActive: true,
    createdAt: daysAgo(60).add(const Duration(hours: 9)),
    updatedAt: daysAgo(60).add(const Duration(hours: 9)),
  );
}

Goal buildSeedPreviousGoal() {
  return Goal(
    id: 'g_prior_maintain',
    startedOn: daysAgo(180),
    endedOn: daysAgo(61),
    startWeightKg: dec('80.0'),
    targetWeightKg: dec('80.0'),
    weeklyRateKg: Decimal.zero,
    dailyCalorieTarget: 2400,
    proteinTargetG: dec('150'),
    carbsTargetG: dec('260'),
    fatTargetG: dec('80'),
    isActive: false,
    createdAt: daysAgo(180).add(const Duration(hours: 9)),
    updatedAt: daysAgo(61).add(const Duration(hours: 9)),
  );
}
