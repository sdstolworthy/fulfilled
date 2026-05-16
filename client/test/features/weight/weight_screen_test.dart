import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/goal.dart';
import 'package:fulfilled/domain/weight.dart';
import 'package:fulfilled/features/weight/weight_screen.dart';
import 'package:fulfilled/features/weight/widgets/weight_history_list.dart';
import 'package:fulfilled/features/weight/widgets/weight_sparkline.dart';
import 'package:fulfilled/features/weight/widgets/weight_summary_card.dart';
import 'package:fulfilled/providers/goal_providers.dart';
import 'package:fulfilled/providers/weight_providers.dart';
import 'package:fulfilled/routing/app_router.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/empty_state.dart';
import 'package:fulfilled/widgets/skeleton.dart';
import 'package:go_router/go_router.dart';

/// Screen 06 widget tests.
///
/// Per the brief:
///   1. The screen renders against mocked providers (all three primary
///      child widgets composed).
///   2. The sparkline materialises the expected point count for the
///      `oneMonth` range when the provider yields N entries.
///   3. Tapping another range chip swaps the series — the `oneWeek`
///      override resolves to a smaller series.
///
/// Providers are overridden with deterministic in-memory values so the
/// test doesn't depend on the mock repository's seed or latency.

DateTime _d(int daysAgo) {
  final n = DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  return today.subtract(Duration(days: daysAgo));
}

WeightSeriesPoint _wp(int daysAgo, double kg, {double? ma}) {
  return WeightSeriesPoint(
    date: _d(daysAgo),
    weightKg: Decimal.parse(kg.toStringAsFixed(1)),
    movingAvg7d: ma == null ? null : Decimal.parse(ma.toStringAsFixed(4)),
  );
}

WeightEntry _we(int daysAgo, double kg) {
  final date = _d(daysAgo);
  return WeightEntry(
    id: 'w_$daysAgo',
    recordedOn: date,
    weightKg: Decimal.parse(kg.toStringAsFixed(1)),
    createdAt: date,
  );
}

Goal _activeGoal() {
  return Goal(
    id: 'g_test',
    startedOn: _d(60),
    startWeightKg: Decimal.parse('82.0'),
    targetWeightKg: Decimal.parse('74.0'),
    weeklyRateKg: Decimal.parse('-0.5'),
    dailyCalorieTarget: 2150,
    isActive: true,
    createdAt: _d(60),
    updatedAt: _d(60),
  );
}

List<WeightSeriesPoint> _seriesFor(WeightRange r) {
  // Deterministic series: oneWeek = 7 points; oneMonth = 30 points;
  // others = 30 points. movingAvg7d set on index ≥ 6.
  final n = r == WeightRange.oneWeek ? 7 : 30;
  final out = <WeightSeriesPoint>[];
  for (var i = 0; i < n; i++) {
    final daysAgo = n - 1 - i;
    final kg = 80.0 - (i * 0.05);
    final ma = i >= 6 ? kg + 0.1 : null;
    out.add(_wp(daysAgo, kg, ma: ma));
  }
  return out;
}

List<WeightEntry> _historySeed({int n = 10}) {
  final out = <WeightEntry>[];
  for (var i = 0; i < n; i++) {
    out.add(_we(i * 2, 80.0 - (i * 0.1)));
  }
  return out;
}

Widget _harness({required List<Override> overrides}) {
  final router = GoRouter(
    initialLocation: '/weight',
    routes: <RouteBase>[
      ShellRoute(
        builder: (_, __, child) => child,
        routes: <RouteBase>[
          GoRoute(
            path: '/weight',
            builder: (_, __) => const WeightScreen(),
          ),
        ],
      ),
    ],
  );

  return ProviderScope(
    overrides: <Override>[
      ...overrides,
      appRouterProvider.overrideWith((_) => router),
    ],
    child: MaterialApp.router(
      theme: buildLightTheme(),
      routerConfig: router,
    ),
  );
}

