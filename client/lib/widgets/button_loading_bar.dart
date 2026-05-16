import 'package:flutter/material.dart';

import '../theme/context_extensions.dart';

/// Button-level loading affordance — the canonical replacement for the
/// inline `CircularProgressIndicator` that used to fill a "Save" /
/// "Continue" CTA while a mutation is in flight.
///
/// T-08 / T-13: loading states are skeletons matched to the consumer's
/// layout, never indeterminate spinners. This widget is the
/// button-level form of that rule. The shape is a static bar (no
/// animation) so `pumpAndSettle()` finishes cleanly in widget tests and
/// the surface stays layout-stable across the loading transition.
///
/// Source: lifted from `_SaveButtonSkeleton` in
/// `features/log_entry/log_entry_sheet.dart` (architect §7.1 — "lock-step
/// prevents drift" when four sites are involved). The visual contract is
/// pixel-equivalent to the lift: a 96-px-wide × 12-px-tall capsule
/// rendered at 35% alpha against the surface color so it reads against
/// the accent button background.
///
/// **Tap semantics.** The widget is rendered *inside* a button whose
/// `onPressed` is `null` during the loading window — there is no tap
/// behavior at this layer. The button's disabled state is the source of
/// truth for "ignore taps."
///
/// **Semantics (T-20).** Wraps the bar in a `Semantics(label: 'Saving',
/// liveRegion: true)` so screen-reader users hear "Saving" when the
/// button enters its loading state.
class ButtonLoadingBar extends StatelessWidget {
  const ButtonLoadingBar({super.key});

  /// Visible width of the bar. Pinned to the original
  /// `_SaveButtonSkeleton` value so the lift is byte-for-byte identical.
  static const double width = 96;

  /// Visible height of the bar. Pinned to the original
  /// `_SaveButtonSkeleton` value.
  static const double height = 12;

  /// Outer hit target — matches a `PrimaryButton` body so the widget can
  /// drop into a CTA's child slot without changing the surrounding
  /// button's rendered height. The button itself stays 44 px (or its
  /// owning shape's full height) via the parent SizedBox; the bar is
  /// centered inside.
  static const double buttonHeight = 44;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Saving',
      liveRegion: true,
      child: SizedBox(
        width: width,
        height: height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(height / 2),
          child: ColoredBox(
            color: context.colors.surface.withValues(alpha: 0.35),
          ),
        ),
      ),
    );
  }
}
