import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/repositories/goal_repository.dart';

import '_harness.dart';

void main() {
  late GoalRepository repo;

  setUp(() {
    resetRepositoriesForTest();
    repo = GoalRepository(buildTestApiClient());
  });

  tearDown(teardownRepositoriesForTest);

  test('active() returns a goal with isActive == true', () async {
    final goal = await repo.active();
    expect(goal.isActive, isTrue);
  });

  test('all() includes both the active and the prior goal', () async {
    final goals = await repo.all();
    expect(goals.length, greaterThanOrEqualTo(2));
    expect(goals.any((g) => g.isActive), isTrue);
    expect(goals.any((g) => !g.isActive && g.endedOn != null), isTrue,
        reason: 'expected a closed-out prior goal in history');
  });
}
