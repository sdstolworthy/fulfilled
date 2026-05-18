import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/food.dart';
import 'repository_providers.dart';

/// Food-domain providers. Screen agents bind to these directly.
///
/// **Debounce contract for [foodSearchProvider].** Screen 02 was told to
/// "debounce in the provider, not in the widget." This file implements
/// that — the family provider waits 250 ms after the latest query
/// argument before hitting the repository. A new query that arrives
/// during the wait cancels the in-flight delay.
///
/// Riverpod's `family` re-creates the provider per key, so the debounce
/// works by leaning on Riverpod's `Future.delayed` plus `ref.onDispose`.
/// Each keystroke watches a *different* family key — the prior key
/// disposes immediately, cancelling its pending delay via the dispose
/// hook. Result: a typing user sees one repository call per pause.

/// Most recently logged foods. Drives the right-rail Quick add card on
/// screen 01-W and the Recent section on screen 02.
final recentFoodsProvider = FutureProvider<List<Food>>((ref) {
  final repo = ref.watch(foodRepositoryProvider);
  return repo.recent();
});

/// Most frequently logged foods. Drives the Frequent section on screen 02.
final frequentFoodsProvider = FutureProvider<List<Food>>((ref) {
  final repo = ref.watch(foodRepositoryProvider);
  return repo.frequent();
});

/// Full food detail (with servings + per-100 g nutrition). Screen 03 and
/// the log-entry sheet (screen 04) both bind to this. Cached per id.
final foodDetailProvider =
    FutureProvider.family<Food, String>((ref, foodId) {
  final repo = ref.watch(foodRepositoryProvider);
  return repo.get(foodId);
});

/// Count of `source == user` foods owned by the caller. Drives the
/// "My foods · N" row on screen 08.
final customFoodCountProvider = FutureProvider<int>((ref) {
  final repo = ref.watch(foodRepositoryProvider);
  return repo.customCount();
});

/// Every `source == user` food owned by the caller. Drives the My foods
/// list screen at `/foods/mine` (T-006). The screen reads this provider
/// directly and applies its in-list filter locally so the per-keystroke
/// `String.contains` never round-trips through the repository.
final myFoodsProvider = FutureProvider<List<Food>>((ref) {
  final repo = ref.watch(foodRepositoryProvider);
  return repo.customFoods();
});

/// Debounced search. Returns an empty list for empty / whitespace
/// queries (avoids a "0 results" flash on first focus). The 250 ms
/// debounce lives in the provider, not the widget — see file docstring.
///
/// **How it works.** Each rebuild of the calling widget watches the
/// family with the latest query; Riverpod re-instantiates the provider
/// with the new key. The new key starts a 250 ms timer; if a newer key
/// supersedes it before the timer fires, `ref.onDispose` cancels the
/// timer and the repository never sees the abandoned query.
final foodSearchProvider =
    FutureProvider.family<List<Food>, String>((ref, query) async {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return const <Food>[];

  // Debounce — wait, but bail if the family key is disposed in the
  // meantime (i.e. another keystroke arrived).
  final completer = Completer<void>();
  final timer = Timer(const Duration(milliseconds: 250), () {
    if (!completer.isCompleted) completer.complete();
  });
  ref.onDispose(() {
    timer.cancel();
    if (!completer.isCompleted) {
      completer.completeError(const _DebounceCancelled());
    }
  });

  try {
    await completer.future;
  } on _DebounceCancelled {
    return const <Food>[];
  }

  // Survived the debounce window — run the search.
  final repo = ref.watch(foodRepositoryProvider);
  return repo.search(trimmed);
});

class _DebounceCancelled implements Exception {
  const _DebounceCancelled();
}

/// Page size shared between [foodSearchProvider] (first page) and
/// [foodSearchPaginationProvider] (subsequent pages). 25 matches the
/// `limit:` default on `FoodRepository.search`.
const int kFoodSearchPageSize = 25;

