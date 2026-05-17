import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../theme/context_extensions.dart';

/// LOG-006 — symmetric "Don't have an account? Sign up" affordance.
///
/// Routes to `/onboarding/1` via `context.go` (T-24 Case 2 —
/// route-to-effect, not push). Onboarding step 1 carries the reciprocal
/// "I already have an account" link that lands back here, completing
/// the bidirectional loop (architect §7.4 / §7.5).
///
/// Styling: `foregroundColor: context.colors.accent`, `textStyle:
/// context.text.bodyStrong`. The link is a `TextButton`, not a
/// `PrimaryButton` — T-04 keeps accent-on-pill for the *single* primary
/// CTA per screen ("Sign in"), and this is the secondary affordance.
class SignUpLink extends StatelessWidget {
  const SignUpLink({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return TextButton(
      onPressed: () => context.go('/onboarding/1'),
      style: TextButton.styleFrom(
        foregroundColor: colors.accent,
        textStyle: context.text.bodyStrong,
      ),
      child: const Text("Don't have an account? Sign up"),
    );
  }
}
