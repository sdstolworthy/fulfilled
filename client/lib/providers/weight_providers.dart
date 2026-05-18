import 'package:decimal/decimal.dart';
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

/// Latest logged weight in canonical kg, or null when the user has
/// never logged a weight.
///
/// **Why this lives in `providers/` instead of on `User`.** "Current
/// weight" is a pure derivation of the weight feed; baking it onto
/// the `User` wire record forces a `meProvider` invalidate from
/// every weight write (cross-tier coupling). Reading through this
/// provider keeps the dependency arrow pointing one way: weight
/// writes invalidate weight providers; profile widgets re-derive
/// via `ref.watch` on the next paint.
///
/// Consumers: profile identity row, current-weight sheet seed,
/// goal editor's calorie-estimator inputs, target-weight stepper
/// seed, prereq-fields check.
final currentWeightKgProvider = FutureProvider<Decimal?>((ref) async {
  final entries = await ref.watch(weightHistoryProvider.future);
  if (entries.isEmpty) return null;
  // `weightHistoryProvider` returns newest-first, so index 0 is
  // the latest log.
  return entries.first.weightKg;
});
