import 'package:flutter/material.dart';

/// Color tokens for the Fulfilled v1 client.
///
/// Hex values copied verbatim from `specs/ui_mocks/INDEX.html` and the
/// architecture doc (§2.1). **Never introduce a new hex in widget code** —
/// new semantic meanings get a new alias here, not a new color. T-01 enforces
/// this discipline; this file is the only legal place to write a hex literal.
///
/// Dark mode ships in v2 (PM Risk 5). The tokens are theme-extension-backed so
/// adding a dark variant is an instance swap, not a rewrite.
@immutable
class AppColors {
  // Surfaces
  final Color bg;
  final Color surface;
  final Color line;
  final Color line2;

  // Ink (text)
  final Color ink;
  final Color ink2;
  final Color ink3;

  // Brand
  final Color accent;
  final Color accentSoft;
  final Color accentLine;

  // Darker accent siblings, derived from `accent` by mixing toward black.
  // Authored as concrete tokens (not call-site `Color.lerp`) so widget code
  // never references `Colors.black` to "darken" the accent. FX-006.
  //
  // - `accentDark`  — accent mixed 15% toward black. Used as the bottom stop
  //   of the screen-07 goal-hero gradient (see `GoalActiveCard`).
  // - `accentHover` — accent mixed  8% toward black. Used as the web/desktop
  //   hover tint on accent-filled controls (see `LogFoodFab`).
  final Color accentDark;
  final Color accentHover;

  // Macros — data-only. T-03: never use these for buttons, links, focus, or
  // any non-macro purpose.
  final Color protein;
  final Color carbs;
  final Color fat;

  // Macros on the dark-teal goal hero (screen 07). T-03 still applies — these
  // are macro tokens, just calibrated for the dark gradient background.
  final Color proteinOnDark;
  final Color carbsOnDark;
  final Color fatOnDark;
  final Color mutedTealOnDark;

  // Status
  final Color danger;
  final Color dangerSoft;
  final Color dangerOver;
  final Color goalLine;
  final Color highlight;

  // Empty-meal dot color used by `MealSection` when the meal has zero entries.
  // Per architecture §9 screen 01 gotcha: it's a deliberate per-empty color,
  // not the regular meal dot at low opacity.
  final Color emptyDot;

  // User-uploaded food thumbnail (the `YOU` badge in `SearchResultRow`).
  // The tan/brown pair is mock-specific (`INDEX.html` search screen) and
  // does NOT collapse to any existing accent/macro token. T-014/B2 lift.
  final Color userThumbBg;
  final Color userThumbInk;

  // Disabled-accent surface for the custom-food primary CTA when validation
  // is failing. Slightly desaturated teal (`#C4D2D0`) — not interchangeable
  // with `accentSoft` (which is the *background* container for active accent
  // content). Used as `Material.color` on the greyed Save button.
  final Color accentDisabled;

  // Material `ColorScheme.shadow` / `.scrim`. Pure-black alphas — the only
  // place we let an alpha-black through is the theme assembly layer; widget
  // code should never spell these out directly.
  final Color shadow;
  final Color scrim;

  const AppColors({
    required this.bg,
    required this.surface,
    required this.line,
    required this.line2,
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.accent,
    required this.accentSoft,
    required this.accentLine,
    required this.accentDark,
    required this.accentHover,
    required this.protein,
    required this.carbs,
    required this.fat,
    required this.proteinOnDark,
    required this.carbsOnDark,
    required this.fatOnDark,
    required this.mutedTealOnDark,
    required this.danger,
    required this.dangerSoft,
    required this.dangerOver,
    required this.goalLine,
    required this.highlight,
    required this.emptyDot,
    required this.userThumbBg,
    required this.userThumbInk,
    required this.accentDisabled,
    required this.shadow,
    required this.scrim,
  });

