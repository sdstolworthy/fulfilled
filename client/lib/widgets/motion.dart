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
