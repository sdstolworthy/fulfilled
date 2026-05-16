import 'dart:math' as math;

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../domain/enums.dart';
import '../../../domain/units/weight.dart';
import '../../../domain/weight.dart';
import '../../../providers/goal_providers.dart';
import '../../../providers/weight_providers.dart';
import '../../../theme/context_extensions.dart';
import '../../../theme/tokens.dart';

/// Sparkline card for screen 06 — header (Trend + range chips), chart,
/// and axis labels.
///
/// **T-19 — no chart dependencies.** Two lines (actual + moving-avg
/// dashed) and an area gradient under the actual line, painted with a
/// single `CustomPainter`. The chart is decorative-looking but every
/// pixel is computed in Dart against the actual data; there's no SVG.
///
/// **Moving-avg suffix.** `WeightSeriesPoint.movingAvg7d` is null on the
/// first six points of the *underlying* history. When a short range (1W)
/// includes a leading point with `movingAvg7d == null`, the dashed line
/// only renders over the suffix where the value is non-null.
///
/// **Empty state.** When the series for the active range is empty:
///   - A single dashed goal line is drawn (if `activeGoalProvider` has a
///     `targetWeightKg`), with no actual-weight curve.
///   - A centered "Log your first weight" CTA replaces the chart body.
class WeightSparklineCard extends ConsumerWidget {
  const WeightSparklineCard({
    required this.range,
    required this.onRangeChanged,
    required this.onLogWeight,
    super.key,
  });

  final WeightRange range;
  final ValueChanged<WeightRange> onRangeChanged;
  final VoidCallback onLogWeight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seriesAsync = ref.watch(weightSeriesProvider(range));
    final goalAsync = ref.watch(activeGoalProvider);

    final goalTarget = goalAsync.maybeWhen(
      data: (g) => g.targetWeightKg,
      orElse: () => null,
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.space.x5,
        0,
        context.space.x5,
        context.space.x3,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: context.colors.surface,
          borderRadius: BorderRadius.circular(context.radius.r4),
          border: Border.all(color: context.colors.line),
        ),
        padding: EdgeInsets.fromLTRB(
          context.space.x4,
          context.space.x3,
          context.space.x4,
          context.space.x3,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _Header(
              range: range,
              onRangeChanged: onRangeChanged,
            ),
            SizedBox(height: context.space.x2),
            SizedBox(
              height: 160,
              child: seriesAsync.when(
                data: (points) => _ChartBody(
                  points: points,
                  goalKg: goalTarget,
                  onLogWeight: onLogWeight,
                ),
                loading: () => const _ChartSkeleton(),
                error: (_, __) => _ChartBody(
                  points: const <WeightSeriesPoint>[],
                  goalKg: goalTarget,
                  onLogWeight: onLogWeight,
                ),
              ),
            ),
            SizedBox(height: context.space.x1),
            seriesAsync.maybeWhen(
              data: (points) => _AxisLabels(points: points, range: range),
              orElse: () => const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.range, required this.onRangeChanged});

  final WeightRange range;
  final ValueChanged<WeightRange> onRangeChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(child: Text('Trend', style: context.text.title.copyWith(fontSize: 13))),
        _RangeChips(selected: range, onChange: onRangeChanged),
      ],
    );
  }
}

class _RangeChips extends StatelessWidget {
  const _RangeChips({required this.selected, required this.onChange});

  final WeightRange selected;
  final ValueChanged<WeightRange> onChange;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(context.space.x05 + 1),
      decoration: BoxDecoration(
        color: context.colors.line2,
        borderRadius: BorderRadius.circular(context.radius.r1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final r in WeightRange.values)
            _Chip(
              label: r.label,
              selected: r == selected,
              onTap: () => onChange(r),
            ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: 'Range $label',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(context.radius.r1 - 2),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: EdgeInsets.symmetric(
            horizontal: context.space.x2 + 2,
            vertical: context.space.x05 + 3,
          ),
          decoration: BoxDecoration(
            color: selected ? context.colors.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(context.radius.r1 - 2),
            boxShadow: selected
                ? <BoxShadow>[
                    BoxShadow(
                      color: context.colors.ink.withValues(alpha: 0.06),
                      blurRadius: 2,
                      offset: const Offset(0, 1),
                    ),
                  ]
                : const <BoxShadow>[],
          ),
          child: Text(
            label,
            style: context.text.eyebrow.copyWith(
              fontSize: 11,
              color: selected ? context.colors.ink : context.colors.ink2,
            ),
          ),
        ),
      ),
    );
  }
}

class _ChartBody extends StatelessWidget {
  const _ChartBody({
    required this.points,
    required this.goalKg,
    required this.onLogWeight,
  });

  final List<WeightSeriesPoint> points;
  final Decimal? goalKg;
  final VoidCallback onLogWeight;

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) {
      return _EmptyChart(goalKg: goalKg, onLogWeight: onLogWeight);
    }

    final colors = context.colors;
    return Semantics(
      label: 'Weight trend, ${points.length} points',
      child: CustomPaint(
        size: Size.infinite,
        painter: _SparklinePainter(
          points: points,
          goalKg: goalKg,
          colors: colors,
        ),
      ),
    );
  }
}

