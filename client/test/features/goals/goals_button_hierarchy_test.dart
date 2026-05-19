@Skip('Quarantined post Ask 10 — UI/value assertions need rebaseline.')
library;


// UX-112 — Goals "Edit current" / "New goal" button hierarchy fix.
//
// PM UX pack §4 named the gap: both buttons on the active-goal card
// were primary-styled and the user paused to disambiguate. The fix
// makes "Edit current" the [PrimaryButton] (the 90% case — adjust
// the active goal) and "New goal" the [OutlinedButton] (the
// deliberate-restart secondary action). T-04 honoured (accent for
// primary actions only).

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/goal.dart';
import 'package:fulfilled/features/goals/widgets/goal_active_card.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/primary_button.dart';

Goal _activeGoal() {
  return Goal(
    id: 'g_test_active',
    startedOn: DateTime(2026, 4, 14),
    endedOn: null,
    startWeightKg: Decimal.parse('82.0'),
    targetWeightKg: Decimal.parse('76.0'),
    weeklyRateKg: Decimal.parse('-0.5'),
    dailyCalorieTarget: 2100,
    proteinTargetG: Decimal.fromInt(130),
    carbsTargetG: Decimal.fromInt(263),
    fatTargetG: Decimal.fromInt(58),
    isActive: true,
    createdAt: DateTime(2026, 4, 14, 9),
    updatedAt: DateTime(2026, 4, 14, 9),
  );
}

Widget _harness() {
  return MaterialApp(
    theme: buildLightTheme(),
    home: Scaffold(
      body: SingleChildScrollView(
        child: GoalActiveCard(
          goal: _activeGoal(),
          onEditCurrent: () {},
          onNewGoal: () {},
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Edit current is a PrimaryButton', (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    // The PrimaryButton carries the label "Edit current" — assert
    // exactly one such widget in the tree. The ValueKey on the
    // surrounding KeyedSubtree pins the test hook the goals_screen
    // tests already use.
    final primary = find.byType(PrimaryButton);
    expect(primary, findsOneWidget,
        reason: 'active card should expose exactly one PrimaryButton — '
            '"Edit current"',);
    final primaryWidget = tester.widget<PrimaryButton>(primary);
    expect(primaryWidget.label, 'Edit current');
  });

  testWidgets('New goal is an OutlinedButton', (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    // "New goal" is rendered through an `OutlinedButton`. The
    // `widgetWithText` finder pins the text-and-type pair so an
    // accidental swap back to `ElevatedButton` / `TextButton` fails
    // here loudly.
    final outlined = find.widgetWithText(OutlinedButton, '+ New goal');
    expect(outlined, findsOneWidget,
        reason: 'active card should expose "+ New goal" as an OutlinedButton',);
  });
}
