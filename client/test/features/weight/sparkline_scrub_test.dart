import 'package:decimal/decimal.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/weight.dart';
import 'package:fulfilled/repositories/goal_repository.dart';
import 'package:fulfilled/features/weight/widgets/weight_sparkline.dart';
import 'package:fulfilled/providers/goal_providers.dart';
import 'package:fulfilled/providers/weight_providers.dart';
import 'package:fulfilled/theme/theme_data.dart';

/// UX-108 — F4 scrub-to-read gesture tests. See `weight_sparkline.dart`.
///
/// The scrub gesture lives inside `WeightSparklineCard` → `_ChartBody` →
/// `_ScrubGestureWrap`. The wrap is private, so the tests probe behaviour
/// via the public `WeightSparklineCard` widget — find the tooltip by its
/// stable `Key('scrub-tooltip')` and the formatted text strings.
///
/// Tests:
///   1. horizontal drag emits guideline + tooltip; release fades it out.
///   2. vertical drag does not block parent scroll (T-12 spirit).
///   3. reduce-motion bypasses fade — instant disappear.
///   4. empty-state chart has no scrub (the wrap short-circuits).
///   5. hover on expanded (web/desktop) emits the same tooltip.

DateTime _d(int daysAgo) {
  // Anchor to a stable date so the formatted "EEE, MMM d" string is
  // deterministic across days / time zones.
  final anchor = DateTime(2026, 5, 14); // Thursday
  return anchor.subtract(Duration(days: daysAgo));
}

WeightSeriesPoint _wp(int daysAgo, double kg, {double? ma}) {
  return WeightSeriesPoint(
    date: _d(daysAgo),
    weightKg: Decimal.parse(kg.toStringAsFixed(1)),
    movingAvg7d: ma == null ? null : Decimal.parse(ma.toStringAsFixed(4)),
  );
}

/// Seven-point series anchored on May 14 2026 — newest at the end.
/// Index 6 = today (Thu, May 14) at 79.6 kg.
List<WeightSeriesPoint> _series() {
  return <WeightSeriesPoint>[
    _wp(6, 80.2),
    _wp(5, 80.0),
    _wp(4, 79.9),
    _wp(3, 79.8),
    _wp(2, 79.8),
    _wp(1, 79.7),
    _wp(0, 79.6),
  ];
}

Widget _harness({
  required List<WeightSeriesPoint> series,
  bool disableAnimations = false,
  Size size = const Size(390, 844),
}) {
  return ProviderScope(
    overrides: <Override>[
      activeGoalProvider.overrideWith(
        (_) async => throw GoalNotFoundError(DateTime(2026, 5, 14)),
      ),
      weightHistoryProvider.overrideWith((_) async => const <WeightEntry>[]),
      for (final r in WeightRange.values)
        weightSeriesProvider(r).overrideWith((_) async => series),
    ],
    child: MaterialApp(
      theme: buildLightTheme(),
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          disableAnimations: disableAnimations,
        ),
        child: Scaffold(
          body: WeightSparklineCard(
            range: WeightRange.oneWeek,
            onRangeChanged: (_) {},
            onLogWeight: () {},
          ),
        ),
      ),
    ),
  );
}

/// Compact-form harness with the sparkline mounted inside a
/// `ListView` — used for the "vertical drag does not block parent
/// scroll" assertion.
Widget _scrollHarness({
  required List<WeightSeriesPoint> series,
  required ScrollController controller,
}) {
  return ProviderScope(
    overrides: <Override>[
      activeGoalProvider.overrideWith(
        (_) async => throw GoalNotFoundError(DateTime(2026, 5, 14)),
      ),
      weightHistoryProvider.overrideWith((_) async => const <WeightEntry>[]),
      for (final r in WeightRange.values)
        weightSeriesProvider(r).overrideWith((_) async => series),
    ],
    child: MaterialApp(
      theme: buildLightTheme(),
      home: MediaQuery(
        data: const MediaQueryData(size: Size(390, 844)),
        child: Scaffold(
          body: ListView(
            controller: controller,
            children: <Widget>[
              WeightSparklineCard(
                range: WeightRange.oneWeek,
                onRangeChanged: (_) {},
                onLogWeight: () {},
              ),
              const SizedBox(height: 1200), // generous below-chart content
            ],
          ),
        ),
      ),
    ),
  );
}

/// Find the chart-area `CustomPaint`s — the inner painter renders at
/// `Size.infinite`. The outer overlay-wrapping `CustomPaint` (mounted
/// only while a scrub is active) sits in the same subtree but with the
/// default zero size and a non-null `foregroundPainter`.
///
/// Tests assert overlay presence by checking whether *any* `CustomPaint`
/// inside the sparkline card has a non-null `foregroundPainter`.
Finder _chartCustomPaint() {
  return find.descendant(
    of: find.byType(WeightSparklineCard),
    matching: find.byWidgetPredicate(
      (w) => w is CustomPaint && w.size == Size.infinite,
    ),
  );
}

