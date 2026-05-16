// QL-108 — Pending-sync row feedback.
//
// `_EntryRow` (inside `widgets/meal_section.dart`) renders a "Pending
// sync" badge when its `isPendingSync` prop is `true`, and on a tap
// that hits the row schedules a 200 ms 1.0 → 1.08 → 1.0 `AnimatedScale`
// pulse on the badge while *also* invoking the row's `onTap` (which
// fires the existing "Still syncing" SnackBar through `editLogEntry`).
//
// We test the leaf-level behaviour here:
//
// 1. The badge renders when `isPendingSync == true` (the `pending-sync-badge`
//    key is present on the badge container).
// 2. The badge is hidden when `isPendingSync == false`.
// 3. The row's Semantics label includes the `still syncing, edit
//    unavailable` suffix (architect §7.6 explicit) when pending.
// 4. Tapping a pending row sets the badge's `AnimatedScale.scale` to
//    1.08 on the first build after the tap, then returns to 1.0 after
//    the 200 ms half-pulse window — and the row's `onTap` was invoked
//    on the tap (mirrors the SnackBar gating from `editLogEntry`).

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/day_summary.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/log_entry.dart';
import 'package:fulfilled/domain/meal.dart';
import 'package:fulfilled/domain/nutrition.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/meal_section.dart';

LogEntry _entry({String id = 'le1'}) => LogEntry(
      id: id,
      foodId: 'f1',
      foodName: 'Greek yogurt',
      servingId: 'sv1',
      servingName: '1 cup',
      consumedOn: DateTime(2026, 5, 14),
      meal: Meal.lunch,
      quantity: Decimal.one,
      gramsTotal: Decimal.fromInt(170),
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

Widget _harness({
  required LogEntry entry,
  required bool pending,
  void Function(LogEntry)? onEntryTap,
}) {
  return MaterialApp(
    theme: buildLightTheme(),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 360,
          child: MealSection(
            subtotal: _subtotal(),
            entries: <LogEntry>[entry],
            onAddTap: () {},
            onEntryTap: onEntryTap,
            isPendingSync: (_) => pending,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'pending row renders the "Pending sync" badge',
    (tester) async {
      await tester.pumpWidget(_harness(entry: _entry(), pending: true));
      await tester.pump();

      expect(find.byKey(const Key('pending-sync-badge')), findsOneWidget);
      expect(find.text('Pending sync'), findsOneWidget);
    },
  );

  testWidgets(
    'non-pending row hides the "Pending sync" badge',
    (tester) async {
      await tester.pumpWidget(_harness(entry: _entry(), pending: false));
      await tester.pump();

      expect(find.byKey(const Key('pending-sync-badge')), findsNothing);
      expect(find.text('Pending sync'), findsNothing);
    },
  );

  testWidgets(
    'pending row Semantics label includes "still syncing, edit unavailable"',
    (tester) async {
      final handle = tester.ensureSemantics();
      addTearDown(handle.dispose);

      await tester.pumpWidget(_harness(entry: _entry(), pending: true));
      await tester.pump();

      expect(
        find.bySemanticsLabel(
          RegExp(r', still syncing, edit unavailable$'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'tapping a pending row pulses the badge (1.0 → 1.08 → 1.0) and '
    'still fires the onTap handler',
    (tester) async {
      int taps = 0;
      await tester.pumpWidget(
        _harness(
          entry: _entry(),
          pending: true,
          onEntryTap: (_) => taps += 1,
        ),
      );
      await tester.pump();

      // Pre-tap: the badge is at rest (scale: 1.0).
      AnimatedScale findScale() => tester.widget<AnimatedScale>(
            find.ancestor(
              of: find.byKey(const Key('pending-sync-badge')),
              matching: find.byType(AnimatedScale),
            ),
          );
      expect(findScale().scale, 1.0);

      // Tap the row — the badge pulses and the onTap fires.
      await tester.tap(find.text('Greek yogurt'));
      await tester.pump();

      // First frame after the tap: the pulse is in progress, scale is
      // the peak (1.08). The handler also fired exactly once.
      expect(findScale().scale, closeTo(1.08, 1e-9));
      expect(taps, 1, reason: 'onTap must still fire on a pending tap');

      // Advance past the 100 ms half-pulse window so the state flips
      // back to 1.0 and the AnimatedScale settles.
      await tester.pump(const Duration(milliseconds: 110));
      await tester.pumpAndSettle();

      expect(findScale().scale, 1.0);
    },
  );

  testWidgets(
    'tapping a non-pending row does not pulse the badge (badge absent)',
    (tester) async {
      int taps = 0;
      await tester.pumpWidget(
        _harness(
          entry: _entry(),
          pending: false,
          onEntryTap: (_) => taps += 1,
        ),
      );
      await tester.pump();

      // Tap the row. Without `isPendingSync`, there's no badge to
      // pulse — the row should still fire `onTap` once.
      await tester.tap(find.text('Greek yogurt'));
      await tester.pump();

      expect(taps, 1);
      expect(find.byKey(const Key('pending-sync-badge')), findsNothing);
    },
  );
}
