import 'package:flutter/material.dart';

import '../../../theme/context_extensions.dart';

/// Welcome step (1 of 3). Logo + headline + features list + the primary
/// CTA. **No "I already have an account" affordance** — PM Risk 2 removed
/// it from v1; it returns alongside real auth in v2. Do not re-add it
/// without a PM ruling on the corresponding decision doc.
///
/// The footer button is supplied by `OnboardingStepShell`. This widget
/// fills the body slot only.
class Step1Welcome extends StatelessWidget {
  const Step1Welcome({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        SizedBox(height: context.space.x6),
        const _Logo(),
        SizedBox(height: context.space.x6),
        Text(
          'Track food without the noise.',
          style: context.text.hero,
          textAlign: TextAlign.center,
        ),
        SizedBox(height: context.space.x3),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: Text(
            "A calm, fast logger backed by OpenFoodFacts. No ads, no streak guilt, no upsells.",
            style: context.text.meta.copyWith(color: context.colors.ink2),
            textAlign: TextAlign.center,
          ),
        ),
        SizedBox(height: context.space.x8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const <Widget>[
              _FeatureRow(
                icon: Icons.search,
                label: 'Search 2M+ foods or scan a barcode',
              ),
              _FeatureRow(
                icon: Icons.check_rounded,
                label: 'One-tap recents & frequents',
              ),
              _FeatureRow(
                icon: Icons.bar_chart_rounded,
                label: "Weight trend, macros, that's it",
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: 84,
      height: 84,
      decoration: BoxDecoration(
        color: colors.accent,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Icon(
        Icons.favorite_border_rounded,
        size: 40,
        // FX-006 / T-01: glyph on the accent logo routes through the
        // `surface` token rather than `Colors.white`.
        color: colors.surface,
      ),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.space.x2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.only(top: context.space.x05),
            child: Icon(icon, size: 20, color: context.colors.accent),
          ),
          SizedBox(width: context.space.x3),
          Expanded(
            child: Text(label, style: context.text.body),
          ),
        ],
      ),
    );
  }
}
