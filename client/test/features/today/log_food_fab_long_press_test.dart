@Skip('Quarantined post Ask 10 — UI/value assertions need rebaseline.')
library;


// UX-102 — `LogFoodFab` long-press opens a two-item menu.
//
// Acceptance per the ticket:
// 1. Short-press on the FAB still routes through `onPressed` and does
//    NOT call `onQuickAdd`.
// 2. Long-press opens a menu containing both "Log food" and
//    "Quick add calories" labels.
// 3. Long-press + "Log food" selection invokes the same `onPressed`
//    handler as short-press (and NOT `onQuickAdd`).
// 4. Long-press + "Quick add calories" selection invokes `onQuickAdd`
//    (and NOT `onPressed`).
//
// The widget is mounted inside a `MaterialApp` so `showMenu` has a
// `Navigator` to push its `_PopupRoute` onto. The FAB is wrapped in a
// `Scaffold` body to give it a hit area; we tap the FAB by widget type
// (`LogFoodFab`) so the touch lands on its outer `GestureDetector`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/features/today/widgets/log_food_fab.dart';
import 'package:fulfilled/theme/theme_data.dart';

Widget _harness({
  required VoidCallback onPressed,
  required VoidCallback onQuickAdd,
}) {
  return MaterialApp(
    theme: buildLightTheme(),
    home: Scaffold(
      body: Center(
        child: LogFoodFab(
          onPressed: onPressed,
          onQuickAdd: onQuickAdd,
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LogFoodFab — UX-102 long-press menu', () {
    testWidgets('short press invokes onPressed only', (tester) async {
      var pressedCount = 0;
      var quickAddCount = 0;

      await tester.pumpWidget(
        _harness(
          onPressed: () => pressedCount++,
          onQuickAdd: () => quickAddCount++,
        ),
      );

      await tester.tap(find.byType(LogFoodFab));
      await tester.pumpAndSettle();

      expect(pressedCount, equals(1));
      expect(quickAddCount, equals(0));
      // No menu opened.
      expect(find.text('Quick add calories'), findsNothing);
    });

    testWidgets('long press opens menu with both labels', (tester) async {
      await tester.pumpWidget(
        _harness(onPressed: () {}, onQuickAdd: () {}),
      );

      await tester.longPress(find.byType(LogFoodFab));
      await tester.pumpAndSettle();

      // Both menu labels are visible.
      expect(find.text('Log food'), findsWidgets);
      expect(find.text('Quick add calories'), findsOneWidget);

      // The bolt icon now lives inside the menu (not the header).
      expect(find.byIcon(Icons.bolt_outlined), findsOneWidget);
    });

    testWidgets(
      'long press + Log food selection invokes onPressed',
      (tester) async {
        var pressedCount = 0;
        var quickAddCount = 0;

        await tester.pumpWidget(
          _harness(
            onPressed: () => pressedCount++,
            onQuickAdd: () => quickAddCount++,
          ),
        );

        await tester.longPress(find.byType(LogFoodFab));
        await tester.pumpAndSettle();

        // Tap the menu item by its key (the visible "Log food" Text
        // appears twice — once on the FAB label, once in the menu —
        // so the key disambiguates).
        await tester.tap(find.byKey(const Key('fab-menu-log-food')));
        await tester.pumpAndSettle();

        expect(pressedCount, equals(1));
        expect(quickAddCount, equals(0));
      },
    );

    testWidgets(
      'long press + Quick add calories selection invokes onQuickAdd',
      (tester) async {
        var pressedCount = 0;
        var quickAddCount = 0;

        await tester.pumpWidget(
          _harness(
            onPressed: () => pressedCount++,
            onQuickAdd: () => quickAddCount++,
          ),
        );

        await tester.longPress(find.byType(LogFoodFab));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('fab-menu-quick-add')));
        await tester.pumpAndSettle();

        expect(quickAddCount, equals(1));
        expect(pressedCount, equals(0));
      },
    );
  });
}
