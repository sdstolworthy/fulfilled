import 'package:flutter/material.dart';

import '../theme/context_extensions.dart';

/// Canonical primary CTA.
///
/// Architecture appendix names this widget; every "Save", "Log",
/// "Continue", and destructive-confirm button funnels through here so
/// the shape (54-height pill, accent background, surface text) lives in
/// one place. T-04 (accent for primary actions) and T-12 (sticky CTAs
/// in a footer row, not floating) both consume this widget.
///
/// Source: extracted from
/// `features/log_entry/log_entry_sheet.dart`'s save button — the
/// architect named that as canonical because it already had the right
/// height, radius, disabled-treatment, and loading swap.
///
/// **Props**
/// - [label] — visible text. Wrapped in a `Text` styled via the theme's
///   `bodyStrong` plus `fontSize: 16`.
/// - [onPressed] — `null` disables the button (Material applies the
///   disabled background automatically; we also bump the alpha so the
///   accent reads as "muted on", not "off").
/// - [isLoading] — when `true`, swaps the label for a 20-px spinner and
///   ignores `onPressed`. Used during async save flows.
/// - [isDestructive] — when `true`, swaps the accent background for
///   `colors.danger` (T-05: muted red for sign-out + destructive
///   confirms; **not** `dangerOver` — that's the over-budget arc fill).
/// - [dense] — when `true`, render a compact 36-px-tall variant for
///   in-content actions where the standard 54-px sticky-CTA shape
///   would crowd surrounding content. The accent fill, ink color, and
///   `bodyStrong` text weight are unchanged; only the height, the
///   horizontal padding (down to `space.x3`), and the loading spinner
///   (16 px instead of 20 px) shrink. The 36-px visible pill sits
///   inside a 44-px `InkResponse` hit-slop wrapper so the gesture
///   target still clears T-06's 44-px minimum even though the
///   rendered surface is smaller. Used by the scanner's no-detect
///   hint (SC-003/SC-005).
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    required this.label,
    required this.onPressed,
    this.isLoading = false,
    this.isDestructive = false,
    this.dense = false,
    super.key,
  });

  /// CTA copy. Short imperative ("Save to log", "Log first food").
  final String label;

  /// Tap handler. `null` => disabled.
  final VoidCallback? onPressed;

  /// When `true`, render a 20-px spinner (16-px in [dense]) instead of
  /// [label] and ignore taps regardless of [onPressed].
  final bool isLoading;

  /// When `true`, swap the accent background for `colors.danger`. Used
  /// by sign-out and destructive-confirm CTAs.
  final bool isDestructive;

  /// When `true`, render the compact 36-px variant. See class doc.
  /// Default `false` preserves the existing 54-px sticky-CTA shape.
  final bool dense;

  /// Visible-pill height for the dense variant. The outer widget is
  /// wrapped to ≥ 44 px (T-06 floor) via an `InkResponse` hit-slop
  /// region, so the gesture target is wider than the rendered pill.
  static const double _denseVisibleHeight = 36;

  /// Tap-target floor for the dense variant. Wraps the 36-px pill in
  /// an `InkResponse` so taps on the 4-px-per-side slop still fire
  /// `onPressed` (T-06: 44 px minimum).
  static const double _denseHitHeight = 44;

  /// Existing sticky-CTA height; default callers render at this size
  /// byte-for-byte regardless of the dense addition.
  static const double _defaultHeight = 54;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = context.radius;
    final space = context.space;
    final background = isDestructive ? colors.danger : colors.accent;
    final effectiveOnPressed = isLoading ? null : onPressed;
    final spinnerSize = dense ? 16.0 : 20.0;
    final spinner = SizedBox(
      width: spinnerSize,
      height: spinnerSize,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: colors.surface,
      ),
    );
    final button = FilledButton(
      onPressed: effectiveOnPressed,
      style: FilledButton.styleFrom(
        backgroundColor: background,
        foregroundColor: colors.surface,
        disabledBackgroundColor: background.withValues(alpha: 0.6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius.r3),
        ),
        textStyle: context.text.bodyStrong.copyWith(fontSize: 16),
        // Tighten horizontal padding for dense so the label fits the
        // narrower side-by-side band in the no-detect hint. Default
        // mode leaves padding to FilledButton's stock style so
        // existing callers render byte-for-byte the same.
        padding: dense
            ? EdgeInsets.symmetric(horizontal: space.x3)
            : null,
        // `shrinkWrap` lets the dense pill render at exactly 36 px
        // inside its enclosing SizedBox; the surrounding InkResponse
        // wrapper supplies the ≥ 44-px hit-slop separately. Default
        // mode inherits the theme so it stays 54 px tall and 48-px
        // hit-slopped, identical to today.
        tapTargetSize: dense ? MaterialTapTargetSize.shrinkWrap : null,
      ),
      child: isLoading ? spinner : Text(label),
    );

    if (!dense) {
      return SizedBox(
        height: _defaultHeight,
        width: double.infinity,
        child: button,
      );
    }

    // Dense path. Render the visible 36-px pill, then expand the
    // gesture surface to 44 px via a transparent `InkResponse` so the
    // slop above and below the pill still fires `onPressed`. Material
    // requires the InkResponse to sit inside a `Material` ancestor;
    // a transparent one keeps the visible accent fill solely on the
    // inner FilledButton (no double-paint). We merge semantics so
    // assistive tech still announces one button, not two.
    return MergeSemantics(
      child: SizedBox(
        height: _denseHitHeight,
        width: double.infinity,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Hit-slop layer underneath. `InkResponse` (not a bare
            // `GestureDetector`) so the slop is a real Material tap
            // target — focus-traversal and hover-cursor work as you'd
            // expect.
            Positioned.fill(
              child: Material(
                type: MaterialType.transparency,
                child: InkResponse(
                  onTap: effectiveOnPressed,
                  containedInkWell: false,
                  highlightShape: BoxShape.rectangle,
                  // The user-visible ink lives on the inner pill;
                  // mute the slop's splash so taps don't paint two
                  // overlapping highlights.
                  splashColor: const Color(0x00000000),
                  highlightColor: const Color(0x00000000),
                  hoverColor: const Color(0x00000000),
                  focusColor: const Color(0x00000000),
                ),
              ),
            ),
            // Visible pill on top so taps within its bounds go to the
            // FilledButton (preserving its native ink + ripple).
            SizedBox(
              height: _denseVisibleHeight,
              width: double.infinity,
              child: button,
            ),
          ],
        ),
      ),
    );
  }
}
