// QL-105 — Unit test for the `pathForDay` helper.
//
// `pathForDay` is the canonical date-to-path map shared by the day-view
// chevrons (`navigateDay`) and the log-save router (T-24 Case 2). The
// rules are:
//   • Today's local calendar date → `/today` (the bare path).
//   • Any other date → `/today/$y-$m-$d` with zero-padded fields.
//
// Architect §6.1 / dev ticket QL-105 acceptance criteria. Tests cover
// today + a backdate + a future date + the zero-padding edge case.

import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/features/today/today_internals.dart';
import 'package:fulfilled/routing/routes.dart';

void main() {
  group('pathForDay', () {
    test('today (DateTime.now) resolves to the bare /today path', () {
      // The "today" branch is keyed off `DateTime.now()` inside the
      // helper. We mirror the comparison here so the test is robust
      // against running across midnight: the assertion is "whatever
      // today is right now, that should map to `Routes.todayPath`."
      final now = DateTime.now();
      expect(pathForDay(now), equals(Routes.todayPath));
      expect(pathForDay(now), equals('/today'));
    });

    test('today with non-midnight clock fields still resolves to /today', () {
      // `pathForDay` does a Y/M/D comparison against `DateTime.now()`;
      // hour/minute fields are immaterial. Construct a DateTime for the
      // same calendar day with a 23:59 clock and assert the bare path.
      final now = DateTime.now();
      final lateToday = DateTime(now.year, now.month, now.day, 23, 59);
      expect(pathForDay(lateToday), equals(Routes.todayPath));
    });

    test('yesterday resolves to /today/YYYY-MM-DD', () {
      // Compute yesterday off `now` so the test is calendar-stable.
      final now = DateTime.now();
      final yesterday =
          DateTime(now.year, now.month, now.day).subtract(const Duration(days: 1));
      final y = yesterday.year.toString().padLeft(4, '0');
      final m = yesterday.month.toString().padLeft(2, '0');
      final d = yesterday.day.toString().padLeft(2, '0');
      expect(pathForDay(yesterday), equals('/today/$y-$m-$d'));
    });

    test('a future date resolves to /today/YYYY-MM-DD', () {
      // 2099-12-31 is unambiguously not today; assert the literal path.
      expect(pathForDay(DateTime(2099, 12, 31)), equals('/today/2099-12-31'));
    });

    test('zero-pads single-digit month and day', () {
      // 2026-01-01 — the canonical zero-padding case. The DateTime
      // constructor accepts `1, 1` but the path string must be
      // `01-01`, not `1-1`. Belt-and-braces against a regression that
      // drops the `padLeft` calls.
      expect(pathForDay(DateTime(2026, 1, 1)), equals('/today/2026-01-01'));
      expect(pathForDay(DateTime(2026, 3, 9)), equals('/today/2026-03-09'));
    });
  });
}
