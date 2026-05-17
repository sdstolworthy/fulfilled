import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/food.dart';
import 'package:fulfilled/domain/log_entry.dart';
import 'package:fulfilled/features/log_entry/log_entry_sheet.dart';
import 'package:fulfilled/theme/theme_data.dart';

import '../../_fixtures.dart';
import '../../repositories/_harness.dart';

/// QL-107 — autofocus pass for `LogEntrySheet`.
///
/// Architect §7.4 / QL-008: the quantity stepper autofocuses on first
/// paint in **create mode** so the system keyboard pops as the sheet
/// opens (saves a tap per session). Edit mode does NOT autofocus —
/// it's reviewing a pre-filled value and stealing focus from a
/// review UI is jarring.
///
/// Dev-ticket constraint adds a form-factor gate: on expanded the
/// sheet renders as a centered `Dialog` and popping the system
/// keyboard inside a desktop dialog is unwanted, so autofocus is
/// compact-only.
Food _testFood() => buildFood(servings: [buildServing(id: 'sv_100g')]);

LogEntry _existingEntry() {
  final today = DateTime.now();
  return buildLogEntry(
    id: 'le_existing',
    servingId: 'sv_100g',
    consumedOn: today,
    quantity: Decimal.parse('1.5'),
    enteredAmount: Decimal.fromInt(150),
    nutritionSnapshot: buildSnapshot(caloriesKcal: Decimal.fromInt(150)),
    note: 'pre-seed',
    createdAt: today,
  );
}

Widget _harness({
  required Food food,
  LogEntry? existing,
}) {
  return ProviderScope(
    overrides: <Override>[
      if (existing != null)
        quantityProvider.overrideWith((ref) => existing.quantity),
    ],
    child: MaterialApp(
      theme: buildLightTheme(),
      home: Scaffold(
        body: LogEntrySheetBody(
          food: food,
          existing: existing,
          onSubmit: (_) {},
          showGrabber: false,
        ),
      ),
    ),
  );
}

void main() {
  setUp(() {
    resetRepositoriesForTest();
  });

  tearDown(() {
    teardownRepositoriesForTest();
  });

  testWidgets(
    'create-mode on compact: quantity stepper TextField has focus on first paint',
    (tester) async {
      // 390 logical px → compact.
      tester.view.physicalSize = const Size(390, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_harness(food: _testFood()));
      // Two pumps: the autofocus framework moves focus on the
      // post-first-frame microtask, not synchronously inside build.
      await tester.pump();
      await tester.pump();

      final fieldFinder = find.descendant(
        of: find.byKey(const Key('log_entry_quantity_field_host')),
        matching: find.byType(TextField),
      );
      expect(fieldFinder, findsOneWidget);

      final TextField field = tester.widget<TextField>(fieldFinder);
      expect(
        field.autofocus,
        isTrue,
        reason:
            'create-mode on compact must set `autofocus: true` on the '
            'quantity TextField per architect §7.4.',
      );

      final FocusNode? node = field.focusNode;
      expect(node, isNotNull);
      expect(
        node!.hasFocus,
        isTrue,
        reason:
            'autofocus: true should land focus on the quantity field on '
            'the first paint.',
      );
    },
  );

  testWidgets(
    'edit-mode on compact: no autofocus on the quantity field',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_harness(
        food: _testFood(),
        existing: _existingEntry(),
      ));
      await tester.pump();
      await tester.pump();

      final TextField field = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const Key('log_entry_quantity_field_host')),
          matching: find.byType(TextField),
        ),
      );

      expect(
        field.autofocus,
        isFalse,
        reason:
            'edit-mode pre-fills the quantity; autofocus would steal '
            'focus from a review UI per architect §7.4.',
      );
      expect(
        field.focusNode!.hasFocus,
        isFalse,
        reason:
            'edit-mode must not request focus on the quantity field on '
            'first paint.',
      );
    },
  );

  testWidgets(
    'create-mode on expanded: quantity field does NOT autofocus '
    '(system keyboard inside a centered dialog is jarring)',
    (tester) async {
      // 1400 logical px → expanded. The sheet renders as a centered
      // `Dialog`; QL-107 dev-ticket constraint: autofocus is
      // compact-only on this site.
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_harness(food: _testFood()));
      await tester.pump();
      await tester.pump();

      final TextField field = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const Key('log_entry_quantity_field_host')),
          matching: find.byType(TextField),
        ),
      );

      expect(
        field.autofocus,
        isFalse,
        reason:
            'expanded form factor: dev-ticket constraint excludes the '
            'quantity field from autofocus (system keyboard inside a '
            'centered desktop dialog is jarring).',
      );
      expect(field.focusNode!.hasFocus, isFalse);
    },
  );
}
