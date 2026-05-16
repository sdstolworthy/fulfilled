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
class LogFoodFab extends StatefulWidget {
  const LogFoodFab({required this.onPressed, super.key});

  final VoidCallback onPressed;

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
          onTapDown: (_) => setState(() => _pressed = true),
          onTapCancel: () => setState(() => _pressed = false),
          onTapUp: (_) => setState(() => _pressed = false),
          onTap: widget.onPressed,
          behavior: HitTestBehavior.opaque,
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
}
