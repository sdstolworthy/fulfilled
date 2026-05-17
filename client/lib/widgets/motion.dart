import 'package:flutter/widgets.dart';

/// Reduced-motion helper. Wraps every animation duration so that when the
/// user has the OS-level "reduce motion" flag enabled (surfaced by Flutter
/// as `MediaQuery.disableAnimations`), every animation in the app collapses
/// to `Duration.zero` and the rendered value snaps to its target on the
/// next frame.
///
/// Usage:
/// ```dart
/// TweenAnimationBuilder<double>(
///   duration: motion(context, const Duration(milliseconds: 400)),
///   ...
/// );
/// ```
///
/// The architect's B4 verdict (`specs/architect_annotated_features.md`)
/// codifies this as the single seam every animated leaf in the app shares
/// — no per-widget if/else branches on the accessibility flag.
///
/// Tickets: T-016 (animation polish), tenant T-08-adjacent accessibility
/// pass.
Duration motion(BuildContext context, Duration full) =>
    MediaQuery.disableAnimationsOf(context) ? Duration.zero : full;

/// T-016 dialog arrival animation used by the bottom-sheet/dialog
/// surfaces (`LogEntrySheet`, `QuickAddSheet`). Fades + slides the
/// dialog body in over 200 ms; collapses to a one-frame snap when
/// `disableAnimations` is set.
///
/// Audit finding #11: the body of this widget was byte-identical
/// between `LogEntrySheet._DialogEnterAnimation` and
/// `QuickAddSheet._DialogEnterAnimation`. Lifting it here drops two
/// copies; new sheets get it for free.
class SheetDialogEnter extends StatelessWidget {
  const SheetDialogEnter({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: motion(context, const Duration(milliseconds: 200)),
      curve: Curves.easeOutCubic,
      builder: (context, t, inner) {
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 8 * (1 - t)),
            child: inner,
          ),
        );
      },
      child: child,
    );
  }
}
