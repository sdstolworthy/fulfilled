// MOCK ONLY — deletable with the rest of the seed fixtures.
//
// Audit-fix F2: the clock + simple Decimal helper used to live in a
// 1300-line god-module alongside seed data for five domains. A weight
// test that pinned time leaked into goal / food / log seeds. Splitting
// out this small file lets each per-domain fixture file import only
// what it needs, and gives the eventual clock-injection refactor (F3)
// a single seam to retarget.

import 'package:decimal/decimal.dart';

/// Test-controllable clock. Top-level mutable for now — F3 will lift
/// this into an explicit constructor parameter on each fixture
/// builder so tests no longer reach into a shared global to pin time.
DateTime Function()? _clockOverride;

DateTime mockNow() => (_clockOverride ?? DateTime.now)();

DateTime mockToday() {
  final n = mockNow();
  return DateTime(n.year, n.month, n.day);
}

void setMockClockForTesting(DateTime Function()? clock) {
  _clockOverride = clock;
}

/// `n` days before [mockToday], at 00:00:00 local. Public so each
/// per-domain fixture file can share it without a library-private
/// duplicate.
DateTime daysAgo(int days) {
  final t = mockToday();
  return DateTime(t.year, t.month, t.day - days);
}

/// `n` days before [mockToday], at the given local hour/minute. Same
/// public rationale as [daysAgo].
DateTime dayAt(int days, int hour, int minute) {
  final t = mockToday();
  return DateTime(t.year, t.month, t.day - days, hour, minute);
}

/// `Decimal.parse(v)` — a one-character shorthand made common enough
/// by the seed-data builders that even reaching into rust_decimal
/// directly would be wire noise. Public so each split file can use
/// it without redeclaring.
Decimal dec(String v) => Decimal.parse(v);
