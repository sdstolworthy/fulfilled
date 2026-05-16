import 'package:flutter/material.dart';

import 'tokens/colors.dart';
import 'tokens/radius.dart';
import 'tokens/space.dart';
import 'tokens/text.dart';

export 'tokens/colors.dart';
export 'tokens/radius.dart';
export 'tokens/space.dart';
export 'tokens/text.dart';

/// The single `ThemeExtension` that bundles every design-token family.
///
/// Consumed via `Theme.of(context).extension<AppTokens>()!` or — preferred —
/// the shorthand getters in `context_extensions.dart` (`context.tokens`,
/// `context.colors`, `context.space`, `context.radius`, `context.text`).
///
/// One extension over four (one per family) is deliberate: it makes
/// `copyWith` cheap, the lookup a single `Map` read, and gives the dark
/// theme migration a single seam to flip when v2 lands.
@immutable
class AppTokens extends ThemeExtension<AppTokens> {
  final AppColors colors;
  final AppText text;
  final AppSpace space;
  final AppRadius radius;

  const AppTokens({
    required this.colors,
    required this.text,
    required this.space,
    required this.radius,
  });

  /// The v1 light tokens. The only call site is `theme_data.dart`.
  factory AppTokens.light() {
    const colors = AppColors.light;
    return AppTokens(
      colors: colors,
      text: AppText.light(colors),
      space: AppSpace.standard,
      radius: AppRadius.standard,
    );
  }

  @override
  AppTokens copyWith({
    AppColors? colors,
    AppText? text,
    AppSpace? space,
    AppRadius? radius,
  }) {
    return AppTokens(
      colors: colors ?? this.colors,
      text: text ?? this.text,
      space: space ?? this.space,
      radius: radius ?? this.radius,
    );
  }

  @override
  AppTokens lerp(ThemeExtension<AppTokens>? other, double t) {
    // Tokens are discrete; cross-fading hex values produces muddy
    // intermediates. Snap at t=0.5 so theme transitions stay crisp once dark
    // mode arrives in v2.
    if (other is! AppTokens) return this;
    return t < 0.5 ? this : other;
  }
}
