import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/context_extensions.dart';
import 'motion.dart';

/// The progress ring that sits at the heart of every "today total" surface
/// (architecture §3 component inventory + T-09 anchor).
///
/// Drawing is delegated to a [CustomPainter] (T-19 forbids embedding the
/// mock's inline SVGs and we own no chart package yet) — the painter
/// strokes a background ring in `line2`, then strokes a foreground arc in
/// either accent (T-04 — "on-track") or `dangerOver` (T-05 — when consumed
/// exceeds the goal).
///
/// The widget never multiplies or divides numbers itself; it accepts a
/// fractional `progress` in `[0, 1+]` (caller clamps for visual sweep,
/// passes the raw ratio for the "over" check) and a pre-formatted
/// center-label string. Decimals stay in the day-summary provider.
class CalorieRing extends StatelessWidget {
  const CalorieRing({
    required this.progress,
    required this.overBudget,
    required this.centerLabel,
    required this.centerCaption,
    this.size = 88,
    this.strokeWidth = 8,
    super.key,
  });

  /// Sweep ratio. The painter clamps to `[0, 1]` for the arc geometry;
  /// values above 1 are handled by the [overBudget] flag, not by sweeping
  /// past the start.
  final double progress;

  /// True when `consumed > target` (T-05). Flips the arc color to danger.
  final bool overBudget;

  /// Big number in the center (e.g. `812`, or `−123`). Already formatted by
  /// the caller via `formatKcal` or equivalent — the ring is not a number
  /// formatter.
  final String centerLabel;

  /// Small uppercase caption beneath the big number (`left` / `over`).
  final String centerCaption;

  /// Outer size of the ring, in logical px. The mock uses 88 on mobile and
  /// 108 on web; the caller picks.
  final double size;

  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final arcColor = overBudget ? colors.dangerOver : colors.accent;

    // T-016 animation hooks. The arc sweep is driven by a
    // `TweenAnimationBuilder<double>` so a change in `progress` interpolates
    // over 600 ms instead of snapping. The over-budget color flip is a
    // 150 ms `AnimatedSwitcher` cross-fade — we key the inner `CustomPaint`
    // on the arc color so the switcher rebuilds the subtree when the color
    // flips (architect's B4 backup: hard fade, not `Color.lerp`, since the
    // accent→dangerOver midpoint reads muddy). Center number is NOT
    // animated (T-02 keeps tabular figures stable).
    final arcDuration = motion(context, const Duration(milliseconds: 600));
    final colorFadeDuration =
        motion(context, const Duration(milliseconds: 150));

    return Semantics(
      label: '$centerLabel kcal $centerCaption',
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            // Perf (Flutter doc — "Performance considerations" on
            // CustomPaint): the ring's `TweenAnimationBuilder` repaints
            // 60 fps for the 600 ms arc sweep. Wrapping the painter in
            // a `RepaintBoundary` isolates it from the surrounding
            // surface (the day-view scrollable, the macro bars below)
            // so a scroll or list-row rebuild upstream doesn't force
            // the arc to repaint, and the arc's per-frame invalidation
            // doesn't bubble back out.
            RepaintBoundary(
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: progress),
                duration: arcDuration,
                curve: Curves.easeInOut,
                builder: (context, value, _) {
                  return AnimatedSwitcher(
                    duration: colorFadeDuration,
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeOutCubic,
                    child: CustomPaint(
                      key: ValueKey<Color>(arcColor),
                      size: Size.square(size),
                      painter: _RingPainter(
                        progress: value,
                        arcColor: arcColor,
                        trackColor: colors.line2,
                        strokeWidth: strokeWidth,
                      ),
                    ),
                  );
                },
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                // The mock specs 20 px on mobile and 24 px on web. The token
                // table doesn't include those exact sizes — picking
                // `titleNumeric` (17 / 600) for compact and `bodyStrongNumeric`
                // scaled up to 24 for the larger ring lands on the visual
                // weight the designer drew without inventing a new typescale.
                Builder(builder: (_) {
                  final centerFontSize = size >= 100 ? 24.0 : 20.0;
                  return Text(
                    centerLabel,
                    style: context.text.titleNumeric.copyWith(
                      fontSize: centerFontSize,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.02 * centerFontSize,
                      color: overBudget ? colors.dangerOver : colors.ink,
                    ),
                  );
                },),
                Text(
                  centerCaption.toUpperCase(),
                  style: context.text.eyebrow.copyWith(
                    color: colors.ink2,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.progress,
    required this.arcColor,
    required this.trackColor,
    required this.strokeWidth,
  });

  final double progress;
  final Color arcColor;
  final Color trackColor;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.shortestSide - strokeWidth) / 2;

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = trackColor;
    canvas.drawCircle(center, radius, track);

    final sweep = progress.clamp(0.0, 1.0) * 2 * math.pi;
    if (sweep <= 0) return;

    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = arcColor;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      sweep,
      false,
      arc,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.arcColor != arcColor ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.strokeWidth != strokeWidth;
}
