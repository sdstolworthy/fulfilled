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
      completer.completeError(_DebounceCancelled());
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
