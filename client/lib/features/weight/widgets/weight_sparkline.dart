import 'dart:math' as math;

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../../domain/enums.dart';
import '../../../domain/units/weight.dart';
import '../../../domain/weight.dart';
import '../../../form_factor/form_factor.dart';
import '../../../providers/goal_providers.dart';
import '../../../providers/profile_providers.dart';
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
    final unit = ref.watch(weightUnitProvider);

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
                  unit: unit,
                  onLogWeight: onLogWeight,
                ),
                loading: () => const _ChartSkeleton(),
                error: (_, __) => _ChartBody(
                  points: const <WeightSeriesPoint>[],
                  goalKg: goalTarget,
                  unit: unit,
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
    required this.unit,
    required this.onLogWeight,
  });

  final List<WeightSeriesPoint> points;
  final Decimal? goalKg;
  final WeightUnit unit;
  final VoidCallback onLogWeight;

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) {
      return _EmptyChart(
        goalKg: goalKg,
        unit: unit,
        onLogWeight: onLogWeight,
      );
    }

    final colors = context.colors;
    return Semantics(
      label: 'Weight trend, ${points.length} points',
      child: _ScrubGestureWrap(
        points: points,
        unit: unit,
        colors: colors,
        child: CustomPaint(
          size: Size.infinite,
          painter: _SparklinePainter(
            points: points,
            goalKg: goalKg,
            unit: unit,
            colors: colors,
          ),
        ),
      ),
    );
  }
}

class _EmptyChart extends StatelessWidget {
  const _EmptyChart({
    required this.goalKg,
    required this.unit,
    required this.onLogWeight,
  });

