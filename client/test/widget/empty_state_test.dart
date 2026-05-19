import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/theme/context_extensions.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/theme/tokens.dart';
import 'package:fulfilled/widgets/empty_state.dart';

/// T-003 — `EmptyState` primitive.
///
/// The tests cover the acceptance criteria:
/// - icon + title + body render
/// - optional action renders when provided
/// - rendered colors come from `AppTokens` (no raw hex anywhere — the
///   color is read from `context.colors.ink3` and matched by value)
Widget _harness(Widget child) {
  return MaterialApp(
    theme: buildLightTheme(),
    home: Scaffold(body: child),
  );
}

void main() {
  testWidgets('renders icon, title, body without action', (tester) async {
    await tester.pumpWidget(
      _harness(
        const EmptyState(
          icon: Icons.search_off,
          title: 'No matches',
          body: 'No foods match your query.',
        ),
      ),
    );

    expect(find.byIcon(Icons.search_off), findsOneWidget);
    expect(find.text('No matches'), findsOneWidget);
    expect(find.text('No foods match your query.'), findsOneWidget);
  });

  testWidgets('renders action slot when provided', (tester) async {
    await tester.pumpWidget(
      _harness(
        EmptyState(
          icon: Icons.restaurant,
          title: 'Nothing logged yet',
          body: 'Tap the plus to log your first food.',
          action: FilledButton(
            onPressed: () {},
            child: const Text('Log first food'),
          ),
        ),
      ),
    );

    expect(find.text('Log first food'), findsOneWidget);
  });

  testWidgets('icon uses ink3 token (no raw hex in widget)', (tester) async {
    Color? captured;
    await tester.pumpWidget(
      _harness(
        Builder(builder: (context) {
          captured = context.colors.ink3;
          return const EmptyState(
            icon: Icons.search_off,
            title: 'Empty',
            body: 'Body',
          );
        },),
      ),
    );

    final iconWidget = tester.widget<Icon>(find.byIcon(Icons.search_off));
    expect(iconWidget.color, equals(captured));
    expect(captured, equals(AppColors.light.ink3));
  });

  // T-013 — both the title and body strings must be present in the
  // semantics tree. The widget doesn't wrap itself in a single
  // `Semantics` node so the visible labels propagate via Flutter's
  // default text-semantics. A regression that swaps either to an
  // `ExcludeSemantics` would fail this.
  testWidgets('semantics tree exposes both title and body', (tester) async {
    await tester.pumpWidget(
      _harness(
        const EmptyState(
          icon: Icons.search_off,
          title: 'No matches',
          body: 'No foods match your query.',
        ),
      ),
    );

    expect(find.bySemanticsLabel('No matches'), findsOneWidget);
    expect(find.bySemanticsLabel('No foods match your query.'), findsOneWidget);
  });
}
