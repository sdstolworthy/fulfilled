import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/calorie_ring.dart';

/// T-001 — `CalorieRing` lifted to `lib/widgets/`.
///
/// Covers the acceptance criteria from the ticket:
/// - default render: center label, caption (uppercased), semantics label
/// - over-budget render: caption flips to "over", semantics composes
///   correctly when `consumed > goal`
///
/// We don't peek inside the `CustomPainter` — the colors-from-tokens
/// invariant is enforced by the absence of raw hex in the widget source
/// (T-01), and the rendered Text widgets are how we observe the public
/// surface.

Widget _harness(Widget child) {
  return MaterialApp(
    theme: buildLightTheme(),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  testWidgets('renders center label + uppercased caption (default)',
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

    expect(find.text('812'), findsOneWidget);
    // The widget uppercases the caption itself.
    expect(find.text('LEFT'), findsOneWidget);
    // Semantics label composes the original-case caption with " kcal ".
    expect(
      find.bySemanticsLabel('812 kcal left'),
      findsOneWidget,
    );
  });

  testWidgets('renders over-budget center + caption when overBudget=true',
      (tester) async {
    await tester.pumpWidget(
      _harness(
        const CalorieRing(
          progress: 1.4,
          overBudget: true,
          centerLabel: '-123',
          centerCaption: 'over',
        ),
      ),
    );

    expect(find.text('-123'), findsOneWidget);
    expect(find.text('OVER'), findsOneWidget);
    expect(
      find.bySemanticsLabel('-123 kcal over'),
      findsOneWidget,
    );
  });

  testWidgets('respects the size prop for the outer SizedBox',
      (tester) async {
    await tester.pumpWidget(
      _harness(
        const CalorieRing(
          progress: 0.0,
          overBudget: false,
          centerLabel: '0',
          centerCaption: 'eaten',
          size: 108,
        ),
      ),
    );

    final box = tester.widget<SizedBox>(
      find
          .descendant(
            of: find.byType(CalorieRing),
            matching: find.byType(SizedBox),
          )
          .first,
    );
    expect(box.width, 108);
    expect(box.height, 108);
  });
}
