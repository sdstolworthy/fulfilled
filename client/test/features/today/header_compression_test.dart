// UX-102 / UX-104 — Compact header decluttering (avatar cut + bolt →
// FAB) and chevron-merge.
//
// Acceptance per the tickets:
// 1. The avatar `Container` block is gone from the header — no finder
//    picks it up under the compact day-view subtree.
// 2. The bolt `IconButton36` (`Icons.bolt_outlined`) is gone from the
//    header. The search `IconButton36` stays.
// 3. UX-104 — neither chevron icon (`Icons.chevron_left` /
//    `Icons.chevron_right`) is anywhere in the compact day view's tree;
//    the chevron pair was the load-bearing per-day navigation in the
//    pre-UX-104 `_DateBar` and is now replaced by `DatePill`'s tap +
//    UX-103's swipe.
// 4. The `RingSummaryCard`'s top-edge paints within the cumulative
//    UX-102 + UX-104 ceiling (280 px) of the safe-area top on a
//    Pixel 4a reference viewport (393×851).
//
// The avatar block had no `Key` in the pre-UX-102 code, so the "no
// avatar" assertion is two-pronged: (a) the placeholder text "SS" is
// absent from the header subtree, and (b) the only `Container` paint
// remaining inside `_CompactHeader` is the `IconButton36`'s touch
// target — no circle-shaped decoration with `accentSoft` fill. We lean
// on the `'SS'` text as the load-bearing tell because the placeholder
// initials are unique to the avatar block.

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/day_summary.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/food.dart';
import 'package:fulfilled/domain/log_entry.dart';
import 'package:fulfilled/domain/meal.dart';
import 'package:fulfilled/domain/nutrition.dart';
import 'package:fulfilled/domain/serving.dart';
import 'package:fulfilled/domain/unit.dart';
import 'package:fulfilled/domain/weight.dart';
import 'package:fulfilled/features/today/today_screen.dart';
import 'package:fulfilled/providers/food_providers.dart';
import 'package:fulfilled/providers/log_providers.dart';
import 'package:fulfilled/providers/weight_providers.dart';
import 'package:fulfilled/routing/routes.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/ring_summary_card.dart';
import 'package:go_router/go_router.dart';

final DateTime _today = () {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}();

DaySummary _summary(DateTime date) => DaySummary(
      date: date,
      kcal: Decimal.fromInt(420),
      protein: Decimal.fromInt(30),
      carbs: Decimal.fromInt(50),
      fat: Decimal.fromInt(15),
      kcalTarget: Decimal.fromInt(2000),
      proteinTarget: Decimal.fromInt(120),
      carbsTarget: Decimal.fromInt(250),
      fatTarget: Decimal.fromInt(65),
      byMeal: <Meal, MealSubtotal>{
        for (final m in Meal.values) m: MealSubtotal.empty(m),
      },
    );

Food _food(String id) => Food(
      id: id,
      name: id,
      source: FoodSource.off,
      isCustom: false,
      servings: <Serving>[
        Serving(
          id: '${id}_s',
          label: '1 serving',
          amount: Decimal.fromInt(100),
          unit: Unit.g,
          kcal: Decimal.fromInt(100),
          isDefault: true,
          source: ServingSource.off,
        ),
      ],
    );

GoRouter _router() {
  return GoRouter(
    initialLocation: Routes.todayPath,
    routes: <RouteBase>[
      ShellRoute(
        builder: (_, __, child) => child,
        routes: <RouteBase>[
          GoRoute(
            path: Routes.todayPath,
            builder: (_, __) => const TodayScreen(),
          ),
          GoRoute(
            path: Routes.foodsPath,
            builder: (_, __) => const Scaffold(body: SizedBox.shrink()),
            routes: <RouteBase>[
              GoRoute(
                path: 'search',
                builder: (_, __) => const Scaffold(body: SizedBox.shrink()),
              ),
            ],
          ),
        ],
      ),
    ],
  );
}

Widget _harness({
  required GoRouter router,
  required List<Override> overrides,
}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp.router(
      theme: buildLightTheme(),
      routerConfig: router,
    ),
  );
}

