import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/food.dart';
import 'package:fulfilled/domain/serving.dart';
import 'package:fulfilled/domain/unit.dart';
import 'package:fulfilled/features/search/search_screen.dart';
import 'package:fulfilled/features/search/widgets/search_field.dart';
import 'package:fulfilled/features/search/widgets/search_result_row.dart';
import 'package:fulfilled/providers/food_providers.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:go_router/go_router.dart';

/// F5-T4 — Search screen tests for the two-section "YOUR FOODS" / "ALL
/// FOODS" split.
///
/// The existing `search_screen_test.dart` is `@Skip`-quarantined post
/// Ask-10. We add F5 cases in this dedicated file so they run on every
/// CI pass rather than being dragged into the quarantine.

Food _food({
  required String id,
  required String name,
  String? brand,
  FoodSource source = FoodSource.off,
  int kcal = 100,
  DateTime? lastLoggedAt,
  int? logCount,
}) {
  return Food(
    id: id,
    name: name,
    brand: brand,
    source: source,
    isCustom: source == FoodSource.user,
    servings: <Serving>[
      Serving(
        id: '${id}_s1',
        label: '1 serving',
        amount: Decimal.fromInt(100),
        unit: Unit.g,
        kcal: Decimal.fromInt(kcal),
        isDefault: true,
        source: ServingSource.off,
      ),
    ],
    lastLoggedAt: lastLoggedAt,
    logCount: logCount,
  );
}

Widget _harness({required List<Food> searchResults}) {
  final router = GoRouter(
    initialLocation: '/foods/search',
    routes: <RouteBase>[
      GoRoute(
        path: '/foods/search',
        builder: (context, state) => const Scaffold(body: SearchScreen()),
      ),
      GoRoute(
        path: '/foods/:id',
        builder: (_, __) => const Scaffold(body: Center(child: Text('detail'))),
      ),
    ],
  );
  return ProviderScope(
    overrides: <Override>[
      recentFoodsProvider.overrideWith((_) async => const <Food>[]),
      frequentFoodsProvider.overrideWith((_) async => const <Food>[]),
      foodSearchProvider.overrideWith((ref, query) async {
        if (query.trim().isEmpty) return const <Food>[];
        return searchResults;
      }),
    ],
    child: MaterialApp.router(
      theme: buildLightTheme(),
      routerConfig: router,
    ),
  );
}

