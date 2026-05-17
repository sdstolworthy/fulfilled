// UX-112 a11y — LiveRegion on the pending-sync row.
//
// PM UX pack §6 acceptance: the pending-sync badge should be wrapped
// in a LiveRegion so the screen reader gets a "Synced" announcement
// when the post-flush fade transitions the badge out. Because the
// outer row Semantics already uses `ExcludeSemantics` to collapse the
// food-name + serving + kcal + "Pending sync" glyphs into a single
// merged label, the badge's own LiveRegion is masked at runtime —
// the row's Semantics is the surface that actually reaches the
// screen reader. The fix declares `liveRegion: widget.isPendingSync`
// on the row's Semantics so the state change announces; the badge
// also carries an inner LiveRegion as a defensive belt-and-braces in
// case the row's ExcludeSemantics changes shape.
//
// Acceptance:
// 1. Pending row: the row's SemanticsNode is a live region.
// 2. Non-pending row: the row's SemanticsNode is NOT a live region.
// 3. The badge's `Semantics(liveRegion: true)` widget is mounted
//    when the row is pending (defensive belt-and-braces — confirms
//    the badge-level declaration was added).

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/day_summary.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/log_entry.dart';
import 'package:fulfilled/domain/meal.dart';
import 'package:fulfilled/domain/nutrition.dart';
import 'package:fulfilled/domain/unit.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/meal_section.dart';

LogEntry _entry() => LogEntry(
      id: 'le1',
      foodId: 'f1',
      foodName: 'Greek yogurt',
      servingId: 'sv1',
      servingName: '1 cup',
      consumedOn: DateTime(2026, 5, 14),
      meal: Meal.lunch,
      quantity: Decimal.one,
      enteredAmount: Decimal.fromInt(170),
      enteredUnit: Unit.g,
      nutritionSnapshot: NutritionSnapshot(
        caloriesKcal: Decimal.fromInt(120),
      ),
      note: null,
      createdAt: DateTime(2026, 5, 14, 12),
      updatedAt: DateTime(2026, 5, 14, 12),
    );

MealSubtotal _subtotal() => MealSubtotal(
      meal: Meal.lunch,
      kcal: Decimal.fromInt(120),
      proteinG: Decimal.fromInt(10),
      carbsG: Decimal.fromInt(15),
      fatG: Decimal.fromInt(2),
      entryCount: 1,
    );

Widget _harness({required bool pending}) {
  return MaterialApp(
    theme: buildLightTheme(),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 360,
          child: MealSection(
            subtotal: _subtotal(),
            entries: <LogEntry>[_entry()],
            onAddTap: () {},
            onEntryTap: (_) {},
            isPendingSync: (_) => pending,
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('pending row Semantics carries liveRegion flag',
      (tester) async {
    final handle = tester.ensureSemantics();
    addTearDown(handle.dispose);

    await tester.pumpWidget(_harness(pending: true));
    await tester.pump();

    // Find the row's merged Semantics node by label suffix (the
    // existing pending-sync test pins this contract).
    final rowFinder = find.bySemanticsLabel(
      RegExp(r', still syncing, edit unavailable$'),
    );
    expect(rowFinder, findsOneWidget);

    final node = tester.getSemantics(rowFinder);
    expect(
      node.hasFlag(SemanticsFlag.isLiveRegion),
      isTrue,
      reason: 'pending row Semantics should be a live region so screen '
          'readers announce the sync state change on transition',
    );
  });

  testWidgets('non-pending row Semantics is NOT a live region',
      (tester) async {
    final handle = tester.ensureSemantics();
    addTearDown(handle.dispose);

    await tester.pumpWidget(_harness(pending: false));
    await tester.pump();

    // Non-pending row's label has no "still syncing" suffix; find
    // by the food name instead.
    final rowFinder =
        find.bySemanticsLabel(RegExp(r'^Greek yogurt,.*edit$'));
    expect(rowFinder, findsOneWidget);

    final node = tester.getSemantics(rowFinder);
    expect(
      node.hasFlag(SemanticsFlag.isLiveRegion),
      isFalse,
      reason: 'idle row should NOT be a live region; the announcement '
          'is only for the pending → synced transition',
    );
  });
}
