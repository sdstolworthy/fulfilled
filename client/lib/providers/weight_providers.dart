import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/enums.dart';
import '../domain/weight.dart';
import 'repository_providers.dart';

/// Weight-domain providers. Screen 06 (weight chart + history) and the
/// profile identity row (screen 08) bind here.
///
/// **Moving-avg gotcha (architect §9 screen 06).** Each
/// [WeightSeriesPoint] returned by [weightSeriesProvider] carries an
/// optional `movingAvg7d` field. The first six points in the underlying
/// (unfiltered) history have it `null` — six predecessors are required.
/// When the chart renders a "Trend" line, draw only the suffix where
/// `movingAvg7d != null`.

/// Series for the chart, family-keyed by [WeightRange]. Returns
/// ascending-by-date points filtered to the range; moving averages are
/// computed over the full history so the first point in a range still
/// has a meaningful trend value (as long as it isn't one of the first
/// six entries overall).
final weightSeriesProvider =
    FutureProvider.family<List<WeightSeriesPoint>, WeightRange>(
        (ref, range) {
  final repo = ref.watch(weightRepositoryProvider);
  return repo.series(range);
});

/// Newest-first list of raw weight entries. Drives screen 06's "Recent
/// entries" list. Limit defaults to the repository's default of 10.
final weightHistoryProvider = FutureProvider<List<WeightEntry>>((ref) {
  final repo = ref.watch(weightRepositoryProvider);
  return repo.history();
});
