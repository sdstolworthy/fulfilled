// MOCK ONLY — this file is deletable once the real API is wired.
//
// Simulated network latency for the mock repository methods. The real
// repositories will replace these awaits with `dio.get(...)` etc.; the
// timing here exists so screens can exercise their skeleton/loading
// states (T-08) instead of receiving data synchronously.
//
// Range 80–250 ms is the spec — fast enough that the user perceives the
// app as responsive, slow enough that a `FutureProvider` actually emits
// `AsyncLoading` before resolving.

import 'dart:math';

final Random _rng = Random(0xC0FFEE); // Deterministic across rebuilds.

bool _testing = false;
int _testMin = 0;
int _testMax = 1;

/// Wait a small, jittered amount before returning. The repository method
/// pattern is:
///
/// ```dart
/// Future<List<Food>> recent({int limit = 8}) async {
///   await mockLatency();
///   return _state.snapshotFoods().where(...).toList();
/// }
/// ```
Future<void> mockLatency({int minMs = 80, int maxMs = 250}) async {
  final lo = _testing ? _testMin : minMs;
  final hi = _testing ? _testMax : maxMs;
  final delta = hi - lo;
  final ms = lo + (delta <= 0 ? 0 : _rng.nextInt(delta));
  if (ms <= 0) {
    // Yield to the microtask queue even for zero — gives `FutureProvider`
    // a tick to emit the loading state.
    await Future<void>.delayed(Duration.zero);
  } else {
    await Future<void>.delayed(Duration(milliseconds: ms));
  }
}

/// Force a deterministic latency in tests. The default jitter would make
/// assertions flaky; this knocks it down to (typically) 0–1 ms. Tests
/// should call this once in `setUp` and [clearMockLatencyForTesting] in
/// `tearDown` for cleanliness.
void setMockLatencyForTesting({int minMs = 0, int maxMs = 1}) {
  _testMin = minMs;
  _testMax = maxMs;
  _testing = true;
}

void clearMockLatencyForTesting() {
  _testing = false;
}
