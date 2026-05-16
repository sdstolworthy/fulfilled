import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/goal.dart';
import 'package:fulfilled/domain/weight.dart';
import 'package:fulfilled/features/weight/weight_screen.dart';
import 'package:fulfilled/providers/goal_providers.dart';
import 'package:fulfilled/providers/weight_providers.dart';
import 'package:fulfilled/routing/app_router.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:go_router/go_router.dart';

/// UX-111 (Theme C dead-affordance sweep) — regression.
///
/// The three named no-op affordances on the weight screen are gone:
///   - the `calendar_today_outlined` `_HeaderIconButton` (formerly
///     `onPressed: null`),
///   - the `more_horiz` `_HeaderIconButton` (also `onPressed: null`),
///   - the "See all" `Text` in the RECENT ENTRIES header (visually
///     read as a button, routed nowhere).
///
/// Architect §8 / PM doc §2 Theme C ruling: delete in v1; the
/// full-history route is a v1.1 product surface.
///
/// Tenants: T-20 (no false affordances).

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
  testWidgets('weight screen has no calendar icon', (tester) async {
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

    expect(
      find.byIcon(Icons.calendar_today_outlined),
      findsNothing,
      reason: 'UX-111: the no-op calendar icon on the weight header '
          'must not be reintroduced — the back-fill date picker lives '
          'on the log sheet.',
    );
    expect(
      find.byIcon(Icons.calendar_today),
      findsNothing,
      reason: 'UX-111: defensive — neither outlined nor filled '
          'calendar glyph belongs on the weight header in v1.',
    );
    expect(
      find.byIcon(Icons.calendar_month),
      findsNothing,
      reason: 'UX-111: defensive — neither `calendar_month` glyph '
          'belongs on the weight header in v1.',
    );
  });

  testWidgets('weight screen has no more_horiz icon on the header',
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

    expect(
      find.byIcon(Icons.more_horiz),
      findsNothing,
      reason: 'UX-111: the no-op `more_horiz` overflow on the weight '
          'header must not be reintroduced. Restore only when wired '
          'to a real menu.',
    );
  });

  testWidgets('weight screen has no "See all" text', (tester) async {
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

    expect(
      find.text('See all'),
      findsNothing,
      reason: 'UX-111: the dead "See all" text in the RECENT ENTRIES '
          'header must not be reintroduced. The full-history route '
          'is a v1.1 product surface.',
    );

    // Sanity: the RECENT ENTRIES eyebrow itself still renders — we
    // cut only the trailing affordance, not the section header.
    expect(find.text('RECENT ENTRIES'), findsOneWidget);
  });
}