/// Additional pages of results for a given search query. The first
/// page lives in [foodSearchProvider]; this notifier owns every page
/// after that. The widget concatenates `firstPage + extraItems` when
/// rendering the list.
///
/// Pagination uses offset-based paging against `/foods/search`. A page
/// that returns fewer rows than [kFoodSearchPageSize] means we've hit
/// the end of the result set, and [hasMore] flips to `false`.
///
/// The notifier is keyed by the *trimmed* query so a leading/trailing
/// whitespace edit doesn't allocate a fresh paginator. New queries
/// start with an empty extra list because Riverpod's family
/// re-instantiates the notifier per key.
class FoodSearchPaginationNotifier
    extends StateNotifier<FoodSearchPaginationState> {
  FoodSearchPaginationNotifier({
    required this.query,
    required this.ref,
  }) : super(FoodSearchPaginationState.initial);

  final String query;
  final Ref ref;

  /// Call once the first page has landed in [foodSearchProvider]. The
  /// pagination state mirrors "did the first page hit the page-size
  /// ceiling" — if it didn't, no more pages exist and load-more taps
  /// short-circuit. Idempotent within a given query key.
  void seedFromFirstPage(int firstPageLength) {
    final hasMore = firstPageLength >= kFoodSearchPageSize;
    if (state.hasMore == hasMore && state.seeded) return;
    state = state.copyWith(hasMore: hasMore, seeded: true);
  }

  /// Fetch the next page. [currentTotal] is the count of rows already
  /// displayed (first page + any previously appended extras) and is
  /// used as the offset. No-op when a fetch is already in flight or
  /// when the prior page told us there's nothing more to load.
  Future<void> loadMore({required int currentTotal}) async {
    if (state.isLoadingMore || !state.hasMore) return;
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;

    state = state.copyWith(isLoadingMore: true);
    try {
      final repo = ref.read(foodRepositoryProvider);
      final next = await repo.search(
        trimmed,
        limit: kFoodSearchPageSize,
        offset: currentTotal,
      );
      // Guard against late returns after the notifier is disposed
      // (typing kept going; the family rebuilt under a new key).
      if (!mounted) return;
      state = state.copyWith(
        extra: <Food>[...state.extra, ...next],
        hasMore: next.length >= kFoodSearchPageSize,
        isLoadingMore: false,
      );
    } catch (_) {
      if (!mounted) return;
      // Swallow — the user can scroll again to retry. The page count
      // and `hasMore` are unchanged so a retry hits the same offset.
      state = state.copyWith(isLoadingMore: false);
    }
  }
}

class FoodSearchPaginationState {
  const FoodSearchPaginationState({
    required this.extra,
    required this.hasMore,
    required this.isLoadingMore,
    required this.seeded,
  });

  /// Pages beyond the first. Empty until [FoodSearchPaginationNotifier.loadMore]
  /// resolves successfully at least once.
  final List<Food> extra;

  /// `true` while we believe more results exist on the server.
  /// Flipped to `false` when a page returns fewer rows than
  /// [kFoodSearchPageSize], or once `seedFromFirstPage` reports a
  /// short first page.
  final bool hasMore;

  /// `true` while a `loadMore()` is in flight. The widget renders a
  /// trailing spinner row while this is true.
  final bool isLoadingMore;

  /// `true` once [FoodSearchPaginationNotifier.seedFromFirstPage] has
  /// been called for this query key. Distinguishes "we haven't seen
  /// the first page yet" (default `hasMore: true`) from "first page
  /// reported short" (`hasMore: false`).
  final bool seeded;

  static const FoodSearchPaginationState initial = FoodSearchPaginationState(
    extra: <Food>[],
    hasMore: true,
    isLoadingMore: false,
    seeded: false,
  );

  FoodSearchPaginationState copyWith({
    List<Food>? extra,
    bool? hasMore,
    bool? isLoadingMore,
    bool? seeded,
  }) =>
      FoodSearchPaginationState(
        extra: extra ?? this.extra,
        hasMore: hasMore ?? this.hasMore,
        isLoadingMore: isLoadingMore ?? this.isLoadingMore,
        seeded: seeded ?? this.seeded,
      );
}

final foodSearchPaginationProvider = StateNotifierProvider.family<
    FoodSearchPaginationNotifier,
    FoodSearchPaginationState,
    String>(
  (ref, query) =>
      FoodSearchPaginationNotifier(query: query, ref: ref),
);
