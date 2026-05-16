import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/food.dart';
import 'package:fulfilled/domain/nutrition.dart';
import 'package:fulfilled/domain/serving.dart';
import 'package:fulfilled/features/search/widgets/search_result_row.dart';
import 'package:fulfilled/theme/theme_data.dart';

/// T-022 — `SearchResultRow` composed-semantics audit.
///
/// The architect's contract for screen 02:
///   `"$name, $serving, $kcal kilocalories"` at the row root, with the
///   visual leaves excluded. The acceptance criterion in the ticket is
///   that `find.bySemanticsLabel(RegExp(r'kilocalories'))` finds the row.
///
/// Stub-only: not executed by this agent. Harness + router scaffolding
/// matches the pattern in `test/features/search/search_screen_test.dart`.
Food _food({
  required String name,
  String? brand,
  int kcal = 130,
  String servingLabel = '1 container (170 g)',
}) {
  return Food(
    id: 'food_1',
    name: name,
    brand: brand,
    source: FoodSource.off,
    isCustom: false,
    nutritionPer100g: NutritionPer100g(
      energyKcal: Decimal.fromInt(kcal),
    ),
    servings: <Serving>[
      Serving(
        id: 'sv_1',
        name: servingLabel,
        grams: Decimal.fromInt(170),
        isDefault: true,
        source: ServingSource.system,
      ),
    ],
  );
}

Widget _harness(Widget child) {
  // Mount a router so `context.push('/foods/...')` doesn't blow up in
  // SearchResultRow's default `onTap`.
  final router = GoRouter(
    routes: <RouteBase>[
      GoRoute(path: '/', builder: (_, __) => Scaffold(body: child)),
      GoRoute(path: '/foods/:id', builder: (_, __) => const SizedBox.shrink()),
    ],
  );
  return MaterialApp.router(
    routerConfig: router,
    theme: buildLightTheme(),
  );
}

void main() {
  testWidgets('composed label includes name + serving + kcal + kilocalories',
      (tester) async {
    final handle = tester.ensureSemantics();
    addTearDown(handle.dispose);

    await tester.pumpWidget(
      _harness(
        SearchResultRow(
          food: _food(name: 'Greek yogurt'),
          query: '',
        ),
      ),
    );

    // The composed phrase reads "Greek yogurt, 1 container (170 g),
    // 130 kilocalories". We assert against the acceptance criterion
    // first (the "kilocalories" word is the load-bearing token), then
    // a tighter regex on name + kcal so a future re-shuffle of the
    // serving phrase still passes the kcal sub-clause.
    expect(
      find.bySemanticsLabel(RegExp(r'kilocalories')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp(r'Greek yogurt.*130 kilocalories')),
      findsOneWidget,
    );
  });

  testWidgets('children are excluded — no per-leaf labels leak',
      (tester) async {
    final handle = tester.ensureSemantics();
    addTearDown(handle.dispose);

    await tester.pumpWidget(
      _harness(
        SearchResultRow(
          food: _food(name: 'Greek yogurt'),
          query: '',
        ),
      ),
    );

    // The visual " · " meta line and the raw "130" leaf are excluded so
    // a screen reader doesn't read them separately. We assert the bare
    // numeric `130` doesn't appear in the semantics tree.
    expect(find.bySemanticsLabel('130'), findsNothing);
    expect(find.bySemanticsLabel('per container'), findsNothing);
  });
}
