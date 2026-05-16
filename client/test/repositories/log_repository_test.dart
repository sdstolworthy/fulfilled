import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/repositories/food_repository.dart';
import 'package:fulfilled/repositories/goal_repository.dart';
import 'package:fulfilled/repositories/log_repository.dart';
import 'package:fulfilled/repositories/_fixtures.dart';

import '_harness.dart';

void main() {
  late LogRepository repo;

  setUp(() {
    resetRepositoriesForTest();
    final api = buildTestApiClient();
    repo = LogRepository(
      api: api,
      foodRepository: FoodRepository(api),
      goalRepository: GoalRepository(api),
    );
  });

  tearDown(teardownRepositoriesForTest);

  test('daySummary(today).kcal > 0', () async {
    final summary = await repo.daySummary(mockToday());
    expect(summary.kcal > Decimal.zero, isTrue,
        reason: 'today is seeded with all four meals');
  });

  test('entriesForDate(today) returns at least one entry', () async {
    final entries = await repo.entriesForDate(mockToday());
    expect(entries, isNotEmpty);
  });

  test('daySummary(today) lifts kcal target from active goal', () async {
    final summary = await repo.daySummary(mockToday());
    expect(summary.kcalTarget, isNotNull,
        reason: 'seed includes an active goal with daily_calorie_target');
  });
}
