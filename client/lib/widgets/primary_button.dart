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
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    required this.label,
    required this.onPressed,
    this.isLoading = false,
    this.isDestructive = false,
    super.key,
  });

  /// CTA copy. Short imperative ("Save to log", "Log first food").
  final String label;

  /// Tap handler. `null` => disabled.
  final VoidCallback? onPressed;

  /// When `true`, render a 20-px spinner instead of [label] and ignore
  /// taps regardless of [onPressed].
  final bool isLoading;

  /// When `true`, swap the accent background for `colors.danger`. Used
  /// by sign-out and destructive-confirm CTAs.
  final bool isDestructive;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = context.radius;
    final background = isDestructive ? colors.danger : colors.accent;
    final effectiveOnPressed = isLoading ? null : onPressed;
    return SizedBox(
      height: 54,
      width: double.infinity,
      child: FilledButton(
        onPressed: effectiveOnPressed,
        style: FilledButton.styleFrom(
          backgroundColor: background,
          foregroundColor: colors.surface,
          disabledBackgroundColor: background.withValues(alpha: 0.6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius.r3),
          ),
          textStyle: context.text.bodyStrong.copyWith(fontSize: 16),
        ),
        child: isLoading
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.surface,
                ),
              )
            : Text(label),
      ),
    );
  }
}
