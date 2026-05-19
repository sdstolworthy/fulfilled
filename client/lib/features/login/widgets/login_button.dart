import 'package:flutter/material.dart';

import '../../../theme/context_extensions.dart';

/// LOG-006 — the "Sign in" submit button.
///
/// Wraps a 54-px-tall, full-width accent pill (matching `PrimaryButton`'s
/// shape — T-04 names this as the single accent-only primary on the
/// screen) and swaps the label for a button-sized static skeleton when
/// `submitting` is `true` (T-08 — zero `CircularProgressIndicator`
/// anywhere in this screen). The skeleton shape is byte-for-byte the
/// same as `_SaveButtonSkeleton` in `log_entry_sheet.dart` (architect
/// §5.7).
///
/// Post-submit nav: the container's `onSubmit` callback is responsible
/// for calling `controller.submit()` and (on `true`) routing via
/// `context.go(Routes.todayPath)` — T-24 Case 2. Keeping the router
/// dependency in the container lets this leaf stay router- and
/// provider-free.
///
/// **Pure presentation widget** — see `specs/testing_guide.md` §4.4.
/// This file imports nothing from `package:flutter_riverpod` or
/// `go_router`.
///
/// **Inputs.**
/// - `submitting` — drives the disabled state + the T-08 skeleton
///   swap.
/// - `url` — used to compute the T-20 semantics label
///   (`Sign in to <hostname>` when the URL field has been filled).
/// - `onSubmit` — fired on tap. Container handles the submit flow +
///   the post-success navigation.
class LoginButton extends StatelessWidget {
  const LoginButton({
    super.key,
    required this.submitting,
    required this.url,
    required this.onSubmit,
  });

  final bool submitting;
  final String url;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = context.radius;

    // T-20 — semantic label includes the hostname when the URL field
    // has been filled (architect §5.8 + ticket "submit reads 'Sign in
    // to <hostname>' when URL present").
    final hostHint = _hostnameForSemantics(url);
    final semanticsLabel =
        hostHint != null ? 'Sign in to $hostHint' : 'Sign in';

    return Semantics(
      button: true,
      label: semanticsLabel,
      child: SizedBox(
        height: 54,
        width: double.infinity,
        child: FilledButton(
          onPressed: submitting ? null : onSubmit,
          style: FilledButton.styleFrom(
            backgroundColor: colors.accent,
            foregroundColor: colors.surface,
            disabledBackgroundColor: colors.accent.withValues(alpha: 0.6),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radius.r3),
            ),
            textStyle: context.text.bodyStrong.copyWith(fontSize: 16),
          ),
          // T-08 — static skeleton in place of label during submit. Same
          // shape as `_SaveButtonSkeleton` in
          // `log_entry_sheet.dart` (architect §5.7). Zero
          // `CircularProgressIndicator` lives in this file.
          child: submitting ? const _SubmitSkeleton() : const Text('Sign in'),
        ),
      ),
    );
  }

  /// Best-effort hostname extract for the semantics label. Returns
  /// `null` for empty / unparseable URLs so the label collapses to
  /// `"Sign in"` rather than `"Sign in to "`.
  String? _hostnameForSemantics(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final parsed = Uri.tryParse(
      trimmed.startsWith('http') ? trimmed : 'https://$trimmed',
    );
    if (parsed == null || parsed.host.isEmpty) return null;
    return parsed.host;
  }
}

/// Button-level loading affordance for T-08. Mirrors the shape of
/// `_SaveButtonSkeleton` in `log_entry_sheet.dart:722` (architect §5.7)
/// so the submit-in-flight surface is layout-stable and `pumpAndSettle`
/// completes cleanly. No `CircularProgressIndicator` — anywhere in this
/// file is a bug.
class _SubmitSkeleton extends StatelessWidget {
  const _SubmitSkeleton();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Signing in',
      liveRegion: true,
      child: SizedBox(
        width: 96,
        height: 12,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: ColoredBox(
            color: context.colors.surface.withValues(alpha: 0.35),
          ),
        ),
      ),
    );
  }
}