Future<void> _typeQuery(WidgetTester tester, String query) async {
  final field = find.descendant(
    of: find.byType(SearchField),
    matching: find.byType(TextField),
  );
  await tester.enterText(field, query);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    // Phone-sized viewport. The split logic is form-factor independent
    // (it lives in `_ResultsList.build`), so we don't need to test
    // multiple sizes.
  });

  Future<void> pumpHarness(WidgetTester tester, Widget app) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
  }

  testWidgets('all-cold results → flat list, no section headers',
      (tester) async {
    final hits = <Food>[
      _food(id: 'c1', name: 'Yogurt, vanilla bean', brand: 'Stonyfield'),
      _food(id: 'c2', name: 'Yogurt, strawberry', brand: 'Yoplait'),
      _food(id: 'c3', name: 'Yogurt, blueberry', brand: 'Chobani'),
    ];
    await pumpHarness(tester, _harness(searchResults: hits));
    await _typeQuery(tester, 'yog');

    // Flat list — no section headers from F5.
    expect(find.text('YOUR FOODS'), findsNothing);
    expect(find.text('ALL FOODS'), findsNothing);
    // The pre-F5 single "RESULTS" eyebrow still renders.
    expect(find.text('RESULTS'), findsOneWidget);
    expect(find.byType(SearchResultRow), findsNWidgets(3));
  });

  testWidgets('all-logged results → only "YOUR FOODS" header renders',
      (tester) async {
    final now = DateTime(2026, 5, 15, 14);
    final hits = <Food>[
      _food(
        id: 'l1',
        name: 'Greek yogurt, plain',
        brand: 'Fage',
        lastLoggedAt: now.subtract(const Duration(days: 1)),
        logCount: 3,
      ),
      _food(
        id: 'l2',
        name: 'Greek yogurt, 2%',
        brand: 'Chobani',
        lastLoggedAt: now.subtract(const Duration(days: 2)),
        logCount: 5,
      ),
    ];
    await pumpHarness(tester, _harness(searchResults: hits));
    await _typeQuery(tester, 'yog');

    expect(find.text('YOUR FOODS'), findsOneWidget);
    expect(find.text('(2)'), findsOneWidget);
    expect(find.text('ALL FOODS'), findsNothing);
    expect(find.byType(SearchResultRow), findsNWidgets(2));
  });

  testWidgets('mixed results → both sections with counts', (tester) async {
    final now = DateTime(2026, 5, 15, 14);
    final hits = <Food>[
      _food(
        id: 'l1',
        name: 'Greek yogurt, plain',
        brand: 'Fage',
        lastLoggedAt: now.subtract(const Duration(days: 1)),
        logCount: 3,
      ),
      _food(id: 'c1', name: 'Yogurt, vanilla', brand: 'Stonyfield'),
      _food(
        id: 'l2',
        name: 'Greek yogurt, 2%',
        brand: 'Chobani',
        lastLoggedAt: now.subtract(const Duration(days: 2)),
        logCount: 5,
      ),
      _food(id: 'c2', name: 'Yogurt, strawberry', brand: 'Yoplait'),
      _food(id: 'c3', name: 'Yogurt, blueberry', brand: 'Chobani'),
    ];
    await pumpHarness(tester, _harness(searchResults: hits));
    await _typeQuery(tester, 'yog');

    expect(find.text('YOUR FOODS'), findsOneWidget);
    expect(find.text('ALL FOODS'), findsOneWidget);
    expect(find.text('(2)'), findsOneWidget); // logged
    expect(find.text('(3)'), findsOneWidget); // cold
    expect(find.byType(SearchResultRow), findsNWidgets(5));
  });

  testWidgets('within "YOUR FOODS" rows are sorted by lastLoggedAt desc',
      (tester) async {
    final now = DateTime(2026, 5, 15, 14);
    // Intentionally pass in oldest-first; widget should re-sort to newest-first.
    final hits = <Food>[
      _food(
        id: 'l_old',
        name: 'Older logged food',
        lastLoggedAt: now.subtract(const Duration(days: 5)),
        logCount: 1,
      ),
      _food(
        id: 'l_mid',
        name: 'Middle logged food',
        lastLoggedAt: now.subtract(const Duration(days: 2)),
        logCount: 1,
      ),
      _food(
        id: 'l_new',
        name: 'Newest logged food',
        lastLoggedAt: now.subtract(const Duration(days: 1)),
        logCount: 1,
      ),
    ];
    await pumpHarness(tester, _harness(searchResults: hits));
    await _typeQuery(tester, 'food');

    final rows = tester
        .widgetList<SearchResultRow>(
          find.byType(SearchResultRow),
        )
        .toList();
    expect(rows.map((r) => r.food.id).toList(),
        <String>['l_new', 'l_mid', 'l_old']);
  });

  testWidgets('sort tiebreaker — logCount desc, then id asc', (tester) async {
    // All three logged at the same instant.
    final at = DateTime(2026, 5, 15, 10);
    final hits = <Food>[
      _food(
        id: 'aaa',
        name: 'Tied A (count 2)',
        lastLoggedAt: at,
        logCount: 2,
      ),
      _food(
        id: 'bbb',
        name: 'Tied B (count 5)',
        lastLoggedAt: at,
        logCount: 5,
      ),
      _food(
        id: 'ccc',
        name: 'Tied C (count 2)',
        lastLoggedAt: at,
        logCount: 2,
      ),
    ];
    await pumpHarness(tester, _harness(searchResults: hits));
    await _typeQuery(tester, 'tied');

    final rows = tester
        .widgetList<SearchResultRow>(find.byType(SearchResultRow))
        .toList();
    // Expected order: bbb (count 5 wins), then aaa & ccc with count 2
    // (same count → id asc → aaa, ccc).
    expect(rows.map((r) => r.food.id).toList(), <String>['bbb', 'aaa', 'ccc']);
  });

  testWidgets(
      'pagination spinner sits at the bottom of "ALL FOODS" when both sections render',
      (tester) async {
    final now = DateTime(2026, 5, 15, 14);
    final hits = <Food>[
      _food(
        id: 'l1',
        name: 'Logged thing',
        lastLoggedAt: now.subtract(const Duration(days: 1)),
        logCount: 2,
      ),
      _food(id: 'c1', name: 'Cold thing 1'),
      _food(id: 'c2', name: 'Cold thing 2'),
    ];

    // Mount with both sections present; the pagination state defaults to
    // `isLoadingMore: false`. We then push the notifier into `isLoadingMore`
    // so the spinner appears, and confirm it lives below the cold list.
    final container = ProviderContainer(
      overrides: <Override>[
        recentFoodsProvider.overrideWith((_) async => const <Food>[]),
        frequentFoodsProvider.overrideWith((_) async => const <Food>[]),
        foodSearchProvider.overrideWith(
          (ref, query) async => query.trim().isEmpty ? <Food>[] : hits,
        ),
      ],
    );
    addTearDown(container.dispose);

    final router = GoRouter(
      initialLocation: '/foods/search',
      routes: <RouteBase>[
        GoRoute(
          path: '/foods/search',
          builder: (context, state) => const Scaffold(body: SearchScreen()),
        ),
        GoRoute(
          path: '/foods/:id',
          builder: (_, __) =>
              const Scaffold(body: Center(child: Text('detail'))),
        ),
      ],
    );

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: buildLightTheme(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _typeQuery(tester, 'thing');

    // Both sections rendered, no spinner yet.
    expect(find.text('YOUR FOODS'), findsOneWidget);
    expect(find.text('ALL FOODS'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // Toggle the pagination notifier into `isLoadingMore: true` so the
    // _ResultsList rebuilds with a trailing spinner. The spinner is
    // an indeterminate `CircularProgressIndicator` which animates
    // forever — we use `pump()` (single frame) instead of
    // `pumpAndSettle()` so the test doesn't hang on the animation.
    final notifier =
        container.read(foodSearchPaginationProvider('thing').notifier);
    notifier.state = notifier.state.copyWith(isLoadingMore: true);
    await tester.pump();

    final spinners = find.byType(CircularProgressIndicator);
    expect(spinners, findsOneWidget);

    // The spinner should be visually after the "ALL FOODS" header — i.e.
    // its global y-position is below the "ALL FOODS" header's y-position.
    final spinnerY = tester.getCenter(spinners).dy;
    final coldHeaderY = tester.getCenter(find.text('ALL FOODS')).dy;
    final loggedHeaderY = tester.getCenter(find.text('YOUR FOODS')).dy;
    expect(spinnerY, greaterThan(coldHeaderY));
    expect(spinnerY, greaterThan(loggedHeaderY));
  });

  testWidgets(
      'pagination spinner sits below the only section when cold is empty',
      (tester) async {
    final now = DateTime(2026, 5, 15, 14);
    final hits = <Food>[
      _food(
        id: 'l1',
        name: 'Logged thing',
        lastLoggedAt: now.subtract(const Duration(days: 1)),
        logCount: 2,
      ),
    ];

    final container = ProviderContainer(
      overrides: <Override>[
        recentFoodsProvider.overrideWith((_) async => const <Food>[]),
        frequentFoodsProvider.overrideWith((_) async => const <Food>[]),
        foodSearchProvider.overrideWith(
          (ref, query) async => query.trim().isEmpty ? <Food>[] : hits,
        ),
      ],
    );
    addTearDown(container.dispose);

    final router = GoRouter(
      initialLocation: '/foods/search',
      routes: <RouteBase>[
        GoRoute(
          path: '/foods/search',
          builder: (context, state) => const Scaffold(body: SearchScreen()),
        ),
        GoRoute(
          path: '/foods/:id',
          builder: (_, __) =>
              const Scaffold(body: Center(child: Text('detail'))),
        ),
      ],
    );

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: buildLightTheme(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _typeQuery(tester, 'thing');

    // Only YOUR FOODS — no ALL FOODS header.
    expect(find.text('YOUR FOODS'), findsOneWidget);
    expect(find.text('ALL FOODS'), findsNothing);

    final notifier =
        container.read(foodSearchPaginationProvider('thing').notifier);
    notifier.state = notifier.state.copyWith(isLoadingMore: true);
    // Indeterminate spinner animates forever — use pump() not pumpAndSettle.
    await tester.pump();

    final spinner = find.byType(CircularProgressIndicator);
    expect(spinner, findsOneWidget);
    final spinnerY = tester.getCenter(spinner).dy;
    final headerY = tester.getCenter(find.text('YOUR FOODS')).dy;
    expect(spinnerY, greaterThan(headerY));
  });
}
