import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/food.dart';
import 'package:fulfilled/domain/serving.dart';
import 'package:fulfilled/domain/unit.dart';
import 'package:fulfilled/features/search/search_screen.dart';
import 'package:fulfilled/features/search/widgets/quick_chip_row.dart';
import 'package:fulfilled/features/search/widgets/search_field.dart';
import 'package:fulfilled/features/search/widgets/search_result_row.dart';
import 'package:fulfilled/providers/food_providers.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:decimal/decimal.dart';
import 'package:go_router/go_router.dart';

/// Widget tests for screen 02. The architect's brief requires at least:
///   1. Empty-query state shows both chip sections.
///   2. Typing triggers debounced search (we mock the provider with
///      `overrideWith`).
///
/// We mount the screen inside a tiny go_router so `context.push(...)`
/// calls in chip / result rows don't blow up. Providers are overridden
/// to deterministic in-memory lists so the test does not depend on the
/// repository's seed data or its mock latency.

Food _food({
  required String id,
  required String name,
  String? brand,
  FoodSource source = FoodSource.off,
  int kcal = 100,
}) {
  return Food(
    id: id,
    name: name,
    brand: brand,
    source: source,
    isCustom: source == FoodSource.user,
    servings: <Serving>[
      Serving(
        id: '${id}_s100',
        label: '1 serving (100 g)',
        amount: Decimal.fromInt(100),
        unit: Unit.g,
        kcal: Decimal.fromInt(kcal),
        isDefault: true,
        source: ServingSource.off,
      ),
    ],
  );
}

final _recent = <Food>[
  _food(id: 'r1', name: 'Greek yogurt, plain', kcal: 130),
  _food(id: 'r2', name: 'Oatmeal, rolled', kcal: 150),
];
final _frequent = <Food>[
  _food(id: 'q1', name: 'Eggs, large', kcal: 72),
  _food(id: 'q2', name: 'Chicken breast', kcal: 165),
];
final _yogurtHits = <Food>[
  _food(
    id: 'h1',
    name: 'Greek yogurt, plain, nonfat',
    brand: 'Fage',
    kcal: 130,
  ),
  _food(
    id: 'h2',
    name: 'Greek yogurt, 2% milkfat',
    brand: 'Chobani',
    kcal: 140,
  ),
];

Widget _harness({List<Override> overrides = const <Override>[]}) {
  final router = GoRouter(
    initialLocation: '/foods/search',
    routes: <RouteBase>[
      GoRoute(
        path: '/foods/search',
        builder: (context, state) => const SearchScreen(),
      ),
      // Stubs for the destinations the rows can push to.
      GoRoute(
        path: '/foods/:id',
        builder: (context, state) =>
            const Scaffold(body: Center(child: Text('detail'))),
      ),
    ],
  );
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp.router(
      theme: buildLightTheme(),
      routerConfig: router,
    ),
  );
}

void main() {
  testWidgets('empty query renders both Recent and Frequent chip sections',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _harness(
        overrides: <Override>[
          recentFoodsProvider.overrideWith((_) async => _recent),
          frequentFoodsProvider.overrideWith((_) async => _frequent),
        ],
      ),
    );
    // Resolve the async providers.
    await tester.pump();
    await tester.pumpAndSettle();

    // Both eyebrow headers visible.
    expect(find.text('RECENT'), findsOneWidget);
    expect(find.text('FREQUENT'), findsOneWidget);

    // Two QuickChipRows total.
    expect(find.byType(QuickChipRow), findsNWidgets(2));

    // Chip labels — both Recent and Frequent samples are rendered.
    expect(find.text('Greek yogurt, plain'), findsOneWidget);
    expect(find.text('Oatmeal, rolled'), findsOneWidget);
    expect(find.text('Eggs, large'), findsOneWidget);
    expect(find.text('Chicken breast'), findsOneWidget);

    // No results section header until the user types.
    expect(find.text('RESULTS'), findsNothing);
  });

  testWidgets(
      'typing a query swaps in the results list and renders SearchResultRows',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _harness(
        overrides: <Override>[
          recentFoodsProvider.overrideWith((_) async => _recent),
          frequentFoodsProvider.overrideWith((_) async => _frequent),
          // Override the family so any non-empty query returns the same
          // canned list — bypassing the 250 ms debounce so the test
          // doesn't need wall-clock pumping.
          foodSearchProvider.overrideWith((ref, query) async {
            final q = query.trim();
            if (q.isEmpty) return const <Food>[];
            return _yogurtHits;
          }),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // Find the lone TextField inside the SearchField widget and type.
    final fieldFinder = find.descendant(
      of: find.byType(SearchField),
      matching: find.byType(TextField),
    );
    expect(fieldFinder, findsOneWidget);
    await tester.enterText(fieldFinder, 'greek yogurt');
    await tester.pumpAndSettle();

    // Results header + count appear; chip headers disappear.
    expect(find.text('RESULTS'), findsOneWidget);
    expect(find.text('2 foods'), findsOneWidget);
    expect(find.text('RECENT'), findsNothing);
    expect(find.text('FREQUENT'), findsNothing);

    // The result rows are SearchResultRows, one per hit.
    expect(find.byType(SearchResultRow), findsNWidgets(2));
  });

  testWidgets('empty result set shows an inline empty-state message',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _harness(
        overrides: <Override>[
          recentFoodsProvider.overrideWith((_) async => _recent),
          frequentFoodsProvider.overrideWith((_) async => _frequent),
          foodSearchProvider
              .overrideWith((ref, query) async => const <Food>[]),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final fieldFinder = find.descendant(
      of: find.byType(SearchField),
      matching: find.byType(TextField),
    );
    await tester.enterText(fieldFinder, 'zzz_no_match');
    await tester.pumpAndSettle();

    expect(find.text('RESULTS'), findsOneWidget);
    expect(find.text('0 foods'), findsOneWidget);
    // T-013 — canonical empty-state copy is "No matches" + "Try a
    // different name." across the search surface.
    expect(find.text('No matches'), findsOneWidget);
    expect(find.text('Try a different name.'), findsOneWidget);
    expect(find.byType(SearchResultRow), findsNothing);
  });
}
