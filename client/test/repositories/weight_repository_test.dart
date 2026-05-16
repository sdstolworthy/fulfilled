import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/repositories/weight_repository.dart';

import '_harness.dart';

void main() {
  late WeightRepository repo;

  setUp(() {
    resetRepositoriesForTest();
    repo = WeightRepository(buildTestApiClient());
  });

  tearDown(teardownRepositoriesForTest);

  test('series(WeightRange.oneMonth) returns 30 points', () async {
    final series = await repo.series(WeightRange.oneMonth);
    expect(series, hasLength(30));
  });

  test('movingAvg7d is set on points from index 6 onwards', () async {
    final series = await repo.series(WeightRange.oneMonth);
    // Index 0..5: not enough predecessors → null.
    for (var i = 0; i < 6; i++) {
      expect(series[i].movingAvg7d, isNull,
          reason: 'early points cannot have a 7-day moving avg');
    }
    // Index >= 6: must have a value.
    for (var i = 6; i < series.length; i++) {
      expect(series[i].movingAvg7d, isNotNull,
          reason: 'point $i should carry a moving avg');
    }
  });

  test('history(limit: 10) returns newest-first list ≤ 10', () async {
    final history = await repo.history();
    expect(history.length <= 10, isTrue);
    // Newest-first.
    for (var i = 1; i < history.length; i++) {
      expect(
        !history[i - 1].recordedOn.isBefore(history[i].recordedOn),
        isTrue,
        reason: 'history must be newest-first',
      );
    }
  });
}
