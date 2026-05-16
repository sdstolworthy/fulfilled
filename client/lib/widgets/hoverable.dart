import 'package:flutter/material.dart';

import '../theme/context_extensions.dart';
import 'motion.dart';

/// Shared hover affordance for tappable surfaces on web/desktop.
///
/// Architecture §7 (Hover) commits the app to one shape: every tappable
/// surface gets `MouseRegion(cursor: SystemMouseCursors.click)` plus a
/// background that interpolates from transparent to `colors.line2` over
/// 80 ms on hover. Accent is never used as a hover color (T-04). Cards
/// never lift on hover.
///
/// **Who uses this widget vs. who relies on Material defaults.**
/// Surfaces that already wrap their child in an `InkResponse` / `InkWell`
/// (e.g. [IconButton36], `_EntryRow` in `MealSection`, `SearchResultRow`,
/// `SettingsRow`, `ServingList` rows, `QuickChipRow` chips,
/// `MealChipPicker` cells, `SegmentedSelect`, `ActivityOption`,
/// `GoalOption`) get the same hover wash by setting Material's
/// `hoverColor: context.colors.line2`. Material handles cursor +
/// fade-in itself, so wrapping again would double-paint and double-cost
/// the gesture pipeline. `Hoverable` is the one helper for any future
/// non-Ink interactive surface — keep it as the single seam so the rule
/// has a name to cite (T-018 / §7).
///
/// **API**:
/// - [child] — the surface to tint on hover.
/// - [radius] — optional corner radius applied to the
///   `AnimatedContainer.decoration` so the tint clips to a rounded
///   shape (chips, cards).
/// - [onTap] — optional tap handler. When provided, the wrapper also
///   detects taps so `Hoverable` can stand alone without an outer
///   `GestureDetector`. Use the existing `InkResponse` path instead
///   when a Material ripple is desired.
///
/// **Reduced motion** — the 80 ms transition routes through
/// [motion], so `MediaQuery.disableAnimations` collapses it to
/// `Duration.zero`. The tint still appears on hover; it just snaps
/// instead of fading.
class Hoverable extends StatefulWidget {
  const Hoverable({
    required this.child,
    this.radius,
    this.onTap,
    super.key,
  });

  /// The widget that becomes the hover target.
  final Widget child;

  /// Optional corner radius for the hover tint.
  final BorderRadius? radius;

  /// Optional tap handler. Mirrors the architect's stated API surface so
  /// callers can use `Hoverable` as a complete tappable affordance when
  /// they don't need an `InkWell` ripple.
  final VoidCallback? onTap;

  @override
  State<Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<Hoverable> {
  bool _isHovered = false;

  void _setHovered(bool value) {
    if (_isHovered == value) return;
    setState(() => _isHovered = value);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    // Architect §7: 80 ms hover fade. `motion()` collapses to zero when
    // reduce-motion is on so the tint snaps without animation.
    final duration = motion(context, const Duration(milliseconds: 80));

    Widget content = AnimatedContainer(
      duration: duration,
      curve: Curves.linear,
      decoration: BoxDecoration(
        color: _isHovered ? colors.line2 : Colors.transparent,
        borderRadius: widget.radius,
      ),
      child: widget.child,
    );

    if (widget.onTap != null) {
      content = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: content,
      );
    }

    // MouseRegion is a no-op on touch-primary devices (Flutter only fires
    // enter/exit for pointer-kind == mouse). No viewport-size branch is
    // needed — `cursor` is harmless on touch and hover events never fire.
    return MouseRegion(
      cursor: widget.onTap == null
          ? MouseCursor.defer
          : SystemMouseCursors.click,
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: content,
    );
  }
}
