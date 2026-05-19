// MOCK ONLY — deletable with the rest of the seed fixtures.
//
// Audit-fix F3 (clock half): the `_clockOverride` global + the
// `setMockClockForTesting` setter used to live here so tests could pin
// "today" before constructing seed data. No test ever actually did
// pin it — every call site was `setMockClockForTesting(null)` in
// `tearDown`, resetting state that was never set. The audit's
// concern was real (top-level mutable, state-leak across tests) but
// the fix isn't injection-into-every-repository; it's deleting the
// unused machinery. If a future test actually needs to pin time, the
// cleanest reintroduction is a `Zone` override (lexically scoped, no
// shared mutable), not a top-level setter.
//
// Latency monkey-patch in `_mock_latency.dart` is a separate concern
// — see TODO there.

import 'package:decimal/decimal.dart';

/// `n` days before today (local-midnight), used by seed-data builders
/// to time-stamp foods/logs/weights at deterministic offsets from
/// "now". Public so each per-domain fixture file can share it.
DateTime daysAgo(int days) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day - days);
}

/// `n` days before today, at the given local hour/minute. Same
/// rationale as [daysAgo].
DateTime dayAt(int days, int hour, int minute) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day - days, hour, minute);
}

/// `Decimal.parse(v)` — a one-character shorthand made common enough
/// by the seed-data builders that even reaching into rust_decimal
/// directly would be wire noise. Public so each split file can use
/// it without redeclaring.
Decimal dec(String v) => Decimal.parse(v);