class _EmptyChart extends StatelessWidget {
  const _EmptyChart({required this.goalKg, required this.onLogWeight});

  final Decimal? goalKg;
  final VoidCallback onLogWeight;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        // Single dashed goal line + gridlines — gives the user a sense of
        // what the chart will look like once they log entries.
        Positioned.fill(
          child: CustomPaint(
            painter: _EmptySparklinePainter(
              goalKg: goalKg,
              colors: context.colors,
            ),
          ),
        ),
        Center(
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onLogWeight,
              borderRadius: BorderRadius.circular(context.radius.rPill),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: context.space.x4,
                  vertical: context.space.x2,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.add_chart_outlined,
                        size: 16, color: context.colors.accent),
                    SizedBox(width: context.space.x1),
                    Text(
                      'Log your first weight',
                      style: context.text.bodyStrong.copyWith(
                        color: context.colors.accent,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ChartSkeleton extends StatelessWidget {
  const _ChartSkeleton();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.colors.line2,
        borderRadius: BorderRadius.circular(context.radius.r2),
      ),
    );
  }
}

class _AxisLabels extends StatelessWidget {
  const _AxisLabels({required this.points, required this.range});

  final List<WeightSeriesPoint> points;
  final WeightRange range;

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) return const SizedBox.shrink();
    final fmt = DateFormat('MMM d');
    // Five labels: 0, 25, 50, 75, 100% across the series.
    final n = points.length;
    final ticks = <int>[
      0,
      ((n - 1) * 0.25).round(),
      ((n - 1) * 0.5).round(),
      ((n - 1) * 0.75).round(),
      n - 1,
    ];
    final labels =
        <String>[for (final i in ticks) fmt.format(points[i].date)];

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        for (final l in labels)
          Text(
            l,
            style: context.text.meta.copyWith(
              fontSize: 10,
              color: context.colors.ink3,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
      ],
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
// CustomPainter — T-19.
// ────────────────────────────────────────────────────────────────────────

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({
    required this.points,
    required this.goalKg,
    required this.colors,
  });

  final List<WeightSeriesPoint> points;
  final Decimal? goalKg;
  final AppColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;

    // Compute y-axis bounds. Include the goal so the dashed line is
    // visible even when weights are well above target.
    double minVal = points.first.weightKg.toDouble();
    double maxVal = minVal;
    for (final p in points) {
      final v = p.weightKg.toDouble();
      if (v < minVal) minVal = v;
      if (v > maxVal) maxVal = v;
      final ma = p.movingAvg7d?.toDouble();
      if (ma != null) {
        if (ma < minVal) minVal = ma;
        if (ma > maxVal) maxVal = ma;
      }
    }
    if (goalKg != null) {
      final g = goalKg!.toDouble();
      if (g < minVal) minVal = g;
      if (g > maxVal) maxVal = g;
    }
    // Pad the range so the curve doesn't kiss the top/bottom edge.
    final range = maxVal - minVal;
    final pad = range == 0 ? 1.0 : range * 0.15;
    minVal -= pad;
    maxVal += pad;

    final chartTop = 8.0;
    final chartBottom = size.height - 4.0;
    final chartHeight = chartBottom - chartTop;

    double xFor(int i) =>
        points.length == 1 ? size.width / 2 : (i / (points.length - 1)) * size.width;
    double yFor(double v) =>
        chartBottom - ((v - minVal) / (maxVal - minVal)) * chartHeight;

    // ── Gridlines (4 horizontal). Matches mock at y=20,60,100,140. ──
    final gridPaint = Paint()
      ..color = colors.line2
      ..strokeWidth = 1;
    final rows = 4;
    for (var r = 0; r < rows; r++) {
      final y = chartTop + (chartHeight / (rows - 1)) * r;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // ── Dashed goal line ────────────────────────────────────────────────
    if (goalKg != null) {
      final goalY = yFor(goalKg!.toDouble());
      _drawDashedLine(
        canvas,
        Offset(0, goalY),
        Offset(size.width, goalY),
        Paint()
          ..color = colors.goalLine
          ..strokeWidth = 1,
        dashWidth: 3,
        gapWidth: 4,
      );
      // "GOAL nn.n" label, right-aligned just above the line.
      final tp = TextPainter(
        text: TextSpan(
          text: 'GOAL ${formatWeightKg(goalKg!)}',
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 9,
            fontWeight: FontWeight.w600,
            color: colors.goalLine,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(size.width - tp.width - 2, goalY - tp.height - 1));
    }

    // ── Area gradient under the actual-weight line ──────────────────────
    final actualPath = Path();
    for (var i = 0; i < points.length; i++) {
      final x = xFor(i);
      final y = yFor(points[i].weightKg.toDouble());
      if (i == 0) {
        actualPath.moveTo(x, y);
      } else {
        actualPath.lineTo(x, y);
      }
    }

    final areaPath = Path.from(actualPath)
      ..lineTo(size.width, chartBottom)
      ..lineTo(0, chartBottom)
      ..close();
    final areaPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[
          colors.accent.withValues(alpha: 0.18),
          colors.accent.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawPath(areaPath, areaPaint);

    // ── Actual-weight line ──────────────────────────────────────────────
    canvas.drawPath(
      actualPath,
      Paint()
        ..color = colors.accent
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke,
    );

    // ── 7-day moving-avg dashed line — suffix where movingAvg7d != null ─
    final maPoints = <Offset>[];
    for (var i = 0; i < points.length; i++) {
      final ma = points[i].movingAvg7d?.toDouble();
      if (ma == null) continue;
      maPoints.add(Offset(xFor(i), yFor(ma)));
    }
    if (maPoints.length >= 2) {
      final dashPaint = Paint()
        ..color = colors.ink3
        ..strokeWidth = 1.4
        ..style = PaintingStyle.stroke;
      for (var i = 0; i < maPoints.length - 1; i++) {
        _drawDashedLine(canvas, maPoints[i], maPoints[i + 1], dashPaint,
            dashWidth: 2, gapWidth: 3);
      }
    }

    // ── Point markers ──────────────────────────────────────────────────
    // Show at most 8 markers — at 1Y/All ranges, drawing one per point is
    // visual noise.
    final maxMarkers = 7;
    final stride = math.max(1, (points.length / maxMarkers).ceil());
    for (var i = 0; i < points.length; i++) {
      final isLast = i == points.length - 1;
      if (!isLast && i % stride != 0) continue;
      final c = Offset(xFor(i), yFor(points[i].weightKg.toDouble()));
      final radius = isLast ? 3.4 : 2.6;
      canvas.drawCircle(
        c,
        radius,
        Paint()..color = colors.surface,
      );
      canvas.drawCircle(
        c,
        radius,
        Paint()
          ..color = colors.accent
          ..strokeWidth = isLast ? 2.4 : 1.8
          ..style = PaintingStyle.stroke,
      );
    }
  }

  void _drawDashedLine(
    Canvas canvas,
    Offset start,
    Offset end,
    Paint paint, {
    required double dashWidth,
    required double gapWidth,
  }) {
    final total = (end - start).distance;
    if (total == 0) return;
    final dx = (end.dx - start.dx) / total;
    final dy = (end.dy - start.dy) / total;
    var traveled = 0.0;
    while (traveled < total) {
      final segEnd = math.min(traveled + dashWidth, total);
      final from = Offset(start.dx + dx * traveled, start.dy + dy * traveled);
      final to = Offset(start.dx + dx * segEnd, start.dy + dy * segEnd);
      canvas.drawLine(from, to, paint);
      traveled = segEnd + gapWidth;
    }
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) {
    if (old.points.length != points.length) return true;
    if (old.goalKg != goalKg) return true;
    for (var i = 0; i < points.length; i++) {
      if (old.points[i] != points[i]) return true;
    }
    return false;
  }
}

class _EmptySparklinePainter extends CustomPainter {
  _EmptySparklinePainter({required this.goalKg, required this.colors});

  final Decimal? goalKg;
  final AppColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = colors.line2
      ..strokeWidth = 1;
    const rows = 4;
    final chartTop = 8.0;
    final chartBottom = size.height - 4.0;
    final chartHeight = chartBottom - chartTop;
    for (var r = 0; r < rows; r++) {
      final y = chartTop + (chartHeight / (rows - 1)) * r;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    if (goalKg != null) {
      final goalY = chartTop + chartHeight * 0.62;
      _drawDashed(
        canvas,
        Offset(0, goalY),
        Offset(size.width, goalY),
        Paint()
          ..color = colors.goalLine
          ..strokeWidth = 1,
      );
      final tp = TextPainter(
        text: TextSpan(
          text: 'GOAL ${formatWeightKg(goalKg!)}',
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 9,
            fontWeight: FontWeight.w600,
            color: colors.goalLine,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(size.width - tp.width - 2, goalY - tp.height - 1));
    }
  }

  void _drawDashed(Canvas canvas, Offset start, Offset end, Paint paint) {
    const dashWidth = 3.0;
    const gapWidth = 4.0;
    final total = (end - start).distance;
    if (total == 0) return;
    final dx = (end.dx - start.dx) / total;
    final dy = (end.dy - start.dy) / total;
    var traveled = 0.0;
    while (traveled < total) {
      final segEnd = math.min(traveled + dashWidth, total);
      final from = Offset(start.dx + dx * traveled, start.dy + dy * traveled);
      final to = Offset(start.dx + dx * segEnd, start.dy + dy * segEnd);
      canvas.drawLine(from, to, paint);
      traveled = segEnd + gapWidth;
    }
  }

  @override
  bool shouldRepaint(covariant _EmptySparklinePainter old) =>
      old.goalKg != goalKg;
}
