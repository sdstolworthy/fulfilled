import 'package:flutter/material.dart';

import '../../../theme/context_extensions.dart';

/// Common chrome shared by all three onboarding steps. Owns:
///
/// - the progress-dot row (n segments, m on),
/// - the "STEP X OF 3" eyebrow,
/// - the optional title + subtitle (lede),
/// - the scrollable body slot,
/// - the sticky footer with a primary CTA and optional back affordance.
///
/// **Form-factor stance.** The shell itself is leaf-level (T-15) — the
/// screen root (`OnboardingScreen`) is what branches on form factor and
/// constrains the column to 520 px on expanded. The shell renders the
/// same on every breakpoint.
///
/// **Architecture mapping.** Inventoried as `OnboardingStepShell` in §3.
/// Per spec the shell sits inside `lib/widgets/`, but per "if it's used by
/// exactly one screen it stays inside the feature folder" rule it lives
/// alongside the steps that compose it. Lifting to `widgets/` is a single
/// move when another screen wants the same shell.
class OnboardingStepShell extends StatelessWidget {
  const OnboardingStepShell({
    required this.step,
    required this.total,
    required this.title,
    required this.body,
    required this.primaryLabel,
    required this.onPrimary,
    this.subtitle,
    this.onBack,
    this.showProgress = true,
    this.showEyebrow = true,
    super.key,
  });

  /// 1-indexed current step.
  final int step;

  /// Total step count. Always 3 in v1 but parametric so adding a step
  /// later is a one-line change.
  final int total;

  /// Page title — `pageTitle` typography. Rendered above the body.
  final String title;

  /// Optional lede paragraph below the title.
  final String? subtitle;

  /// Body slot — scrolls inside its own region so the footer stays
  /// sticky on small screens.
  final Widget body;

  /// Primary CTA label ("Get started", "Continue", "Start logging").
  final String primaryLabel;

  /// Tapped when the user advances. The caller decides whether to commit
  /// or just goToStep().
  final VoidCallback onPrimary;

  /// Back-tap handler. Step 1 omits this — no back from welcome.
  final VoidCallback? onBack;

  final bool showProgress;
  final bool showEyebrow;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (onBack != null)
          _TopBar(onBack: onBack!)
        else
          SizedBox(height: context.space.x4),
        if (showProgress)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: context.space.x5),
            child: _ProgressDots(step: step, total: total),
          ),
        Expanded(
          child: SingleChildScrollView(
            keyboardDismissBehavior:
                ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.fromLTRB(
              context.space.x6,
              context.space.x4,
              context.space.x6,
              context.space.x4,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (showEyebrow)
                  Padding(
                    padding: EdgeInsets.only(bottom: context.space.x05),
                    child: Text(
                      'STEP $step OF $total',
                      style: context.text.eyebrow.copyWith(
                        color: context.colors.ink3,
                      ),
                    ),
                  ),
                Text(title, style: context.text.pageTitle),
                if (subtitle != null) ...<Widget>[
                  SizedBox(height: context.space.x2),
                  Text(
                    subtitle!,
                    style: context.text.meta,
                  ),
                ],
                SizedBox(height: context.space.x5),
                body,
              ],
            ),
          ),
        ),
        _Footer(
          label: primaryLabel,
          onPressed: onPrimary,
        ),
      ],
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.space.x3,
        context.space.x2,
        context.space.x3,
        context.space.x2,
      ),
      child: Row(
        children: <Widget>[
          TextButton(
            onPressed: onBack,
            style: TextButton.styleFrom(
              foregroundColor: context.colors.ink2,
              padding: EdgeInsets.symmetric(
                horizontal: context.space.x3,
                vertical: context.space.x2,
              ),
              minimumSize: const Size(44, 44),
            ),
            child: Text('Back', style: context.text.body),
          ),
          const Spacer(),
        ],
      ),
    );
  }
}

class _ProgressDots extends StatelessWidget {
  const _ProgressDots({required this.step, required this.total});

  final int step;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        for (var i = 0; i < total; i++) ...<Widget>[
          if (i > 0) SizedBox(width: context.space.x1),
          Expanded(
            child: Container(
              height: 3,
              constraints: const BoxConstraints(maxWidth: 60),
              decoration: BoxDecoration(
                color: i < step ? context.colors.accent : context.colors.line2,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          context.space.x5,
          context.space.x3,
          context.space.x5,
          context.space.x6,
        ),
        child: SizedBox(
          height: 54,
          child: FilledButton(
            onPressed: onPressed,
            style: FilledButton.styleFrom(
              backgroundColor: context.colors.accent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(context.radius.r3),
              ),
              textStyle: context.text.bodyStrong.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            child: Text(label),
          ),
        ),
      ),
    );
  }
}