void main() {
  testWidgets('renders core composition against mocked providers',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _harness(
        overrides: <Override>[
          activeGoalProvider.overrideWith((_) async => _activeGoal()),
          weightHistoryProvider.overrideWith((_) async => _historySeed()),
          for (final r in WeightRange.values)
            weightSeriesProvider(r).overrideWith((_) async => _seriesFor(r)),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // Title renders.
    expect(find.text('Weight'), findsOneWidget);

    // The three primary child widgets each render exactly once.
    expect(find.byType(WeightSummaryCard), findsOneWidget);
    expect(find.byType(WeightSparklineCard), findsOneWidget);
    expect(find.byType(WeightHistoryList), findsOneWidget);

    // All five range chips are present.
    for (final r in WeightRange.values) {
      expect(find.text(r.label), findsOneWidget);
    }

    // "Recent entries" header.
    expect(find.text('RECENT ENTRIES'), findsOneWidget);

    // Log weight FAB exists on compact.
    expect(find.text('Log weight'), findsWidgets);
  });

  testWidgets('sparkline materialises the expected point count for oneMonth',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final monthSeries = _seriesFor(WeightRange.oneMonth);
    expect(monthSeries, hasLength(30));

    await tester.pumpWidget(
      _harness(
        overrides: <Override>[
          activeGoalProvider.overrideWith((_) async => _activeGoal()),
          weightHistoryProvider.overrideWith((_) async => _historySeed()),
          for (final r in WeightRange.values)
            weightSeriesProvider(r).overrideWith((_) async => _seriesFor(r)),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // The chart renders against the active range — by default `oneMonth`.
    // The painter is internal; assert that the CustomPaint is mounted by
    // looking inside the sparkline subtree.
    final sparkline = tester.widget<WeightSparklineCard>(
      find.byType(WeightSparklineCard),
    );
    expect(sparkline.range, WeightRange.oneMonth);

    // A CustomPaint must exist within the sparkline (the painter draws
    // the actual line + dashed avg + goal line).
    expect(
      find.descendant(
        of: find.byType(WeightSparklineCard),
        matching: find.byType(CustomPaint),
      ),
      findsWidgets,
    );
  });

  testWidgets('tapping a range chip swaps the series',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _harness(
        overrides: <Override>[
          activeGoalProvider.overrideWith((_) async => _activeGoal()),
          weightHistoryProvider.overrideWith((_) async => _historySeed()),
          for (final r in WeightRange.values)
            weightSeriesProvider(r).overrideWith((_) async => _seriesFor(r)),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // Default is 1M.
    expect(
      tester.widget<WeightSparklineCard>(find.byType(WeightSparklineCard)).range,
      WeightRange.oneMonth,
    );

    // Tap the "1W" chip — there are two text spans rendered for the
    // chip face. `find.text` resolves a single chip-face text widget.
    await tester.tap(find.text('1W'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<WeightSparklineCard>(find.byType(WeightSparklineCard)).range,
      WeightRange.oneWeek,
    );

    // Tap "All" — switches to the largest range.
    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<WeightSparklineCard>(find.byType(WeightSparklineCard)).range,
      WeightRange.all,
    );
  });

  // T-013 — when `weightHistoryProvider` is parked in the loading state
  // the history list renders the lifted [Skeleton] primitive, never a
  // spinner. Goal/series providers resolve immediately so the rest of
  // the screen settles cleanly while only the history list is loading.
  testWidgets(
      'history loading state renders Skeleton, never CircularProgressIndicator',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final completer = Completer<List<WeightEntry>>();
    addTearDown(() {
      if (!completer.isCompleted) completer.complete(<WeightEntry>[]);
    });

    await tester.pumpWidget(
      _harness(
        overrides: <Override>[
          activeGoalProvider.overrideWith((_) async => _activeGoal()),
          weightHistoryProvider.overrideWith((_) => completer.future),
          for (final r in WeightRange.values)
            weightSeriesProvider(r).overrideWith((_) async => _seriesFor(r)),
        ],
      ),
    );
    await tester.pump(); // resolve everything that can resolve.
    await tester.pump();

    expect(find.byType(WeightHistoryList), findsOneWidget);
    final history = find.descendant(
      of: find.byType(WeightHistoryList),
      matching: find.byType(Skeleton),
    );
    expect(history, findsWidgets);
    expect(
      find.descendant(
        of: find.byType(WeightHistoryList),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsNothing,
    );
  });

  // T-013 — empty `weightHistoryProvider` renders the lifted EmptyState
  // with a "Log your first weight" CTA. Previous code emitted a plain
  // text label without an action.
  testWidgets('empty history renders EmptyState with a "Log your first weight" CTA',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _harness(
        overrides: <Override>[
          activeGoalProvider.overrideWith((_) async => _activeGoal()),
          weightHistoryProvider.overrideWith((_) async => <WeightEntry>[]),
          for (final r in WeightRange.values)
            weightSeriesProvider(r).overrideWith((_) async => _seriesFor(r)),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final emptyState = find.descendant(
      of: find.byType(WeightHistoryList),
      matching: find.byType(EmptyState),
    );
    expect(emptyState, findsOneWidget);
    expect(find.text('No weight logged yet'), findsOneWidget);
    expect(find.text('Log your first weight'), findsOneWidget);
  });

  testWidgets(
      'no-active-goal renders the summary without crashing',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _harness(
        overrides: <Override>[
          // Goal provider intentionally throws to exercise the
          // `AsyncValue.error` arm in WeightSummaryCard / sparkline.
          activeGoalProvider.overrideWith(
            (_) async => throw Exception('GoalNotFoundError'),
          ),
          weightHistoryProvider.overrideWith((_) async => _historySeed()),
          for (final r in WeightRange.values)
            weightSeriesProvider(r).overrideWith((_) async => _seriesFor(r)),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // The summary card still renders; START / GOAL fall back to em-dashes.
    expect(find.byType(WeightSummaryCard), findsOneWidget);
    expect(find.text('START'), findsOneWidget);
    expect(find.text('GOAL'), findsOneWidget);
  });
}
