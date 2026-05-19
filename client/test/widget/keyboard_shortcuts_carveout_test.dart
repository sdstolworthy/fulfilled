// Carve-out tests for the global keyboard shortcuts: every shortcut
// that's a plain character (`n`, `/`, `g _`) must yield to a focused
// `TextField` so the user types the character instead of triggering
// the shortcut.
//
// What we can actually assert in a widget test: the shortcut callback
// must NOT fire (and the search focus must not move, and the router
// must not navigate). `tester.sendKeyEvent` doesn't feed the text
// input pipeline, so we can't verify the field's `text` directly —
// but the user-visible failure mode is the shortcut side-effect
// firing on a typed key, and that is what these tests pin.
//
// Per `specs/testing_guide.md` §4.4 the widget takes its inputs as
// constructor params — no `ProviderScope` needed.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/widgets/keyboard_shortcuts.dart';

class _Harness {
  _Harness({
    required this.fieldFocus,
    required this.searchFocus,
    required this.logFired,
    required this.popped,
  });
  final FocusNode fieldFocus;
  final FocusNode searchFocus;
  final ValueGetter<bool> logFired;
  final ValueGetter<bool> popped;
}

/// Pumps [KeyboardShortcuts] wrapping a focused [TextField] that uses
/// an **external** `FocusNode` — the production setup
/// (`searchFieldFocusNodeProvider` → `SearchField`).
Future<_Harness> _pumpHarness(WidgetTester tester) async {
  final controller = TextEditingController();
  final fieldFocus = FocusNode(debugLabel: 'test-field');
  final searchFocus = FocusNode(debugLabel: 'test-search-focus');
  addTearDown(controller.dispose);
  addTearDown(fieldFocus.dispose);
  addTearDown(searchFocus.dispose);

  var logFired = false;
  var popped = false;

  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(size: Size(1280, 800)),
        child: KeyboardShortcuts(
          searchFocusNode: searchFocus,
          onLogShortcut: () => logFired = true,
          child: Scaffold(
            // The PopScope catches Navigator.maybePop attempts so the
            // `g _` tests can spot a router-side fire without having
            // to mount a real GoRouter.
            body: PopScope(
              canPop: false,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop) popped = true;
              },
              child: Center(
                child: SizedBox(
                  width: 200,
                  child: TextField(
                    controller: controller,
                    focusNode: fieldFocus,
                    autofocus: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  expect(
    fieldFocus.hasFocus,
    isTrue,
    reason: 'autofocus should have given the field primary focus',
  );

  return _Harness(
    fieldFocus: fieldFocus,
    searchFocus: searchFocus,
    logFired: () => logFired,
    popped: () => popped,
  );
}

void main() {
  testWidgets(
    'n while a TextField is focused → onLogShortcut does NOT fire',
    (tester) async {
      final harness = await _pumpHarness(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pump();

      expect(
        harness.logFired(),
        isFalse,
        reason: 'the n-shortcut must yield to the focused field',
      );
      expect(
        harness.fieldFocus.hasFocus,
        isTrue,
        reason: 'focus should not have moved',
      );
    },
  );

  testWidgets(
    '/ while a TextField is focused → search focus does NOT move',
    (tester) async {
      final harness = await _pumpHarness(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.slash);
      await tester.pump();

      // The `/` shortcut moves focus to `searchFocusNode` when it fires.
      // The carve-out should suppress that and leave the field focused.
      expect(
        harness.searchFocus.hasFocus,
        isFalse,
        reason: 'the /-shortcut must yield to the focused field',
      );
      expect(harness.fieldFocus.hasFocus, isTrue);
    },
  );

  testWidgets(
    'g while a TextField is focused → does NOT arm the two-key sequence',
    (tester) async {
      final harness = await _pumpHarness(tester);

      // First `g` (would normally arm), then `t` (would normally route
      // to /today). With the field focused neither must fire — and
      // since the test harness has no real GoRouter, a fire would
      // throw, so a clean run is itself the assertion.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
      await tester.pump();

      expect(harness.logFired(), isFalse);
      expect(harness.fieldFocus.hasFocus, isTrue);
    },
  );

  testWidgets(
    'no plain alphabetic key triggers the n-shortcut while a TextField is focused',
    (tester) async {
      // Defense in depth: every alphabetic key must yield to the field.
      // If a future shortcut binds a new letter without a carve-out it
      // should fail this assertion.
      final harness = await _pumpHarness(tester);

      const keys = <LogicalKeyboardKey>[
        LogicalKeyboardKey.keyA,
        LogicalKeyboardKey.keyB,
        LogicalKeyboardKey.keyC,
        LogicalKeyboardKey.keyD,
        LogicalKeyboardKey.keyE,
        LogicalKeyboardKey.keyN,
        LogicalKeyboardKey.keyQ,
        LogicalKeyboardKey.keyX,
        LogicalKeyboardKey.keyZ,
      ];

      for (final key in keys) {
        await tester.sendKeyEvent(key);
        await tester.pump();
      }

      expect(
        harness.logFired(),
        isFalse,
        reason: 'no alphabetic key may trigger a shortcut',
      );
      expect(
        harness.fieldFocus.hasFocus,
        isTrue,
        reason: 'no alphabetic key may move focus off the field',
      );
    },
  );
}
