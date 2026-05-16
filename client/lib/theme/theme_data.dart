import 'package:flutter/material.dart';

import 'tokens.dart';

/// The single light theme for v1. Dark mode is out of scope (PM Risk 5).
///
/// Assembled from `AppTokens.light()` so every widget reads the same hex/space
/// values via `context.tokens`. Material's `ColorScheme.fromSeed` would
/// generate values that conflict with the designer palette — we hand-build
/// the scheme from `AppColors` to stay 1:1 with `INDEX.html`.
ThemeData buildLightTheme() {
  final tokens = AppTokens.light();
  final c = tokens.colors;

  final colorScheme = ColorScheme(
    brightness: Brightness.light,
    primary: c.accent,
    onPrimary: c.surface,
    primaryContainer: c.accentSoft,
    onPrimaryContainer: c.accent,
    secondary: c.accent,
    onSecondary: c.surface,
    secondaryContainer: c.accentSoft,
    onSecondaryContainer: c.accent,
    error: c.danger,
    onError: c.surface,
    errorContainer: c.dangerSoft,
    onErrorContainer: c.danger,
    surface: c.surface,
    onSurface: c.ink,
    surfaceContainerHighest: c.line2,
    outline: c.line,
    outlineVariant: c.line2,
    shadow: const Color(0x1A000000),
    scrim: const Color(0x66000000),
    inverseSurface: c.ink,
    onInverseSurface: c.surface,
    inversePrimary: c.accentSoft,
  );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: c.bg,
    fontFamily: 'Inter',
    visualDensity: VisualDensity.standard,
    splashFactory: InkSparkle.splashFactory,
    extensions: <ThemeExtension<dynamic>>[tokens],
  );

  return base.copyWith(
    textTheme: base.textTheme.copyWith(
      displayLarge: tokens.text.display,
      displayMedium: tokens.text.hero,
      headlineLarge: tokens.text.pageTitle,
      titleLarge: tokens.text.title,
      titleMedium: tokens.text.bodyStrong,
      bodyLarge: tokens.text.body,
      bodyMedium: tokens.text.body,
      bodySmall: tokens.text.meta,
      labelLarge: tokens.text.bodyStrong,
      labelMedium: tokens.text.meta,
      labelSmall: tokens.text.eyebrow,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: c.bg,
      foregroundColor: c.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: tokens.text.title,
      centerTitle: false,
    ),
    dividerTheme: DividerThemeData(color: c.line, thickness: 1, space: 1),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: c.surface,
      indicatorColor: c.accentSoft,
      labelTextStyle: WidgetStatePropertyAll(tokens.text.meta),
      iconTheme: WidgetStatePropertyAll(IconThemeData(color: c.ink, size: 22)),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: 84, // matches INDEX touch-target spec
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: c.surface,
      selectedIconTheme: IconThemeData(color: c.accent, size: 22),
      unselectedIconTheme: IconThemeData(color: c.ink2, size: 22),
      selectedLabelTextStyle: tokens.text.bodyStrong.copyWith(color: c.accent),
      unselectedLabelTextStyle: tokens.text.body.copyWith(color: c.ink2),
      indicatorColor: c.accentSoft,
      useIndicator: true,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(tokens.radius.r2),
        borderSide: BorderSide(color: c.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(tokens.radius.r2),
        borderSide: BorderSide(color: c.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(tokens.radius.r2),
        borderSide: BorderSide(color: c.accent, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(tokens.radius.r2),
        borderSide: BorderSide(color: c.danger),
      ),
      hintStyle: tokens.text.body.copyWith(color: c.ink3),
      contentPadding: EdgeInsets.symmetric(
        horizontal: tokens.space.x4,
        vertical: tokens.space.x3,
      ),
    ),
    cardTheme: CardThemeData(
      color: c.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: c.line),
        borderRadius: BorderRadius.circular(tokens.radius.r3),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: c.accent,
      foregroundColor: c.surface,
      elevation: 6,
      focusElevation: 6,
      hoverElevation: 6,
      shape: const StadiumBorder(),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.ink,
      contentTextStyle: tokens.text.body.copyWith(color: c.surface),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
