import 'dart:ui';

import 'package:flutter/material.dart';

import 'colors.dart';

/// Typography tokens. Inter, weights 400/500/600/700 only, scale exactly per
/// `INDEX.html` and architecture §2.2. T-02: every rendered number flows
/// through a tabular-figures variant or `NumberText`; don't apply tabular
/// figures globally to body text — it breaks headlines.
@immutable
class AppText {
  final TextStyle eyebrow; // 11 / 600
  final TextStyle meta; // 13 / 400
  final TextStyle body; // 14 / 500
  final TextStyle bodyStrong; // 15 / 600
  final TextStyle title; // 17 / 600
  final TextStyle pageTitle; // 22 / 600
  final TextStyle hero; // 32 / 600
  final TextStyle display; // 42 / 600 — onboarding/goal hero

  // Tabular-figures variants. Use these everywhere a digit appears. Adding the
  // feature at the leaf widget (rather than the global theme) keeps body copy
  // proportional.
  final TextStyle metaNumeric;
  final TextStyle bodyNumeric;
  final TextStyle bodyStrongNumeric;
  final TextStyle titleNumeric;
  final TextStyle heroNumeric;
  final TextStyle displayNumeric;

  const AppText({
    required this.eyebrow,
    required this.meta,
    required this.body,
    required this.bodyStrong,
    required this.title,
    required this.pageTitle,
    required this.hero,
    required this.display,
    required this.metaNumeric,
    required this.bodyNumeric,
    required this.bodyStrongNumeric,
    required this.titleNumeric,
    required this.heroNumeric,
    required this.displayNumeric,
  });

  /// Build the canonical text tokens against the light palette. Once the Inter
  /// font assets are bundled in `assets/fonts/` (see pubspec), all of these
  /// resolve to Inter; until then Flutter falls back through the platform
  /// default — that fallback is acceptable in CI/tests, not in production.
  factory AppText.light(AppColors colors) {
    const family = 'Inter';
    const tabular = <FontFeature>[FontFeature.tabularFigures()];

    final eyebrow = TextStyle(
      fontFamily: family,
      fontSize: 11,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.10 * 11,
      color: colors.ink2,
      height: 1.2,
    );

    final meta = TextStyle(
      fontFamily: family,
      fontSize: 13,
      fontWeight: FontWeight.w400,
      color: colors.ink2,
      height: 1.4,
    );

    final body = TextStyle(
      fontFamily: family,
      fontSize: 14,
      fontWeight: FontWeight.w500,
      color: colors.ink,
      height: 1.45,
    );

    final bodyStrong = TextStyle(
      fontFamily: family,
      fontSize: 15,
      fontWeight: FontWeight.w600,
      color: colors.ink,
      height: 1.4,
    );

    final title = TextStyle(
      fontFamily: family,
      fontSize: 17,
      fontWeight: FontWeight.w600,
      color: colors.ink,
      height: 1.3,
    );

    final pageTitle = TextStyle(
      fontFamily: family,
      fontSize: 22,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.01 * 22,
      color: colors.ink,
      height: 1.2,
    );

    final hero = TextStyle(
      fontFamily: family,
      fontSize: 32,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.02 * 32,
      color: colors.ink,
      height: 1.1,
    );

    final display = TextStyle(
      fontFamily: family,
      fontSize: 42,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.02 * 42,
      color: colors.ink,
      height: 1.05,
    );

    return AppText(
      eyebrow: eyebrow,
      meta: meta,
      body: body,
      bodyStrong: bodyStrong,
      title: title,
      pageTitle: pageTitle,
      hero: hero,
      display: display,
      metaNumeric: meta.copyWith(fontFeatures: tabular),
      bodyNumeric: body.copyWith(fontFeatures: tabular),
      bodyStrongNumeric: bodyStrong.copyWith(fontFeatures: tabular),
      titleNumeric: title.copyWith(fontFeatures: tabular),
      heroNumeric: hero.copyWith(fontFeatures: tabular),
      displayNumeric: display.copyWith(fontFeatures: tabular),
    );
  }

  AppText copyWith({
    TextStyle? eyebrow,
    TextStyle? meta,
    TextStyle? body,
    TextStyle? bodyStrong,
    TextStyle? title,
    TextStyle? pageTitle,
    TextStyle? hero,
    TextStyle? display,
    TextStyle? metaNumeric,
    TextStyle? bodyNumeric,
    TextStyle? bodyStrongNumeric,
    TextStyle? titleNumeric,
    TextStyle? heroNumeric,
    TextStyle? displayNumeric,
  }) {
    return AppText(
      eyebrow: eyebrow ?? this.eyebrow,
      meta: meta ?? this.meta,
      body: body ?? this.body,
      bodyStrong: bodyStrong ?? this.bodyStrong,
      title: title ?? this.title,
      pageTitle: pageTitle ?? this.pageTitle,
      hero: hero ?? this.hero,
      display: display ?? this.display,
      metaNumeric: metaNumeric ?? this.metaNumeric,
      bodyNumeric: bodyNumeric ?? this.bodyNumeric,
      bodyStrongNumeric: bodyStrongNumeric ?? this.bodyStrongNumeric,
      titleNumeric: titleNumeric ?? this.titleNumeric,
      heroNumeric: heroNumeric ?? this.heroNumeric,
      displayNumeric: displayNumeric ?? this.displayNumeric,
    );
  }
}
