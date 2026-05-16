import 'package:flutter/material.dart';

/// Spacing tokens. 4 px base; flat double constants. Architecture §2.3.
///
/// Never write a raw spacing literal in widget code — T-01. If a screen needs
/// a value that doesn't appear here, the spec is the conversation, not a
/// magic number in a `Padding`.
@immutable
class AppSpace {
  final double x05;
  final double x1;
  final double x2;
  final double x3;
  final double x4;
  final double x5;
  final double x6;
  final double x8;

  const AppSpace({
    this.x05 = 2,
    this.x1 = 4,
    this.x2 = 8,
    this.x3 = 12,
    this.x4 = 16,
    this.x5 = 20,
    this.x6 = 24,
    this.x8 = 32,
  });

  static const AppSpace standard = AppSpace();

  AppSpace copyWith({
    double? x05,
    double? x1,
    double? x2,
    double? x3,
    double? x4,
    double? x5,
    double? x6,
    double? x8,
  }) {
    return AppSpace(
      x05: x05 ?? this.x05,
      x1: x1 ?? this.x1,
      x2: x2 ?? this.x2,
      x3: x3 ?? this.x3,
      x4: x4 ?? this.x4,
      x5: x5 ?? this.x5,
      x6: x6 ?? this.x6,
      x8: x8 ?? this.x8,
    );
  }
}