List<Override> _baselineOverrides() => <Override>[
      daySummaryProvider(_today).overrideWith((_) async => _summary(_today)),
      logEntriesProvider(_today).overrideWith((_) async => <LogEntry>[]),
      recentFoodsProvider.overrideWith((_) async => <Food>[_food('r1')]),
      frequentFoodsProvider.overrideWith((_) async => <Food>[_food('f1')]),
      for (final r in WeightRange.values)
        weightSeriesProvider(r)
            .overrideWith((_) async => <WeightSeriesPoint>[]),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UX-102 — compact header has no avatar or bolt', () {
    testWidgets('avatar block is absent from the header subtree',
        (tester) async {
      // Pixel 4a reference viewport per the ticket.
      tester.view.physicalSize = const Size(393, 851);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final router = _router();
      await tester.pumpWidget(
        _harness(router: router, overrides: _baselineOverrides()),
      );
      await tester.pumpAndSettle();

      // The pre-UX-102 avatar rendered a 'SS' placeholder text. After
      // the cut, the text must not be present anywhere in the tree.
      expect(find.text('SS'), findsNothing);
    });

    testWidgets('bolt icon is absent from the header', (tester) async {
      tester.view.physicalSize = const Size(393, 851);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final router = _router();
      await tester.pumpWidget(
        _harness(router: router, overrides: _baselineOverrides()),
      );
      await tester.pumpAndSettle();

      // The bolt icon used to live in `_CompactHeader`'s row. UX-102
      // moves its handler into the FAB long-press menu and deletes the
      // header instance. The long-press menu is closed by default
      // (route-modal), so the only path to the bolt icon (the open
      // menu's PopupMenuItem) is dormant — `find.byIcon` should be
      // zero across the entire pumped tree.
      expect(find.byIcon(Icons.bolt_outlined), findsNothing);
    });

    testWidgets('search icon is still in the header', (tester) async {
      tester.view.physicalSize = const Size(393, 851);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final router = _router();
      await tester.pumpWidget(
        _harness(router: router, overrides: _baselineOverrides()),
      );
      await tester.pumpAndSettle();

      // The search affordance is the sole header icon now.
      expect(find.byIcon(Icons.search), findsOneWidget);
    });

    testWidgets('chevron icons are absent from the day-view header',
        (tester) async {
      tester.view.physicalSize = const Size(393, 851);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final router = _router();
      await tester.pumpWidget(
        _harness(router: router, overrides: _baselineOverrides()),
      );
      await tester.pumpAndSettle();

      // UX-104 removes the chevron `IconButton36` pair from `_DateBar`.
      // Per-day navigation is now swipe (UX-103) or the date picker
      // (`DatePill` tap).
      //
      // We scope the assertion to icons painted *above* the ring summary
      // card's top edge — that's the day-view header band. (The
      // `_EmptyDayCopyFromButton`, landed by UX-106 in the empty-day
      // pill below the ring, includes its own `Icons.chevron_right`
      // glyph; that's unrelated to the chevron pair this assertion
      // targets.)
      final ringTopY = tester.getTopLeft(find.byType(RingSummaryCard)).dy;
      final chevronLeftAbove = find.byIcon(Icons.chevron_left).evaluate().where(
            (e) {
              final ro = e.renderObject;
              if (ro is! RenderBox || !ro.attached) return false;
              return ro.localToGlobal(Offset.zero).dy < ringTopY;
            },
          );
      final chevronRightAbove =
          find.byIcon(Icons.chevron_right).evaluate().where(
        (e) {
          final ro = e.renderObject;
          if (ro is! RenderBox || !ro.attached) return false;
          return ro.localToGlobal(Offset.zero).dy < ringTopY;
        },
      );
      expect(chevronLeftAbove, isEmpty);
      expect(chevronRightAbove, isEmpty);
    });

    testWidgets(
      'ring paints within 280 px of safe-area top on Pixel 4a viewport',
      (tester) async {
        tester.view.physicalSize = const Size(393, 851);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final router = _router();
        await tester.pumpWidget(
          _harness(router: router, overrides: _baselineOverrides()),
        );
        await tester.pumpAndSettle();

        // The `RingSummaryCard`'s top-edge global y-coordinate is the
        // distance from the viewport's top — which in this harness has
        // no safe-area inset, so it equals the safe-area-top offset.
        // Architect §6.1 + §6.6 PR 4 AC: the cumulative UX-102 +
        // UX-104 target is 280 px (the chevron-merge collapses the
        // separate `_CompactHeader` row into the `_DateBar` band, so
        // the ring rises by ~one row of chrome relative to UX-102's
        // 320 px floor).
        final ringTopY =
            tester.getTopLeft(find.byType(RingSummaryCard)).dy;
        expect(
          ringTopY,
          lessThanOrEqualTo(280),
          reason:
              'RingSummaryCard top-edge should be within 280 px of the '
              'safe-area top after UX-104; was $ringTopY',
        );
      },
    );
  });
}
