import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../routing/routes.dart';
import '../../../theme/context_extensions.dart';
import '../login_controller.dart';

/// LOG-006 — the "Sign in" submit button.
///
/// Wraps a 54-px-tall, full-width accent pill (matching `PrimaryButton`'s
/// shape — T-04 names this as the single accent-only primary on the
/// screen) and swaps the label for a button-sized static skeleton when
/// `state.submitting` is `true` (T-08 — zero `CircularProgressIndicator`
/// anywhere in this screen). The skeleton shape is byte-for-byte the
/// same as `_SaveButtonSkeleton` in `log_entry_sheet.dart` (architect
/// §5.7).
///
/// Post-submit nav: on `controller.submit() == true` we call
/// `context.go(Routes.todayPath)` (T-24 Case 2 — route-to-effect, not
/// push, so the back button doesn't return to the login form).
class LoginButton extends ConsumerWidget {
  const LoginButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Perf (Flutter doc — "Control build() cost"): only `submitting`
    // and `url` are read here. Watching the whole state would rebuild
    // the button on every keystroke of username / password / urlError.
    // We use two `.select` calls because the two slices change on
    // independent edges; the button rebuilds when either flips.
    final submitting = ref.watch(
      loginControllerProvider.select((s) => s.submitting),
    );
    final url = ref.watch(
      loginControllerProvider.select((s) => s.url),
    );
    final controller = ref.read(loginControllerProvider.notifier);
    final colors = context.colors;
    final radius = context.radius;

    Future<void> onPressed() async {
      final ok = await controller.submit();
      if (ok && context.mounted) {
        // T-24 Case 2 — route-to-effect on success. `go` (not `push`)
        // so the back button doesn't bounce the user back to the login
        // form after they're signed in.
        context.go(Routes.todayPath);
      }
    }

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
          onPressed: submitting ? null : onPressed,
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
