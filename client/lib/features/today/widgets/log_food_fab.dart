import 'package:flutter/material.dart';

import '../../../theme/context_extensions.dart';
import '../../../widgets/motion.dart';

/// The compact "Log food" FAB. Lifted out of `day_view_compact.dart` so the
/// T-016 animation hooks (press-down scale + web hover tint) live on a
/// widget the architect can point at by name.
///
/// **Animations** (T-016):
/// - Press-down: `AnimatedScale` to 0.95 over 120 ms.
/// - Hover (web only): `MouseRegion` flips `_hovered`; the background
///   interpolates to a slightly-darker accent over 80 ms via
///   `AnimatedContainer`. **No elevation change** — T-04 / §7 forbid
///   hover-elevation.
/// - All durations route through `motion(context, …)` so reduce-motion
///   collapses them to zero.
///
/// We render a custom rounded container instead of
/// `FloatingActionButton.extended` so the `AnimatedContainer` background
/// tween actually drives the painted color (Material's FAB does not
/// implicitly animate `backgroundColor`). Visual identity matches the
/// extended FAB: 56-px height, 16-px horizontal padding, 16-px corner
/// radius, accent fill, surface text, leading "+" icon, label.
///
/// **UX-102 — long-press secondary action.** A long-press on the FAB
/// opens a two-item `showMenu` popup with "Log food" (the same handler
/// as short-press) and "Quick add calories" (`onQuickAdd`). The bolt
/// icon that used to live in the compact header (`_CompactHeader`) is
/// folded into this menu so the header collapses to a single search
/// icon. T-12 (the FAB is the only floating action) holds under the
/// strict reading: `showMenu` is a route-style modal (Material's
/// `_PopupRoute`) anchored over the FAB, not a separate floating
/// widget. See `architect_ux_pack.md` §6.2 + §10.1.
class LogFoodFab extends StatefulWidget {
  const LogFoodFab({
    required this.onPressed,
    required this.onQuickAdd,
    super.key,
  });

  /// Short-press / "Log food" handler. Unchanged from the pre-UX-102
  /// behaviour: the day view passes
  /// `() => context.push(Routes.foodsSearchPath)`.
  final VoidCallback onPressed;

  /// Long-press → "Quick add calories" handler. UX-102 moves the bolt
  /// icon's prior handler (`() => showQuickAddSheet(context)`) into
  /// this slot.
  final VoidCallback onQuickAdd;

  @override
  State<LogFoodFab> createState() => _LogFoodFabState();
}

class _LogFoodFabState extends State<LogFoodFab> {
  bool _pressed = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    // The hover tint stays under `accent` and never raises elevation — the
    // §7 rule + T-04 (accent is the "press here" hue; we darken it, not
    // shift it elsewhere). 8 % black overlay reads as a barely-visible
    // darken without inventing a new token.
    final hoverTint = Color.alphaBlend(
      Colors.black.withValues(alpha: 0.08),
      colors.accent,
    );
    final pressDuration = motion(context, const Duration(milliseconds: 120));
    final hoverDuration = motion(context, const Duration(milliseconds: 80));
    const radius = BorderRadius.all(Radius.circular(16));

    return Semantics(
      button: true,
      label: 'Log food',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          // UX-102: long-press opens the two-item menu. `HitTestBehavior.
          // opaque` so the long-press registers on the FAB surface and
          // not on the underlying scaffold body.
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapCancel: () => setState(() => _pressed = false),
          onTapUp: (_) => setState(() => _pressed = false),
          onTap: widget.onPressed,
          onLongPress: () => _showLongPressMenu(context),
          child: AnimatedScale(
            scale: _pressed ? 0.95 : 1.0,
            duration: pressDuration,
            curve: Curves.easeInOut,
            child: AnimatedContainer(
              duration: hoverDuration,
              curve: Curves.easeInOut,
              height: 56,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: _hovered ? hoverTint : colors.accent,
                borderRadius: radius,
                // Static drop shadow that matches Material's default FAB
                // elevation; constant across hover/press so the §7 "no
                // elevation change on hover" rule holds.
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.12),
                    blurRadius: 6,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.add, size: 18, color: colors.surface),
                  const SizedBox(width: 8),
                  Text(
                    'Log food',
                    style: context.text.bodyStrong.copyWith(
                      color: colors.surface,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// UX-102 — open the two-item FAB menu anchored above the FAB.
  ///
  /// **Why `showMenu` and not `showModalBottomSheet`**: the PM doc §2
  /// Theme A and architect §6.2 both name a menu, not a sheet. A sheet
  /// is too heavy for two items; the menu reads as "the FAB grew two
  /// options," not "the FAB opened a screen." `showMenu` is the same
  /// surface a `PopupMenuButton` renders.
  ///
  /// **T-12 reading**: `showMenu` is a route-style modal (Material's
  /// `_PopupRoute`), not a floating widget — the FAB stays the only
  /// floating action. See `architect_ux_pack.md` §10.1.
  Future<void> _showLongPressMenu(BuildContext context) async {
    final overlayState = Overlay.of(context);
    final overlayBox = overlayState.context.findRenderObject() as RenderBox;
    // Anchor the popup just above the FAB. The FAB sits at bottom-right
    // with safe-area offset; the menu opens upward from a 220×200 inset
    // from the overlay's bottom-right corner (architect §6.2's starting
    // offsets). These values keep the menu inside the Pixel 4a viewport.
    final selected = await showMenu<_FabAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        overlayBox.size.width - 220,
        overlayBox.size.height - 200,
        24,
        24,
      ),
      items: const <PopupMenuEntry<_FabAction>>[
        PopupMenuItem<_FabAction>(
          key: Key('fab-menu-log-food'),
          value: _FabAction.logFood,
          child: Row(
            children: <Widget>[
              Icon(Icons.add),
              SizedBox(width: 12),
              Text('Log food'),
            ],
          ),
        ),
        PopupMenuItem<_FabAction>(
          key: Key('fab-menu-quick-add'),
          value: _FabAction.quickAdd,
          child: Row(
            children: <Widget>[
              Icon(Icons.bolt_outlined),
              SizedBox(width: 12),
              Text('Quick add calories'),
            ],
          ),
        ),
      ],
    );
    if (!mounted) return;
    switch (selected) {
      case _FabAction.logFood:
        widget.onPressed();
        break;
      case _FabAction.quickAdd:
        widget.onQuickAdd();
        break;
      case null:
        // Dismissed without selection — no-op.
        break;
    }
  }
}

/// Long-press menu actions for [LogFoodFab]. File-private — the menu's
/// values are not part of the public surface; the widget exposes only
/// the two `VoidCallback` parameters.
enum _FabAction { logFood, quickAdd }
