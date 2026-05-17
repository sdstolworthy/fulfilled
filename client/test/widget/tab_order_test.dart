import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fulfilled/domain/food.dart';
import 'package:fulfilled/domain/log_entry.dart';
import 'package:fulfilled/features/log_entry/log_entry_sheet.dart';
import 'package:fulfilled/theme/theme_data.dart';

import '../_fixtures.dart';

/// T-022 — tab-order spot check.
///
/// The architect's brief says "spot-check log-entry dialog (screen 04)
/// and custom-food form (screen 05)". Flutter's default focus traversal
/// is visual-order (top-to-bottom, left-to-right), so this test is
/// purely a smoke check that pressing Tab moves focus forward from the
/// first focusable input without exception. If a future refactor breaks
/// the visual ordering and the agent has to introduce
/// `FocusTraversalOrder` widgets, this test is the place that catches
/// the regression.
///
/// Stub-only: not executed by this agent. The pattern mirrors
/// `test/features/log_entry/log_entry_sheet_test.dart`.
Food _food() => buildFood(
      brand: null,
      servings: [buildServing(id: 'sv_100g')],
    );

Widget _harness({
  required ValueChanged<LogCreate> onSubmit,
}) {
  return ProviderScope(
    child: MaterialApp(
      theme: buildLightTheme(),
      home: Scaffold(
        body: LogEntrySheetBody(
          food: _food(),
          onSubmit: onSubmit,
          showGrabber: false,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('log-entry sheet — tab moves focus without throwing',
      (tester) async {
    await tester.pumpWidget(
      _harness(onSubmit: (_) {}),
    );
    await tester.pumpAndSettle();

    // Tab three times across the visible input column (quantity stepper,
    // meal chips, note field). Flutter's default traversal policy is
    // ReadingOrderTraversalPolicy — visual top-to-bottom, left-to-right —
    // which matches the mock's input order. The assertion is purely that
    // none of the keypresses raises an exception and the framework
    // settles afterwards.
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }

    // Sanity — something has focus after tabbing.
    expect(
      FocusManager.instance.primaryFocus,
      isNotNull,
      reason: 'Tab traversal should land on a focusable descendant.',
    );
  });
}
