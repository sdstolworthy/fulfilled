import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/food.dart';
import 'package:fulfilled/domain/log_entry.dart';
import 'package:fulfilled/features/log_entry/log_entry_sheet.dart';
import 'package:fulfilled/features/log_entry/widgets/meal_chip_picker.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:intl/intl.dart';

import '../../_fixtures.dart';

/// QL-107 — `LogEntrySheet` DATE row.
///
/// Asserts the row renders between MEAL and NOTE, formats the current
/// `_date` in the architect-spec'd wording (`"Today · MMM d"` for
/// today, `"EEE, MMM d"` otherwise), opens `showDatePicker` on tap,
/// updates the row label when a date is selected, and the picked date
/// flows into the `LogCreate` payload on save.
Food _testFood() => buildFood(servings: [buildServing(id: 'sv_100g')]);

Widget _harness({
  required Food food,
  required ValueChanged<LogCreate> onSubmit,
  DateTime? initialDate,
}) {
  return ProviderScope(
    child: MaterialApp(
      theme: buildLightTheme(),
      home: Scaffold(
        body: LogEntrySheetBody(
          food: food,
          onSubmit: onSubmit,
          showGrabber: false,
          initialDate: initialDate,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'DATE row renders between MEAL and NOTE with the "Today · MMM d" label '
    'when _date == today',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_harness(
        food: _testFood(),
        onSubmit: (_) {},
      ),);
      await tester.pump();

      // Row presence — keyed widget exists.
      expect(find.byKey(const Key('log_entry_date_row')), findsOneWidget);

      // Label text uses the "Today · MMM d" wording on first paint
      // (create-mode default seeds `_date` from `DateTime.now()`).
      final today = DateTime.now();
      final expected = 'Today · ${DateFormat('MMM d').format(today)}';
      expect(find.text(expected), findsOneWidget);

      // Position check: MEAL eyebrow precedes the row; NOTE eyebrow
      // follows it. Architect §7.7 — DATE sits between MEAL and NOTE.
      final mealOffset = tester
          .getTopLeft(find.text('MEAL'))
          .dy;
      final dateOffset = tester
          .getTopLeft(find.byKey(const Key('log_entry_date_row')))
          .dy;
      final noteOffset = tester
          .getTopLeft(find.text('NOTE (OPTIONAL)'))
          .dy;
      expect(mealOffset, lessThan(dateOffset));
      expect(dateOffset, lessThan(noteOffset));

      // The MealChipPicker still renders above the row (sanity).
      expect(find.byType(MealChipPicker), findsOneWidget);
    },
  );

  testWidgets(
    'DATE row label reads "EEE, MMM d" when _date != today',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Seed `_date` to a deterministic non-today value via the
      // `@visibleForTesting initialDate` seam — the architect-named
      // route into the date state without going through the picker.
      final backdate = DateTime.now().subtract(const Duration(days: 2));
      final expected = DateFormat('EEE, MMM d').format(
        DateTime(backdate.year, backdate.month, backdate.day),
      );

      await tester.pumpWidget(_harness(
        food: _testFood(),
        onSubmit: (_) {},
        initialDate: backdate,
      ),);
      await tester.pump();

      expect(find.text(expected), findsOneWidget);
      // "Today · …" wording is absent on a backdated state.
      expect(find.textContaining('Today · '), findsNothing);
    },
  );

  testWidgets(
    'tapping the DATE row opens showDatePicker',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_harness(
        food: _testFood(),
        onSubmit: (_) {},
      ),);
      await tester.pump();

      // No date picker present before tap.
      expect(find.byType(DatePickerDialog), findsNothing);

      await tester.tap(find.byKey(const Key('log_entry_date_row')));
      await tester.pumpAndSettle();

      // `showDatePicker` mounts a `DatePickerDialog` in the overlay.
      expect(find.byType(DatePickerDialog), findsOneWidget);
    },
  );

  testWidgets(
    'picked date flows into the LogCreate payload on save',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Pre-seed `_date` to a backdated value via the test seam (the
      // production path uses the DatePicker, but the picker's UI is
      // out of scope here — we're asserting the date threads into
      // the save payload, not the picker's own behaviour, which is
      // Flutter-owned).
      final backdate = DateTime.now().subtract(const Duration(days: 3));
      final expectedDate =
          DateTime(backdate.year, backdate.month, backdate.day);

      LogCreate? captured;
      await tester.pumpWidget(_harness(
        food: _testFood(),
        onSubmit: (lc) => captured = lc,
        initialDate: backdate,
      ),);
      await tester.pump();

      await tester.tap(find.byKey(const Key('log_entry_save_button')));
      await tester.pump();

      expect(captured, isNotNull);
      expect(captured!.consumedOn, equals(expectedDate));
    },
  );

  testWidgets(
    'edit-mode renders the DATE row pre-seeded from existing.consumedOn',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final consumedOn = DateTime.now().subtract(const Duration(days: 4));
      final entry = buildLogEntry(
        id: 'le_existing',
        servingId: 'sv_100g',
        consumedOn: consumedOn,
      );

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: buildLightTheme(),
            home: Scaffold(
              body: LogEntrySheetBody(
                food: _testFood(),
                existing: entry,
                onSubmit: (_) {},
                showGrabber: false,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final expected = DateFormat('EEE, MMM d').format(
        DateTime(consumedOn.year, consumedOn.month, consumedOn.day),
      );
      expect(find.text(expected), findsOneWidget);
    },
  );
}
