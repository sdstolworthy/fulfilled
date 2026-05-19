// MOCK ONLY — deletable with the rest of the seed fixtures.

import 'package:decimal/decimal.dart';

import '../domain/weight.dart';
import '_clock.dart';

List<WeightEntry> buildSeedWeights() {
  final out = <WeightEntry>[];
  const samples = <double>[
    82.1, 82.0, 81.9, 82.1, 81.8, 81.7, 81.5,
    81.6, 81.4, 81.2, 81.0, 81.1, 80.9, 80.8,
    80.7, 80.5, 80.6, 80.4, 80.3, 80.1, 80.2,
    80.0, 79.8, 79.9, 79.7, 79.6, 79.5, 79.6, 79.4, 79.4,
  ];
  for (var i = 0; i < samples.length; i++) {
    final dayOffset = samples.length - 1 - i;
    final date = daysAgo(dayOffset);
    out.add(
      WeightEntry(
        id: 'w_$i',
        recordedOn: date,
        recordedAtLocal: '07:30:00',
        weightKg: Decimal.parse(samples[i].toStringAsFixed(1)),
        createdAt: date.add(const Duration(hours: 7, minutes: 31)),
      ),
    );
  }
  return out;
}

List<WeightSeriesPoint> buildWeightSeries(List<WeightEntry> entries) {
  final sorted = <WeightEntry>[...entries]
    ..sort((a, b) => a.recordedOn.compareTo(b.recordedOn));
  final out = <WeightSeriesPoint>[];
  for (var i = 0; i < sorted.length; i++) {
    Decimal? avg;
    if (i >= 6) {
      var sum = Decimal.zero;
      for (var j = i - 6; j <= i; j++) {
        sum = sum + sorted[j].weightKg;
      }
      avg = (sum / Decimal.fromInt(7))
          .toDecimal(scaleOnInfinitePrecision: 4);
    }
    out.add(
      WeightSeriesPoint(
        date: sorted[i].recordedOn,
        weightKg: sorted[i].weightKg,
        movingAvg7d: avg,
      ),
    );
  }
  return out;
}
