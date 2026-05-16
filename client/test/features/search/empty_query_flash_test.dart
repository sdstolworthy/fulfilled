// QL-109 — empty-query flash regression test.
//
// When the user types a query and then clears the field, the chip
// rest-state (Recent / Frequent) must return immediately. The results
// list must not flash empty during the debounce window. See
// `search_screen.dart` `_ResultsSection` (defensive empty-query
// short-circuit) and `SearchScreenBody.build` (`isQueryActive` ternary).

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/food.dart';
import 'package:fulfilled/domain/nutrition.dart';
import 'package:fulfilled/domain/serving.dart';
import 'package:fulfilled/features/search/search_screen.dart';
import 'package:fulfilled/features/search/widgets/quick_chip_row.dart';
import 'package:fulfilled/features/search/widgets/search_field.dart';
import 'package:fulfilled/features/search/widgets/search_result_row.dart';
import 'package:fulfilled/providers/food_providers.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:go_router/go_router.dart';

Food _food({
  required String id,
  required String name,
  int kcal = 100,
}) {
  return Food(
    id: id,
    name: name,
    source: FoodSource.off,
    isCustom: false,
    nutritionPer100g: NutritionPer100g(energyKcal: Decimal.fromInt(kcal)),
    servings: <Serving>[
      Serving(
        id: '${id}_s100',
        name: '100 g',
        grams: Decimal.fromInt(100),
        isDefault: true,
        source: ServingSource.system,
      ),
    ],
  );
}

final _recent = <Food>[
  _food(id: 'r1', name: 'Greek yogurt, plain', kcal: 130),
];
final _frequent = <Food>[
  _food(id: 'q1', name: 'Eggs, large', kcal: 72),
];
final _yogurtHits = <Food>[
  _food(id: 'h1', name: 'Greek yogurt, plain, nonfat', kcal: 130),
  _food(id: 'h2', name: 'Greek yogurt, 2% milkfat', kcal: 140),
];

Widget _harness({List<Override> overrides = const <Override>[]}) {
  final router = GoRouter(
    initialLocation: '/foods/search',
    routes: <RouteBase>[
      GoRoute(
        path: '/foods/search',
        builder: (context, state) => const SearchScreen(),
      ),
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
  testWidgets(
    'clearing the query returns to the chip rest-state without flashing '
    'an empty results list',
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
            // Non-empty queries return canned hits synchronously,
            // empty queries must never reach the provider (the screen
            // should short-circuit before then) — assert by checking
            // for the canned result text after clearing.
            foodSearchProvider.overrideWith((ref, query) async {
              final q = query.trim();
              if (q.isEmpty) return const <Food>[];
              return _yogurtHits;
            }),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // Type a query — results section appears.
      final fieldFinder = find.descendant(
        of: find.byType(SearchField),
        matching: find.byType(TextField),
      );
      await tester.enterText(fieldFinder, 'greek');
      await tester.pumpAndSettle();
      expect(find.text('RESULTS'), findsOneWidget);
      expect(find.byType(SearchResultRow), findsNWidgets(2));
      // Chip headers gone while results are showing.
      expect(find.text('RECENT'), findsNothing);
      expect(find.text('FREQUENT'), findsNothing);

      // Clear the field. Immediately after the synchronous frame —
      // before any debounce / async result settles — the chip headers
      // must already be visible, and the RESULTS header / row widgets
      // must be gone. `tester.pump()` (no duration) processes only the
      // setState rebuild, so this asserts the synchronous switch.
      await tester.enterText(fieldFinder, '');
      await tester.pump();

      expect(find.text('RESULTS'), findsNothing,
          reason: 'Results header must not linger after the field clears');
      expect(find.byType(SearchResultRow), findsNothing,
          reason: 'Stale result rows must not paint between query clear and '
              'debounce settle');
      expect(find.byType(QuickChipRow), findsNWidgets(2),
          reason: 'Chip rest-state must return on the same frame the query '
              'becomes empty');
      expect(find.text('RECENT'), findsOneWidget);
      expect(find.text('FREQUENT'), findsOneWidget);
    },
  );
}
