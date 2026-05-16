import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/calorie_ring.dart';

/// T-016 — `CalorieRing` animation polish.
///
/// Extends the T-001 lift test with the two T-016 invariants:
/// - A `TweenAnimationBuilder<double>` is present in the tree (the arc
///   sweep is driven by the tween, not a snap).
/// - When `MediaQuery.disableAnimations` is true the rendered progress
///   resolves to the target on the first frame — no further pumps
///   should change the value (i.e. duration collapses to zero per the
///   `motion()` helper).

Widget _harness(Widget child, {bool disableAnimations = false}) {
  return MaterialApp(
    theme: buildLightTheme(),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Scaffold(body: Center(child: child)),
    ),
  );
}

void main() {
  testWidgets('TweenAnimationBuilder<double> is present in the tree',
      (tester) async {
    await tester.pumpWidget(
      _harness(
        const CalorieRing(
          progress: 0.6,
          overBudget: false,
          centerLabel: '812',
          centerCaption: 'left',
        ),
      ),
    );

    expect(
      find.descendant(
        of: find.byType(CalorieRing),
        matching: find.byType(TweenAnimationBuilder<double>),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
      'with disableAnimations=true the arc tween resolves on the first frame',
      (tester) async {
    await tester.pumpWidget(
      _harness(
        const CalorieRing(
          progress: 0.75,
          overBudget: false,
          centerLabel: '500',
          centerCaption: 'left',
        ),
        disableAnimations: true,
      ),
    );

    // Locate the inner tween and read its evaluated value. With duration
    // zero the builder's `value` argument equals the tween's `end` from
    // the first frame onward — no pumpAndSettle needed.
    final tween = tester.widget<TweenAnimationBuilder<double>>(
      find.byType(TweenAnimationBuilder<double>),
    );
    expect(tween.duration, Duration.zero);
    expect(tween.tween.end, 0.75);
  });

  testWidgets(
      'with disableAnimations=false the tween duration is non-zero',
      (tester) async {
    await tester.pumpWidget(
      _harness(
        const CalorieRing(
          progress: 0.4,
          overBudget: false,
          centerLabel: '600',
          centerCaption: 'left',
        ),
      ),
    );

    final tween = tester.widget<TweenAnimationBuilder<double>>(
      find.byType(TweenAnimationBuilder<double>),
    );
    expect(tween.duration, greaterThan(Duration.zero));
  });
}