bool _overlayMounted(WidgetTester tester) {
  return tester
      .widgetList<CustomPaint>(find.descendant(
        of: find.byType(WeightSparklineCard),
        matching: find.byType(CustomPaint),
      ))
      .any((p) => p.foregroundPainter != null);
}

void main() {
  testWidgets(
      'compact horizontal drag emits guideline + tooltip; release fades it out',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness(series: _series()));
    await tester.pumpAndSettle();

    // The AnimatedBuilder host is mounted up-front — its stable Key
    // exists even when no scrub is active.
    expect(find.byKey(const Key('scrub-tooltip')), findsOneWidget);

    // Pre-drag: no overlay painter mounted (no foregroundPainter on any
    // chart-area CustomPaint).
    expect(_overlayMounted(tester), isFalse);

    // Drag the chart horizontally from its center.
    final chartCenter = tester.getCenter(_chartCustomPaint().first);
    final gesture = await tester.startGesture(chartCenter);
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump(const Duration(milliseconds: 150)); // past fade-in

    expect(
      _overlayMounted(tester),
      isTrue,
      reason: 'scrub overlay painter must be mounted during drag',
    );

    // Release — pump past the fade-out duration. The overlay unmounts.
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      _overlayMounted(tester),
      isFalse,
      reason: 'overlay painter clears after fade-out completes',
    );
  });

  testWidgets('vertical drag does not block parent scroll (T-12 spirit)',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_scrollHarness(
      series: _series(),
      controller: controller,
    ));
    await tester.pumpAndSettle();

    expect(controller.offset, 0.0);

    // Drag vertically inside the chart bounds — the parent ListView
    // should scroll because the chart only claims horizontal drag.
    final chartCenter = tester.getCenter(_chartCustomPaint().first);
    final gesture = await tester.startGesture(chartCenter);
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      controller.offset,
      greaterThan(50.0),
      reason: 'vertical drag inside chart must scroll the parent ListView',
    );
  });

  testWidgets('reduce-motion bypasses fade — instant disappear',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _harness(series: _series(), disableAnimations: true),
    );
    await tester.pumpAndSettle();

    final chartCenter = tester.getCenter(_chartCustomPaint().first);
    final gesture = await tester.startGesture(chartCenter);
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();

    // With reduce-motion, the overlay snaps to fully visible on the
    // very first frame.
    expect(
      _overlayMounted(tester),
      isTrue,
      reason: 'reduce-motion still mounts the overlay on drag start',
    );

    // Release and pump exactly one frame — overlay must already be
    // gone (no fade tail).
    await gesture.up();
    await tester.pump();

    expect(
      _overlayMounted(tester),
      isFalse,
      reason: 'reduce-motion bypasses the fade; overlay unmounts on release',
    );
  });

  testWidgets('empty-state chart has no scrub (gesture is a no-op)',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_harness(series: const <WeightSeriesPoint>[]));
    await tester.pumpAndSettle();

    // Empty state shows the "Log your first weight" CTA — there is no
    // chart `CustomPaint` at Size.infinite carrying a `_SparklinePainter`.
    expect(find.text('Log your first weight'), findsOneWidget);

    // Attempt to drag where the chart would have been; verify no
    // overlay painter is ever mounted.
    final cardCenter = tester.getCenter(find.byType(WeightSparklineCard));
    final gesture = await tester.startGesture(cardCenter);
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump(const Duration(milliseconds: 150));

    expect(
      _overlayMounted(tester),
      isFalse,
      reason: 'empty-state chart: scrub gesture is a no-op',
    );

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('expanded hover emits the same tooltip overlay',
      (tester) async {
    // Expanded form factor: width >= 1024 → MouseRegion path.
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _harness(series: _series(), size: const Size(1280, 900)),
    );
    await tester.pumpAndSettle();

    final chartCenter = tester.getCenter(_chartCustomPaint().first);

    // Simulate a mouse hover at chart center via a synthetic mouse
    // pointer event. `createGesture(kind: PointerDeviceKind.mouse)`
    // produces a hover-capable gesture.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(chartCenter);
    await tester.pump(const Duration(milliseconds: 150));

    expect(
      _overlayMounted(tester),
      isTrue,
      reason: 'expanded: MouseRegion.onHover mounts the overlay painter',
    );

    // Move the pointer off the chart — overlay fades and unmounts.
    await mouse.moveTo(const Offset(0, 0));
    await tester.pumpAndSettle();

    expect(
      _overlayMounted(tester),
      isFalse,
      reason: 'expanded: onExit fades overlay back out',
    );
  });
}
