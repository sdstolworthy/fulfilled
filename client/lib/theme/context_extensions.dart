import 'package:flutter/material.dart';

import 'tokens.dart';

/// `BuildContext` extensions that hide the `Theme.of(...).extension<...>()!`
/// boilerplate. Reading tokens should be a one-liner — anything more verbose
/// invites raw literals back into widgets, and raw literals violate T-01.
///
/// Usage:
/// ```dart
/// final pad = context.space.x4;
/// final card = context.colors.surface;
/// final h = context.text.title;
/// ```
extension AppTokensContext on BuildContext {
  AppTokens get tokens {
    final ext = Theme.of(this).extension<AppTokens>();
    assert(
      ext != null,
      'AppTokens missing from ThemeData. '
      'Did you wrap MaterialApp.router with the theme from theme_data.dart?',
    );
    return ext!;
  }

  AppColors get colors => tokens.colors;
  AppText get text => tokens.text;
  AppSpace get space => tokens.space;
  AppRadius get radius => tokens.radius;
}
