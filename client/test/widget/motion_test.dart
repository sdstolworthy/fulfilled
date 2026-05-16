import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/widgets/motion.dart';

/// T-016 — `motion(context, full)` helper.
///
/// Covers the architect's reduced-motion invariant: every animation
/// duration in the app routes through this helper, and when the
/// `MediaQuery.disableAnimations` flag is true the duration collapses
/// to `Duration.zero` (so animations resolve on the first frame).

void main() {
  testWidgets('returns the full duration when disableAnimations is false',
      (tester) async {
    Duration? captured;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(),
        child: Builder(
          builder: (context) {
            captured = motion(context, const Duration(milliseconds: 400));
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(captured, const Duration(milliseconds: 400));
  });

  testWidgets('collapses to Duration.zero when disableAnimations is true',
      (tester) async {
    Duration? captured;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Builder(
          builder: (context) {
            captured = motion(context, const Duration(milliseconds: 600));
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(captured, Duration.zero);
  });

  testWidgets('collapses even when full is zero (idempotent)',
      (tester) async {
    Duration? captured;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Builder(
          builder: (context) {
            captured = motion(context, Duration.zero);
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(captured, Duration.zero);
  });
}
