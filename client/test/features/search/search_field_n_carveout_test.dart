// Production-faithful tests that the `n` keyboard shortcut yields to a
// focused `SearchField`. The unit-level carve-out test
// (`test/widget/keyboard_shortcuts_carveout_test.dart`) covers the
// generic case; these mount the actual `SearchField` widget so a
// regression in the production widget stack surfaces too.
//
// Two harness shapes — both are real production paths:
//   1. SearchField directly inside KeyboardShortcuts (the screen-02
//      mount at `/foods/search`).
//   2. SearchField inside the command-palette dialog opened via
//      `showCommandPaletteSearch` (`⌘K` / `Ctrl-K`). The dialog wraps
//      its content in its own `Shortcuts(Esc)` layer; the n-shortcut
//      handler still has to see "field is focused" through that.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/features/search/widgets/search_field.dart';
import 'package:fulfilled/providers/search_focus_provider.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/keyboard_shortcuts.dart';

void main() {
  testWidgets(
    'production stack: n typed into the SearchField does NOT fire the n-shortcut',
    (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      final container = ProviderContainer();
      addTearDown(container.dispose);

      // Pre-resolve the search focus node so the test can assert
      // against the same instance the SearchField will be wired to.
      final searchFocusNode =
          container.read(searchFieldFocusNodeProvider);

      var logFired = false;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildLightTheme(),
            home: MediaQuery(
              data: const MediaQueryData(size: Size(1280, 800)),
              child: KeyboardShortcuts(
                searchFocusNode: searchFocusNode,
                onLogShortcut: () => logFired = true,
                child: Scaffold(
                  body: Center(
                    child: SearchField(
                      controller: controller,
                      onChanged: (_) {},
                      focusNode: searchFocusNode,
                      autofocus: true,
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
        searchFocusNode.hasFocus,
        isTrue,
        reason: 'SearchField should be autofocused',
      );

      // Send `n`. The shortcut callback must not fire and focus must
      // stay on the search field.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pump();

      expect(
        logFired,
        isFalse,
        reason: 'typing n into the SearchField must not trigger the '
            'global n-shortcut',
      );
      expect(searchFocusNode.hasFocus, isTrue);
    },
  );

  testWidgets(
    'command palette: n typed inside the dialog does NOT fire the n-shortcut',
    (tester) async {
      // Mimics the ⌘K → command-palette dialog flow. The dialog wraps
      // its content in its own Shortcuts(Esc) layer; the editable-focus
      // gate has to still resolve through the dialog's widget tree.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final searchFocusNode =
          container.read(searchFieldFocusNodeProvider);

      var logFired = false;

      // Build a minimal dialog body that mirrors the command-palette
      // shell's structure: outer Shortcuts(Esc), inner SearchField.
      Widget dialogBody(BuildContext context) {
        final controller = TextEditingController();
        addTearDown(controller.dispose);
        return Shortcuts(
          shortcuts: const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.escape): _DummyDismiss(),
          },
          child: Actions(
            actions: <Type, Action<Intent>>{
              _DummyDismiss:
                  CallbackAction<_DummyDismiss>(onInvoke: (_) => null),
            },
            child: Material(
              child: SearchField(
                controller: controller,
                onChanged: (_) {},
                focusNode: searchFocusNode,
                autofocus: true,
              ),
            ),
          ),
        );
      }

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildLightTheme(),
            home: MediaQuery(
              data: const MediaQueryData(size: Size(1280, 800)),
              child: KeyboardShortcuts(
                searchFocusNode: searchFocusNode,
                onLogShortcut: () => logFired = true,
                child: Builder(
                  builder: (context) => Scaffold(
                    body: Center(
                      child: ElevatedButton(
                        onPressed: () => showDialog<void>(
                          context: context,
                          builder: (_) => Dialog(child: dialogBody(context)),
                        ),
                        child: const Text('open'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(
        searchFocusNode.hasFocus,
        isTrue,
        reason: 'dialog SearchField should autofocus',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pump();

      expect(
        logFired,
        isFalse,
        reason: 'n typed inside the command-palette dialog must not '
            'trigger the global n-shortcut',
      );
    },
  );
}

class _DummyDismiss extends Intent {
  const _DummyDismiss();
}
