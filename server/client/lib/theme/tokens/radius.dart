import 'package:flutter/material.dart';

/// Corner-radius tokens. Architecture §2.3.
///
/// `rPill` is large enough that any container shorter than it renders a true
/// pill — use it on chips, the FAB, and segmented controls.
@immutable
class AppRadius {
  final double r1;
  final double r2;
  final double r3;
  final double r4;
  final double r5;
  final double rPill;

  const AppRadius({
    this.r1 = 8,
    this.r2 = 12,
    this.r3 = 14,
    this.r4 = 18,
    this.r5 = 28,
    this.rPill = 999,
  });

  static const AppRadius standard = AppRadius();

  AppRadius copyWith({
    double? r1,
    double? r2,
    double? r3,
    double? r4,
    double? r5,
    double? rPill,
  }) {
    return AppRadius(
      r1: r1 ?? this.r1,
      r2: r2 ?? this.r2,
      r3: r3 ?? this.r3,
      r4: r4 ?? this.r4,
      r5: r5 ?? this.r5,
      rPill: rPill ?? this.rPill,
    );
  }
}
