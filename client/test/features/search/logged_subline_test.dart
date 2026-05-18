import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/features/search/widgets/search_result_row.dart';

/// F5-T4 — Table-driven coverage for `formatLoggedSubline` and the
/// underlying `_formatLoggedWhen` recency thresholds.
///
/// All cases pass an explicit [now] so the test isn't sensitive to wall
/// clock drift. Dates are local-calendar `DateTime(y, m, d)` instants —
/// the formatter uses local-calendar comparison, so DST transitions
/// don't shift the calendar-day classification.
void main() {
  // Fixed "now" — Friday May 15, 2026 at 14:00 local. Used by most
  // cases; the DST and year-rollover tests pin their own `now`.
  final friMay15 = DateTime(2026, 5, 15, 14, 0);

  group('formatLoggedSubline — recency thresholds', () {
    test('same calendar day → "Today"', () {
      final at = DateTime(2026, 5, 15, 9, 0);
      expect(
        formatLoggedSubline(at, 1, now: friMay15),
        'Logged Today',
      );
    });

    test('previous calendar day → "Yesterday"', () {
      final at = DateTime(2026, 5, 14, 22, 0);
      expect(
        formatLoggedSubline(at, 1, now: friMay15),
        'Logged Yesterday',
      );
    });

    test('2 days ago → short weekday', () {
      // May 13, 2026 is a Wednesday.
      final at = DateTime(2026, 5, 13, 9, 0);
      expect(
        formatLoggedSubline(at, 1, now: friMay15),
        'Logged Wed',
      );
    });

    test('6 days ago → short weekday (boundary inside the 7-day window)', () {
      // May 9, 2026 is a Saturday — 6 days before May 15.
      final at = DateTime(2026, 5, 9, 9, 0);
      expect(
        formatLoggedSubline(at, 1, now: friMay15),
        'Logged Sat',
      );
    });

    test('exactly 7 days ago → "MMM d" (same-year, falls out of weekday band)',
        () {
      final at = DateTime(2026, 5, 8, 9, 0);
      expect(
        formatLoggedSubline(at, 1, now: friMay15),
        'Logged May 8',
      );
    });

    test('same calendar year, > 7 days → "MMM d"', () {
      final at = DateTime(2026, 3, 4, 9, 0);
      expect(
        formatLoggedSubline(at, 1, now: friMay15),
        'Logged Mar 4',
      );
    });

    test('prior year → "MMM d, y"', () {
      final at = DateTime(2024, 5, 3, 9, 0);
      expect(
        formatLoggedSubline(at, 1, now: friMay15),
        'Logged May 3, 2024',
      );
    });
  });

  group('formatLoggedSubline — count suffix', () {
    test('logCount == 1 → no trailing "· N×"', () {
      final at = DateTime(2026, 5, 15, 9, 0);
      expect(formatLoggedSubline(at, 1, now: friMay15), 'Logged Today');
    });

    test('logCount == null → no trailing "· N×" (treated as 0)', () {
      final at = DateTime(2026, 5, 15, 9, 0);
      expect(formatLoggedSubline(at, null, now: friMay15), 'Logged Today');
    });

    test('logCount == 0 → no trailing "· N×" (defensive)', () {
      // The widget gating on `wasLoggedByCaller` should keep this branch
      // unreachable in production, but the formatter must not blow up
      // if it ever fires.
      final at = DateTime(2026, 5, 15, 9, 0);
      expect(formatLoggedSubline(at, 0, now: friMay15), 'Logged Today');
    });

    test('logCount == 2 → "Logged Today · 2×"', () {
      final at = DateTime(2026, 5, 15, 9, 0);
      expect(formatLoggedSubline(at, 2, now: friMay15), 'Logged Today · 2×');
    });

    test('logCount == 4 → "Logged Tue · 4×"', () {
      // May 12, 2026 is a Tuesday.
      final at = DateTime(2026, 5, 12, 9, 0);
      expect(
        formatLoggedSubline(at, 4, now: friMay15),
        'Logged Tue · 4×',
      );
    });

    test('logCount == 999 → "Logged Today · 999×" (boundary)', () {
      final at = DateTime(2026, 5, 15, 9, 0);
      expect(
        formatLoggedSubline(at, 999, now: friMay15),
        'Logged Today · 999×',
      );
    });

    test('logCount == 1000 → "Logged Today · 999+×" (cap)', () {
      final at = DateTime(2026, 5, 15, 9, 0);
      expect(
        formatLoggedSubline(at, 1000, now: friMay15),
        'Logged Today · 999+×',
      );
    });

    test('logCount == 2500 → "Logged Today · 999+×" (cap holds)', () {
      final at = DateTime(2026, 5, 15, 9, 0);
      expect(
        formatLoggedSubline(at, 2500, now: friMay15),
        'Logged Today · 999+×',
      );
    });
  });

  group('formatLoggedSubline — glyph correctness', () {
    test('multiplication sign is U+00D7, not letter x', () {
      final at = DateTime(2026, 5, 15, 9, 0);
      final out = formatLoggedSubline(at, 4, now: friMay15);
      expect(out, contains('×'));
      expect(out, isNot(contains(' 4x'))); // not the letter x
      expect(out, isNot(contains(' 4X')));
    });

    test('separator is a middle dot U+00B7', () {
      final at = DateTime(2026, 5, 15, 9, 0);
      final out = formatLoggedSubline(at, 4, now: friMay15);
      expect(out, contains('·'));
    });
  });

  group('formatLoggedSubline — DST spring-forward boundary', () {
    // FE plan §8 — DST case. Date-only math must not double-step across
    // a DST transition. The formatter builds `DateTime(y, m, d)` for
    // both sides of the comparison, which is timezone-agnostic (it
    // pins to the local-calendar midnight), so the case below should
    // resolve to "Yesterday" regardless of the host's tz config.
    //
    // March 8, 2026 is the US spring-forward day. The `at` instant is
    // wall-clock 22:00 the prior day (March 7); `now` is 14:00 on the
    // transition day (March 8). On a host running US time these are
    // ~17 wall-hours apart but only one calendar day apart.
    test('Mar 7 22:00 against Mar 8 14:00 resolves to "Yesterday"', () {
      final mar8 = DateTime(2026, 3, 8, 14, 0);
      final mar7 = DateTime(2026, 3, 7, 22, 0);
      expect(formatLoggedSubline(mar7, 2, now: mar8), 'Logged Yesterday · 2×');
    });

    // Symmetric case: same-day comparison straddling the transition.
    test('Mar 8 01:00 against Mar 8 14:00 resolves to "Today"', () {
      final mar8at1 = DateTime(2026, 3, 8, 1, 0);
      final mar8at14 = DateTime(2026, 3, 8, 14, 0);
      expect(formatLoggedSubline(mar8at1, 1, now: mar8at14), 'Logged Today');
    });
  });

  group('formatLoggedSubline — year rollover', () {
    test('Dec 31 prior year against Jan 2 this year → short weekday band', () {
      // Jan 2 2027 is a Saturday; Dec 31 2026 is a Thursday — within 7 days.
      final at = DateTime(2026, 12, 31, 9, 0);
      final now = DateTime(2027, 1, 2, 14, 0);
      expect(formatLoggedSubline(at, 1, now: now), 'Logged Thu');
    });

    test('Dec 31 prior year against Jan 12 this year → "MMM d, y" (prior year)',
        () {
      // 12 days apart — out of the weekday band, and the years differ,
      // so we use the explicit-year format.
      final at = DateTime(2026, 12, 31, 9, 0);
      final now = DateTime(2027, 1, 12, 14, 0);
      expect(formatLoggedSubline(at, 1, now: now), 'Logged Dec 31, 2026');
    });
  });
}