  final Decimal? goalKg;
  final WeightUnit unit;
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
              unit: unit,
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
    required this.unit,
    required this.colors,
  });

  final List<WeightSeriesPoint> points;
  final Decimal? goalKg;
  final WeightUnit unit;
  final AppColors colors;

  /// Convert a canonical kg into the y-axis display value. For kg the
  /// axis is kg; for lb / st the axis is linear in pounds — the visible
  /// glyph at each tick still renders via `formatWeight(canonical_kg,
  /// unit)`, which produces the composite under stone.
  ///
  /// The conversion routes through the public `parseWeightToKg` seam
  /// (the inverse of `formatWeight`), so this painter never inlines the
  /// kg-per-lb constant. Architect §3.13 / §3.14: only `weight.dart`
  /// knows the avoirdupois constant.
  double _displayValue(Decimal kg) {
    switch (unit) {
      case WeightUnit.kg:
        return kg.toDouble();
      case WeightUnit.lb:
      case WeightUnit.st:
        // kg → lb. `parseWeightToKg('1', WeightUnit.lb)` is 1 lb in kg;
        // dividing by that converts kg → lb without inlining a literal.
        final lbInKg = parseWeightToKg('1', WeightUnit.lb);
        return (kg / lbInKg).toDouble();
    }
  }

  /// Inverse of [_displayValue] — pixel-space y mapping consumes display
  /// values, but the goal / tick labels start from a canonical kg
  /// `Decimal`. The painter rounds tick positions to a uniform interval
  /// in display space and carries the corresponding kg back through
  /// `Decimal` for the label, using the same public seam.
  Decimal _kgFromDisplay(double display) {
    switch (unit) {
      case WeightUnit.kg:
        return Decimal.parse(display.toStringAsFixed(4));
      case WeightUnit.lb:
      case WeightUnit.st:
        // display is in pounds → kg via `parseWeightToKg`. The string
        // round-trip is the same float-safety dance as the formatter:
        // only the already-rounded value crosses into `Decimal`.
        return parseWeightToKg(display.toStringAsFixed(4), WeightUnit.lb);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;

    // Compute y-axis bounds *in the display unit*. Stone runs in total
    // pounds, kg in kilograms, lb in pounds — pre-converting at painter
    // setup keeps the tick math obvious (architect §3.14).
    double minVal = _displayValue(points.first.weightKg);
    double maxVal = minVal;
    for (final p in points) {
      final v = _displayValue(p.weightKg);
      if (v < minVal) minVal = v;
      if (v > maxVal) maxVal = v;
      final maKg = p.movingAvg7d;
      if (maKg != null) {
        final ma = _displayValue(maKg);
        if (ma < minVal) minVal = ma;
        if (ma > maxVal) maxVal = ma;
      }
    }
    if (goalKg != null) {
      final g = _displayValue(goalKg!);
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

    // ── Gridlines + tick labels (4 horizontal). Tick values are
    // computed in the display unit; the label round-trips back through
    // `formatWeightWithUnit(canonical_kg, unit)` so stone renders as a
    // composite (`'12 st 7 lb'`).
    final gridPaint = Paint()
      ..color = colors.line2
      ..strokeWidth = 1;
    final rows = 4;
    for (var r = 0; r < rows; r++) {
      final y = chartTop + (chartHeight / (rows - 1)) * r;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
      // Top row = maxVal, bottom row = minVal — invert the index so the
      // label at the top edge is the biggest weight.
      final tickValue = maxVal - (maxVal - minVal) * (r / (rows - 1));
      final tickKg = _kgFromDisplay(tickValue);
      final tp = TextPainter(
        text: TextSpan(
          text: formatWeightWithUnit(tickKg, unit),
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 9,
            color: colors.ink3,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(2, y - tp.height - 1));
    }

    // ── Dashed goal line ────────────────────────────────────────────────
    if (goalKg != null) {
      final goalY = yFor(_displayValue(goalKg!));
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
      // "GOAL <weight>" label, right-aligned just above the line.
      final tp = TextPainter(
        text: TextSpan(
          text: 'GOAL ${formatWeightWithUnit(goalKg!, unit)}',
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
      final y = yFor(_displayValue(points[i].weightKg));
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
      final maKg = points[i].movingAvg7d;
      if (maKg == null) continue;
      maPoints.add(Offset(xFor(i), yFor(_displayValue(maKg))));
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
      final c = Offset(xFor(i), yFor(_displayValue(points[i].weightKg)));
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
    if (old.unit != unit) return true;
    for (var i = 0; i < points.length; i++) {
      if (old.points[i] != points[i]) return true;
    }
    return false;
  }
}

class _EmptySparklinePainter extends CustomPainter {
  _EmptySparklinePainter({
    required this.goalKg,
    required this.unit,
    required this.colors,
  });

  final Decimal? goalKg;
  final WeightUnit unit;
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
          text: 'GOAL ${formatWeightWithUnit(goalKg!, unit)}',
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
      old.goalKg != goalKg || old.unit != unit;
}

// ────────────────────────────────────────────────────────────────────────
// F4 — Sparkline scrub-to-read gesture (UX-108).
//
// Wraps the existing chart `CustomPaint` in a gesture-aware overlay:
//
//   - Compact: `GestureDetector` with `onHorizontalDrag*` +
//     `HitTestBehavior.translucent`. Horizontal-drag-only so the
//     vertical scroll of the parent `ListView` is not hijacked
//     (PM §2 F4 acceptance + T-12 spirit).
//   - Expanded: `MouseRegion.onEnter/onHover/onExit` — hover only.
//     A touch on expanded falls through to the parent scroll, per
//     architect §5.1.
//
// The overlay is rendered by a `foregroundPainter` (`_ScrubOverlayPainter`)
// so the guideline + tooltip draw *over* the existing chart strokes
// without an extra widget layer / `Positioned` math.
//
// Fade in / out: 120 ms (`motion('chart.scrub.in/out')`). The token isn't
// defined as a function helper, so the duration is inline here with a
// `MediaQuery.disableAnimationsOf` short-circuit per the a11y AC.
//
// Empty-state short-circuit: when `points.isEmpty`, the wrap returns the
// child directly without any gesture handlers (the empty-state CTA owns
// the chart area).
// ────────────────────────────────────────────────────────────────────────

class _ScrubGestureWrap extends StatefulWidget {
  const _ScrubGestureWrap({
    required this.points,
    required this.unit,
    required this.colors,
    required this.child,
  });

  final List<WeightSeriesPoint> points;
  final WeightUnit unit;
  final AppColors colors;
  final Widget child;

  @override
  State<_ScrubGestureWrap> createState() => _ScrubGestureWrapState();
}

class _ScrubGestureWrapState extends State<_ScrubGestureWrap>
    with SingleTickerProviderStateMixin {
  /// Active scrub X-coordinate in widget-local pixels. Null when no
  /// scrub is active. The overlay painter mounts only when this is
  /// non-null.
  double? _scrubX;

  /// Fade animation for the guideline + tooltip. 120 ms in / 120 ms out
  /// per architect §5.1's `motion('chart.scrub.in/out')`. Reduce-motion
  /// short-circuits the controller's `value` directly so frames snap.
  late final AnimationController _fade;

  static const Duration _fadeDuration = Duration(milliseconds: 120);

  @override
  void initState() {
    super.initState();
    _fade = AnimationController(
      vsync: this,
      duration: _fadeDuration,
      reverseDuration: _fadeDuration,
      value: 0,
    );
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  void _startAt(double x, bool disableAnims) {
    setState(() => _scrubX = x);
    if (disableAnims) {
      _fade.value = 1.0;
    } else {
      _fade.forward();
    }
  }

  void _updateAt(double x) {
    setState(() => _scrubX = x);
  }

  void _endScrub(bool disableAnims) {
    if (disableAnims) {
      _fade.value = 0.0;
      if (mounted) setState(() => _scrubX = null);
      return;
    }
    _fade.reverse().then((_) {
      if (mounted) setState(() => _scrubX = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Empty-state: no points → no scrub gesture (AC: empty-state chart
    // is a no-op for scrub).
    if (widget.points.isEmpty) return widget.child;

    final isExpanded = FormFactor.of(context).isExpanded;
    final disableAnims = MediaQuery.disableAnimationsOf(context);

    // Mount the overlay painter only when a scrub is active *or* the
    // fade is still running (so the reverse() tail still paints).
    final overlay = AnimatedBuilder(
      key: const Key('scrub-tooltip'),
      animation: _fade,
      builder: (_, __) {
        if (_scrubX == null || _fade.value == 0.0) return widget.child;
        return CustomPaint(
          foregroundPainter: _ScrubOverlayPainter(
            scrubX: _scrubX!,
            opacity: _fade.value.clamp(0.0, 1.0),
            points: widget.points,
            unit: widget.unit,
            colors: widget.colors,
          ),
          child: widget.child,
        );
      },
    );

    if (isExpanded) {
      return MouseRegion(
        onEnter: (e) => _startAt(e.localPosition.dx, disableAnims),
        onHover: (e) => _updateAt(e.localPosition.dx),
        onExit: (_) => _endScrub(disableAnims),
        child: overlay,
      );
    }

    return GestureDetector(
      // `translucent` so vertical drags pass through to the parent
      // `ListView`. Horizontal-drag-only so the arena resolution stays
      // ours on horizontal motion without hijacking vertical scroll.
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (d) =>
          _startAt(d.localPosition.dx, disableAnims),
      onHorizontalDragUpdate: (d) => _updateAt(d.localPosition.dx),
      onHorizontalDragEnd: (_) => _endScrub(disableAnims),
      onHorizontalDragCancel: () => _endScrub(disableAnims),
      child: overlay,
    );
  }
}

/// Foreground painter for the F4 scrub overlay: vertical guideline +
/// dot + floating tooltip card. Snaps to the nearest data point in X.
///
/// The Y-axis bounds are recomputed locally so this painter doesn't have
/// to share state with `_SparklinePainter` (the chart caps at ~30 points;
/// the linear scan + min/max sweep is O(n) and fast). The math mirrors
/// `_SparklinePainter` 1:1 — the chart-top / chart-bottom inset, the
/// 15 % padding, the `xFor` / `yFor` mapping.
class _ScrubOverlayPainter extends CustomPainter {
  _ScrubOverlayPainter({
    required this.scrubX,
    required this.opacity,
    required this.points,
    required this.unit,
    required this.colors,
  });

  final double scrubX;
  final double opacity;
  final List<WeightSeriesPoint> points;
  final WeightUnit unit;
  final AppColors colors;

  double _displayValue(Decimal kg) {
    switch (unit) {
      case WeightUnit.kg:
        return kg.toDouble();
      case WeightUnit.lb:
      case WeightUnit.st:
        final lbInKg = parseWeightToKg('1', WeightUnit.lb);
        return (kg / lbInKg).toDouble();
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty || opacity <= 0) return;

    // ── Recompute the Y bounds (mirrors `_SparklinePainter`) ──────────
    double minVal = _displayValue(points.first.weightKg);
    double maxVal = minVal;
    for (final p in points) {
      final v = _displayValue(p.weightKg);
      if (v < minVal) minVal = v;
      if (v > maxVal) maxVal = v;
      final maKg = p.movingAvg7d;
      if (maKg != null) {
        final ma = _displayValue(maKg);
        if (ma < minVal) minVal = ma;
        if (ma > maxVal) maxVal = ma;
      }
    }
    final range = maxVal - minVal;
    final pad = range == 0 ? 1.0 : range * 0.15;
    minVal -= pad;
    maxVal += pad;

    const chartTop = 8.0;
    final chartBottom = size.height - 4.0;
    final chartHeight = chartBottom - chartTop;

    double xFor(int i) => points.length == 1
        ? size.width / 2
        : (i / (points.length - 1)) * size.width;
    double yFor(double v) =>
        chartBottom - ((v - minVal) / (maxVal - minVal)) * chartHeight;

    // ── Snap to the nearest data point in X (linear scan, ≤30 pts) ───
    var nearest = 0;
    var nearestDx = (xFor(0) - scrubX).abs();
    for (var i = 1; i < points.length; i++) {
      final dx = (xFor(i) - scrubX).abs();
      if (dx < nearestDx) {
        nearestDx = dx;
        nearest = i;
      }
    }
    final point = points[nearest];
    final snappedX = xFor(nearest);
    final pointY = yFor(_displayValue(point.weightKg));

    // ── 1-px vertical guideline at the snapped X ─────────────────────
    final guidePaint = Paint()
      ..color = colors.ink2.withValues(alpha: 0.4 * opacity)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(snappedX, chartTop),
      Offset(snappedX, chartBottom),
      guidePaint,
    );

    // ── 4-px filled dot at the snapped data point ────────────────────
    canvas.drawCircle(
      Offset(snappedX, pointY),
      4,
      Paint()..color = colors.accent.withValues(alpha: opacity),
    );

    // ── Tooltip text: two lines ──────────────────────────────────────
    final dateLabel = DateFormat('EEE, MMM d').format(point.date);
    final weightLabel = formatWeightWithUnit(point.weightKg, unit);
    final tp = TextPainter(
      text: TextSpan(
        children: <InlineSpan>[
          TextSpan(
            text: dateLabel,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 10,
              fontWeight: FontWeight.w600,
              // FX-006 / T-01: tooltip text on the dark `ink` capsule uses
              // the `surface` token rather than `Colors.white`.
              color: colors.surface.withValues(alpha: opacity),
            ),
          ),
          TextSpan(
            text: '\n$weightLabel',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: colors.surface.withValues(alpha: opacity),
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout();

    const padX = 8.0;
    const padY = 6.0;
    const gap = 8.0; // gap between dot and tooltip
    final boxW = tp.width + padX * 2;
    final boxH = tp.height + padY * 2;

    // Position the tooltip above the dot; clamp inside chart bounds so
    // it doesn't clip on left/right edges. Architect §5.1.
    double left = snappedX - boxW / 2;
    left = left.clamp(0.0, math.max(0.0, size.width - boxW));
    double top = pointY - boxH - gap;
    if (top < 0) {
      // Not enough room above — flip below the dot.
      top = pointY + gap;
    }

    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(left, top, boxW, boxH),
      const Radius.circular(6),
    );
    canvas.drawRRect(
      rrect,
      Paint()..color = colors.ink.withValues(alpha: opacity),
    );
    tp.paint(canvas, Offset(left + padX, top + padY));
  }

  @override
  bool shouldRepaint(covariant _ScrubOverlayPainter old) {
    if (old.scrubX != scrubX) return true;
    if (old.opacity != opacity) return true;
    if (old.unit != unit) return true;
    if (old.points.length != points.length) return true;
    return false;
  }

  @override
  bool? hitTest(Offset position) => false;
}
