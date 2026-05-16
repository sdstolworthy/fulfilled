import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../../../domain/enums.dart';
import '../../../domain/units/weight.dart';
import '../../../domain/weight.dart';
import '../../../theme/context_extensions.dart';

/// The small inline weight chart on the expanded right rail.
///
/// **Not a replacement for `WeightSparkline`.** The component inventory
/// gives that widget a `dense` flag for this exact slot. Until that widget
/// is implemented, the today screen renders this self-contained painter
/// so the rail isn't empty. Flag for lift: when the real
/// `WeightSparkline(dense: true)` ships, this file can be deleted and the
/// expanded right rail switches to it in one line.
///
/// T-19: no SVG; the chart is a `CustomPainter` cubic path. Decimal math
/// happens upstream — this widget only ever consumes doubles for pixel
/// placement, after [formatWeight] has rendered the header number.
///
/// **Unit handling.** The active [WeightUnit] arrives as a constructor
/// param — the screen-level Consumer reads `weightUnitProvider`. This
/// widget itself does not subscribe so it stays embeddable in tests and
/// in surfaces that drive the unit from a non-default provider.
class MiniWeightSparkline extends StatelessWidget {
  const MiniWeightSparkline({
    required this.points,
    required this.unit,
    super.key,
  });

  /// Ascending-by-date series. Empty list ⇒ empty state.
  final List<WeightSeriesPoint> points;

  /// Active display unit for the header and delta. The painter itself
  /// is unit-agnostic — pixel placement is normalised against
  /// [WeightSeriesPoint.weightKg], not against the displayed number.
  final WeightUnit unit;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(context.radius.r3),
      ),
      padding: EdgeInsets.all(context.space.x4 + 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'Weight · last 30 days',
            style: context.text.eyebrow.copyWith(color: colors.ink3),
          ),
          SizedBox(height: context.space.x3),
          if (points.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(vertical: context.space.x4),
              child: Text(
                'Log your first weight to see a trend.',
                style: context.text.meta,
              ),
            )
          else ...<Widget>[
            _Header(points: points, unit: unit),
            SizedBox(height: context.space.x2),
            SizedBox(
              height: 64,
              child: CustomPaint(
                painter: _SparklinePainter(
                  points: points,
                  lineColor: colors.accent,
                  fillTop: colors.accent.withValues(alpha: 0.18),
                  fillBottom: colors.accent.withValues(alpha: 0.0),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.points, required this.unit});
  final List<WeightSeriesPoint> points;
  final WeightUnit unit;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final latest = points.last.weightKg;
    final first = points.first.weightKg;
    final delta = latest - first;

    // Stone collapses to the composite ("12 st 7 lb") which already
    // inlines its units — render a single `Text` and drop the separate
    // suffix (architect §3.13 row). kg / lb keep the two-`Text` split.
    final Widget headerNumber;
    if (unit == WeightUnit.st) {
      headerNumber = Text(
        formatWeight(latest, unit),
        style: context.text.titleNumeric.copyWith(fontSize: 22),
      );
    } else {
      headerNumber = Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: <Widget>[
          Text(
            formatWeight(latest, unit),
            style: context.text.titleNumeric.copyWith(fontSize: 22),
          ),
          SizedBox(width: context.space.x1),
          Text(
            unit.shortLabel,
            style: context.text.meta.copyWith(color: colors.ink2),
          ),
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        Expanded(child: headerNumber),
        Text(
          _deltaLabel(delta),
          style: context.text.metaNumeric.copyWith(
            color: colors.accent,
            fontWeight: FontWeight.w600,
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  String _deltaLabel(Decimal delta) {
    if (delta == Decimal.zero) {
      // Architect §3.13 row: the `±0.0 kg` zero case collapses to
      // `±0 st` under stone (the composite would inline its own units
      // and `±0 st 0 lb` reads worse than `±0 st`). Keep the existing
      // shape for kg / lb.
      return unit == WeightUnit.st ? '±0 st' : '±0.0 ${unit.shortLabel}';
    }
    final magnitude = formatWeightWithUnit(delta.abs(), unit);
    // Use a U+2212 minus glyph; ASCII + sign for positives so the glyph
    // is visually crisp at small size. The accent color signals "good"
    // for either direction in the mock; the consumer of the screen can
    // colorize differently when goal direction lands.
    return delta < Decimal.zero ? '−$magnitude' : '+$magnitude';
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({
    required this.points,
    required this.lineColor,
    required this.fillTop,
    required this.fillBottom,
  });

  final List<WeightSeriesPoint> points;
  final Color lineColor;
  final Color fillTop;
  final Color fillBottom;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty || size.width <= 0 || size.height <= 0) return;
    final xs = <double>[];
    final ys = <double>[];

    double minY = double.infinity;
    double maxY = double.negativeInfinity;
    for (final p in points) {
      final v = p.weightKg.toDouble();
      if (v < minY) minY = v;
      if (v > maxY) maxY = v;
    }
    if (!minY.isFinite || !maxY.isFinite) return;
    if (minY == maxY) {
      minY -= 0.5;
      maxY += 0.5;
    }
    final pad = 4.0;
    final usableHeight = size.height - pad * 2;
    final usableWidth = size.width;

    for (var i = 0; i < points.length; i++) {
      final x = points.length == 1
          ? usableWidth / 2
          : (i / (points.length - 1)) * usableWidth;
      final norm = (points[i].weightKg.toDouble() - minY) / (maxY - minY);
      final y = pad + (1 - norm) * usableHeight;
      xs.add(x);
      ys.add(y);
    }

    final path = Path()..moveTo(xs.first, ys.first);
    for (var i = 1; i < xs.length; i++) {
      // Smoothing via simple mid-point curves keeps the line consistent
      // with the mock without pulling in a chart package.
      final cx = (xs[i - 1] + xs[i]) / 2;
      path.cubicTo(cx, ys[i - 1], cx, ys[i], xs[i], ys[i]);
    }

    final fillPath = Path.from(path)
      ..lineTo(xs.last, size.height)
      ..lineTo(xs.first, size.height)
      ..close();

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[fillTop, fillBottom],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawPath(fillPath, fillPaint);

    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = lineColor;
    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      old.points != points ||
      old.lineColor != lineColor ||
      old.fillTop != fillTop ||
      old.fillBottom != fillBottom;
}