  /// The v1 light palette. Exact values are the contract; do not edit without
  /// a designer hand-off.
  static const AppColors light = AppColors(
    bg: Color(0xFFFAFAF8),
    surface: Color(0xFFFFFFFF),
    line: Color(0xFFE6E5E0),
    line2: Color(0xFFEFEEE9),
    ink: Color(0xFF1A1D1A),
    ink2: Color(0xFF5C625C),
    ink3: Color(0xFF9AA09A),
    accent: Color(0xFF1F5F5B),
    accentSoft: Color(0xFFE4EEEC),
    accentLine: Color(0xFFB6D2CF),
    accentDark: Color(0xFF1A514D),
    accentHover: Color(0xFF1D5754),
    protein: Color(0xFFC77B3A),
    carbs: Color(0xFF6E8B3D),
    fat: Color(0xFFB6883F),
    proteinOnDark: Color(0xFFE8AE7C),
    carbsOnDark: Color(0xFFB7CC8A),
    fatOnDark: Color(0xFFDDB985),
    mutedTealOnDark: Color(0xFFA9CBC8),
    danger: Color(0xFFB5552E),
    dangerSoft: Color(0xFFFBEBE2),
    dangerOver: Color(0xFFB5552E),
    goalLine: Color(0xFFC77B3A),
    highlight: Color(0xFFFFF1B8),
    emptyDot: Color(0xFFD9D6CD),
    userThumbBg: Color(0xFFF5EFE6),
    userThumbInk: Color(0xFF8C6B2C),
    accentDisabled: Color(0xFFC4D2D0),
    shadow: Color(0x1A000000),
    scrim: Color(0x66000000),
  );

  AppColors copyWith({
    Color? bg,
    Color? surface,
    Color? line,
    Color? line2,
    Color? ink,
    Color? ink2,
    Color? ink3,
    Color? accent,
    Color? accentSoft,
    Color? accentLine,
    Color? accentDark,
    Color? accentHover,
    Color? protein,
    Color? carbs,
    Color? fat,
    Color? proteinOnDark,
    Color? carbsOnDark,
    Color? fatOnDark,
    Color? mutedTealOnDark,
    Color? danger,
    Color? dangerSoft,
    Color? dangerOver,
    Color? goalLine,
    Color? highlight,
    Color? emptyDot,
    Color? userThumbBg,
    Color? userThumbInk,
    Color? accentDisabled,
    Color? shadow,
    Color? scrim,
  }) {
    return AppColors(
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      line: line ?? this.line,
      line2: line2 ?? this.line2,
      ink: ink ?? this.ink,
      ink2: ink2 ?? this.ink2,
      ink3: ink3 ?? this.ink3,
      accent: accent ?? this.accent,
      accentSoft: accentSoft ?? this.accentSoft,
      accentLine: accentLine ?? this.accentLine,
      accentDark: accentDark ?? this.accentDark,
      accentHover: accentHover ?? this.accentHover,
      protein: protein ?? this.protein,
      carbs: carbs ?? this.carbs,
      fat: fat ?? this.fat,
      proteinOnDark: proteinOnDark ?? this.proteinOnDark,
      carbsOnDark: carbsOnDark ?? this.carbsOnDark,
      fatOnDark: fatOnDark ?? this.fatOnDark,
      mutedTealOnDark: mutedTealOnDark ?? this.mutedTealOnDark,
      danger: danger ?? this.danger,
      dangerSoft: dangerSoft ?? this.dangerSoft,
      dangerOver: dangerOver ?? this.dangerOver,
      goalLine: goalLine ?? this.goalLine,
      highlight: highlight ?? this.highlight,
      emptyDot: emptyDot ?? this.emptyDot,
      userThumbBg: userThumbBg ?? this.userThumbBg,
      userThumbInk: userThumbInk ?? this.userThumbInk,
      accentDisabled: accentDisabled ?? this.accentDisabled,
      shadow: shadow ?? this.shadow,
      scrim: scrim ?? this.scrim,
    );
  }
}
