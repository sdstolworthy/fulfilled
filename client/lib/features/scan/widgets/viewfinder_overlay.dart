import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme/context_extensions.dart';

/// Maximum cutout side, in logical pixels.
///
/// Caps the viewfinder square so it stays phone-sized on a wide canvas
/// (e.g. iPad landscape at 1024 × 768). Without the cap the 70%-of-shorter-
/// side rule would produce a ~538 px reticle which is awkward for
/// hand-held scanning. Resolves architect risk 3 — see
/// `specs/dev_tickets_barcode.md` SC-002 acceptance criteria.
const double _kMaxCutoutSide = 320.0;

/// Fraction of the shorter viewport side the cutout occupies before the
/// 320-px cap kicks in. Phones (~390 wide) land at ~273 px; iPad portrait
/// (~768 wide) lands at the cap.
const double _kCutoutFraction = 0.70;

/// Alpha applied to `colors.ink` for the dim surround. Numeric opacity on
/// a token color is the canonical pattern across the app (see
/// `MacroBar`, `weight_sparkline`, `LogEntrySheet`); T-01 still holds —
/// no raw hex.
const double _kDimAlpha = 0.62;

/// 1-px hairline tracing the cutout edge. Crisp against the dim and any
/// dark camera frame; not accent (T-04 reserves accent for actions).
const double _kEdgeStrokeWidth = 1.0;

/// Optional Yuka-style corner accents — short legs anchored at each
/// corner of the cutout. Visual "active aim" hint per PM §3 principle 1.
const double _kCornerLegLength = 24.0;
const double _kCornerStrokeWidth = 2.0;

/// Dim-and-cutout viewfinder for the barcode scanner route.
///
/// Sits between the [MobileScanner] preview and the top-bar buttons in
/// [ScanScreen]'s [Stack]. The painter fills the canvas with a
/// translucent ink layer and punches out a centered rounded square so
/// the user sees exactly where the decoder is looking. Geometry is
/// data-driven on the canvas size — no platform branch (T-15).
///
/// The cutout side is `min(shorter_side * 0.70, 320.0)`:
///   - 390 × 844 (iPhone 13 portrait) → 273 px.
///   - 768 × 1024 (iPad portrait) → 320 px (capped).
///   - 1024 × 768 (iPad landscape) → 320 px (capped).
///
/// The cap resolves architect risk 3 — see
/// `specs/dev_tickets_barcode.md` SC-002.
class ViewfinderOverlay extends StatelessWidget {
  const ViewfinderOverlay({super.key, this.cornerRadius});

  /// Overridable for tests; production reads `context.radius.r3`.
  final double? cornerRadius;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = cornerRadius ?? context.radius.r3;
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _ViewfinderPainter(
          dim: colors.ink.withValues(alpha: _kDimAlpha),
          edge: colors.surface,
          accent: colors.accent,
          cornerRadius: radius,
        ),
      ),
    );
  }
}

/// `@visibleForTesting` seam exposing the painter's geometry math.
///
/// The production painter is private (`_ViewfinderPainter`). Widget
/// tests assert the 320-px cap at three viewport sizes without
/// rendering to a [Canvas] — they call [ViewfinderGeometry.cutoutRectFor]
/// directly. Kept as a no-instance container so a future evolution of
/// the painter can't drift from the test contract: the painter calls
/// this same helper at paint time.
@visibleForTesting
class ViewfinderGeometry {
  const ViewfinderGeometry._();

  /// Computes the cutout [Rect] for a viewport of [size]. Pure function
  /// of [size]; same math the painter uses at paint time.
  static Rect cutoutRectFor(Size size) {
    final shorter = math.min(size.width, size.height);
    final side = math.min(shorter * _kCutoutFraction, _kMaxCutoutSide);
    final left = (size.width - side) / 2;
    final top = (size.height - side) / 2;
    return Rect.fromLTWH(left, top, side, side);
  }

  /// The 320-px cap as a public constant for test assertions.
  static const double maxCutoutSide = _kMaxCutoutSide;

  /// The 0.70 fraction as a public constant for test assertions.
  static const double cutoutFraction = _kCutoutFraction;
}

class _ViewfinderPainter extends CustomPainter {
  _ViewfinderPainter({
    required this.dim,
    required this.edge,
    required this.accent,
    required this.cornerRadius,
  });

  final Color dim;
  final Color edge;
  final Color accent;
  final double cornerRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final cutout = ViewfinderGeometry.cutoutRectFor(size);
    final rRect = RRect.fromRectAndRadius(
      cutout,
      Radius.circular(cornerRadius),
    );

    // Dim surround = full-canvas rect minus the rounded-rect cutout.
    final fullPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final cutoutPath = Path()..addRRect(rRect);
    final dimPath = Path.combine(
      PathOperation.difference,
      fullPath,
      cutoutPath,
    );

    final dimPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = dim;
    canvas.drawPath(dimPath, dimPaint);

    // 1-px hairline tracing the cutout edge so the rounded square reads
    // as a frame against arbitrary camera content.
    final edgePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _kEdgeStrokeWidth
      ..color = edge;
    canvas.drawRRect(rRect, edgePaint);

    // Four short corner accents — the Yuka-style "active aim" hint.
    // Each corner draws two short legs along the cutout edge that stop
    // before the arc, so the rounded corner reads cleanly. The accent
    // here is a decorative emphasis on the same frame the user is
    // already aiming at; T-04 reserves accent for actions and this is
    // the accent budget's one decorative call.
    _drawCornerAccents(canvas, cutout);
  }

  void _drawCornerAccents(Canvas canvas, Rect r) {
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _kCornerStrokeWidth
      ..strokeCap = StrokeCap.round
      ..color = accent;

    // Inset legs so they sit on the straight portion of the edge, not
    // inside the corner arc. The arc radius is `cornerRadius`; starting
    // each leg at `r.left + cornerRadius` (etc.) keeps the geometry
    // clean even when the radius is large relative to the leg length.
    final leg = _kCornerLegLength;
    final cr = cornerRadius;

    // Top-left.
    canvas.drawLine(
      Offset(r.left, r.top + cr),
      Offset(r.left, r.top + cr + leg),
      p,
    );
    canvas.drawLine(
      Offset(r.left + cr, r.top),
      Offset(r.left + cr + leg, r.top),
      p,
    );

    // Top-right.
    canvas.drawLine(
      Offset(r.right, r.top + cr),
      Offset(r.right, r.top + cr + leg),
      p,
    );
    canvas.drawLine(
      Offset(r.right - cr, r.top),
      Offset(r.right - cr - leg, r.top),
      p,
    );

    // Bottom-left.
    canvas.drawLine(
      Offset(r.left, r.bottom - cr),
      Offset(r.left, r.bottom - cr - leg),
      p,
    );
    canvas.drawLine(
      Offset(r.left + cr, r.bottom),
      Offset(r.left + cr + leg, r.bottom),
      p,
    );

    // Bottom-right.
    canvas.drawLine(
      Offset(r.right, r.bottom - cr),
      Offset(r.right, r.bottom - cr - leg),
      p,
    );
    canvas.drawLine(
      Offset(r.right - cr, r.bottom),
      Offset(r.right - cr - leg, r.bottom),
      p,
    );
  }

  @override
  bool shouldRepaint(covariant _ViewfinderPainter oldDelegate) =>
      oldDelegate.dim != dim ||
      oldDelegate.edge != edge ||
      oldDelegate.accent != accent ||
      oldDelegate.cornerRadius != cornerRadius;
}
