import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/log_entry/log_entry_sheet.dart';
import '../form_factor/form_factor.dart';
import '../domain/food.dart';
import '../providers/food_providers.dart';
import '../providers/search_focus_provider.dart';
import '../routing/routes.dart';

/// Global desktop keyboard shortcuts. Architecture §7 "Keyboard shortcuts
/// (`expanded` only)". Wired by `app_router.dart` around the shell.
///
/// On compact / medium this widget is a passthrough — see the early
/// return in `build`. On expanded it wraps `child` in a `Focus` +
/// `Shortcuts` + `Actions` stack:
///
/// | Key | Action |
/// |---|---|
/// | `/` | Focus search input (or push `/foods/search`) |
/// | `⌘K` / `Ctrl-K` | Push `/foods/search` |
/// | `n` | Open the log-entry dialog for the most recent food, |
/// |     | or push `/foods/search` if no recents are available. |
/// | `g t/f/w/o` | Navigate to Today / Foods / Weight / Goals (1 s timeout) |
/// | `g m` | Intentionally unbound (no-op) |
/// | `Esc` | `Navigator.maybePop()` |
///
/// TextField carve-out: `/`, `n`, and the `g _` sequences do nothing
/// while a `TextField` (anything backed by `EditableText`) has primary
/// focus — so typing `/` into the search field types a slash. `⌘K` and
/// `Esc` still fire because they have modifier / special semantics.
class KeyboardShortcuts extends ConsumerStatefulWidget {
  const KeyboardShortcuts({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<KeyboardShortcuts> createState() => _KeyboardShortcutsState();
}

class _KeyboardShortcutsState extends ConsumerState<KeyboardShortcuts> {
  final _TwoKeyMatcher _goMatcher = _TwoKeyMatcher();
  final FocusNode _shortcutsFocus = FocusNode(
    debugLabel: 'keyboardShortcutsRoot',
    skipTraversal: true,
  );

  @override
  void dispose() {
    _goMatcher.dispose();
    _shortcutsFocus.dispose();
    super.dispose();
  }

  /// True when a text field currently owns primary focus. Used by the
  /// raw `onKeyEvent` path's `g _` two-key sequence carve-out (the
  /// `CharacterActivator`-backed `/` and `n` shortcuts now handle the
  /// editable-skip case themselves, so this check is only load-bearing
  /// for the raw-event path).
  ///
  /// The naive check (`primaryFocus.context.widget is EditableText`)
  /// breaks when a `TextField` is constructed with an external
  /// `FocusNode` (e.g. `searchFieldFocusNodeProvider` → search field):
  /// the FocusNode's `.context` resolves to the `Focus` widget that
  /// wraps `EditableText`, not the `EditableText` itself, so the
  /// `is EditableText` check returns false even when the field is
  /// actively being typed into. We walk the descendant tree from the
  /// focus context looking for an `EditableText` so external-FocusNode
  /// fields are detected too.
  bool get _editableFocused {
    final focused = FocusManager.instance.primaryFocus;
    final ctx = focused?.context;
    if (ctx == null) return false;
    if (ctx.widget is EditableText) return true;
    bool found = false;
    void visit(Element el) {
      if (found) return;
      if (el.widget is EditableText) {
        found = true;
        return;
      }
      el.visitChildren(visit);
    }
    ctx.visitChildElements(visit);
    return found;
  }

  void _focusSearchOrPush(BuildContext context) {
    final node = ref.read(searchFieldFocusNodeProvider);
    if (node.context != null && node.canRequestFocus) {
      node.requestFocus();
    } else {
      context.goNamed(Routes.foodsSearchName);
    }
  }

  Future<void> _openLogEntryForMostRecent(BuildContext context) async {
    // Read whatever the recents provider currently has. If it's loading
    // or errored, treat as "no recents available" and fall back to
    // search — the shortcut is a fast path, not a blocking await.
    final recents = ref.read(recentFoodsProvider);
    final list = recents.maybeWhen(
      data: (foods) => foods,
      orElse: () => const <Food>[],
    );
    if (list.isEmpty) {
      if (!context.mounted) return;
      context.goNamed(Routes.foodsSearchName);
      return;
    }
    if (!context.mounted) return;
    await showLogEntrySheet(context, food: list.first);
  }

  void _handleGoKey(BuildContext context, LogicalKeyboardKey second) {
    switch (second) {
      case LogicalKeyboardKey.keyT:
        context.goNamed(Routes.todayName);
        return;
      case LogicalKeyboardKey.keyF:
        context.goNamed(Routes.foodsName);
        return;
      case LogicalKeyboardKey.keyW:
        context.goNamed(Routes.weightName);
        return;
      case LogicalKeyboardKey.keyO:
        context.goNamed(Routes.goalsName);
        return;
      // `g m` and any other letter are intentionally unbound.
    }
  }

  @override
  Widget build(BuildContext context) {
    // FormFactor gate. Architecture §7: do NOT bind on compact / medium.
    if (!FormFactor.of(context).isExpanded) {
      return widget.child;
    }

    return Focus(
      focusNode: _shortcutsFocus,
      // Don't autofocus — we don't want to steal focus from the search
      // TextField when it autofocuses itself on Screen 02. The `onKeyEvent`
      // hook fires for unhandled keys bubbling up the focus tree, which is
      // exactly what we want.
      canRequestFocus: false,
      descendantsAreFocusable: true,
      // Stage 1: a raw key handler runs **before** the Shortcuts map so
      // the two-key `g _` sequence — which can't be expressed as a
      // single `SingleActivator` — can consume the second keystroke.
      // All character-keyed shortcuts (`/`, `n`, `g _`) run *here* —
      // not through a `Shortcuts` widget — because Flutter's
      // `Shortcuts` + `CharacterActivator` invokes the action before
      // the focused `EditableText` ever sees the keystroke, even
      // though the docs imply otherwise. Doing the editable-focus
      // gate manually at this layer is the only way to keep `n` from
      // hijacking typed characters in the search field. Modifier-
      // based and `Escape` shortcuts continue through the `Shortcuts`
      // widget below — text fields don't consume those.
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;

        // Let `Esc` / `⌘K` fall through to the Shortcuts map.
        if (key == LogicalKeyboardKey.escape) return KeyEventResult.ignored;
        if (key == LogicalKeyboardKey.keyK &&
            (HardwareKeyboard.instance.isMetaPressed ||
                HardwareKeyboard.instance.isControlPressed)) {
          return KeyEventResult.ignored;
        }

        // Two-key `g _` sequence. After `g`, consume the next key
        // inside the 1 s window.
        if (_goMatcher.isWaitingForSecondKey) {
          if (_editableFocused) {
            _goMatcher.reset();
            return KeyEventResult.ignored;
          }
          _goMatcher.reset();
          _handleGoKey(context, key);
          return KeyEventResult.handled;
        }

        // From here on every shortcut is editable-gated.
        if (_editableFocused) return KeyEventResult.ignored;

        if (key == LogicalKeyboardKey.keyG) {
          _goMatcher.armForSecondKey();
          return KeyEventResult.handled;
        }
        if (event.character == '/') {
          _focusSearchOrPush(context);
          return KeyEventResult.handled;
        }
        if (event.character?.toLowerCase() == 'n') {
          unawaited(_openLogEntryForMostRecent(context));
          return KeyEventResult.handled;
        }

        return KeyEventResult.ignored;
      },
      child: Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          // ⌘K / Ctrl-K stays on `SingleActivator` — modifier
          // combinations aren't consumed by text fields, and the
          // shortcut is intentionally global anyway.
          SingleActivator(LogicalKeyboardKey.keyK, meta: true):
              _OpenSearchRouteIntent(),
          SingleActivator(LogicalKeyboardKey.keyK, control: true):
              _OpenSearchRouteIntent(),
          // `Esc` is fine as a SingleActivator — it isn't a text
          // input character and `EditableText` doesn't consume it.
          SingleActivator(LogicalKeyboardKey.escape): _PopIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            _OpenSearchRouteIntent: CallbackAction<_OpenSearchRouteIntent>(
              onInvoke: (_) {
                // ⌘K / Ctrl-K is intentionally NOT carved out — it's a
                // global escape hatch the user can hit anywhere.
                context.goNamed(Routes.foodsSearchName);
                return null;
              },
            ),
            _PopIntent: CallbackAction<_PopIntent>(
              onInvoke: (_) {
                Navigator.maybePop(context);
                return null;
              },
            ),
          },
          child: widget.child,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Intents — empty marker types per Shortcuts/Actions convention.
// Only modifier-keyed shortcuts still flow through Shortcuts/Actions;
// the character-keyed ones are handled in the raw `onKeyEvent` above.
// ---------------------------------------------------------------------------

class _OpenSearchRouteIntent extends Intent {
  const _OpenSearchRouteIntent();
}

class _PopIntent extends Intent {
  const _PopIntent();
}

// ---------------------------------------------------------------------------
// Two-key matcher for `g _` sequences. After the first `g`, the next
// keystroke within 1 s consumes the second key; otherwise we reset.
// ---------------------------------------------------------------------------

class _TwoKeyMatcher {
  Timer? _timer;
  bool _armed = false;

  bool get isWaitingForSecondKey => _armed;

  void armForSecondKey() {
    _armed = true;
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 1), reset);
  }

  void reset() {
    _armed = false;
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _armed = false;
  }
}
