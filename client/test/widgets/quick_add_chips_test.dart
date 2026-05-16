import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/food.dart';
import 'package:fulfilled/domain/nutrition.dart';
import 'package:fulfilled/domain/serving.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/empty_state.dart';
import 'package:fulfilled/widgets/primary_button.dart';
import 'package:fulfilled/widgets/quick_add_chips.dart';
import 'package:go_router/go_router.dart';

/// T-013 (B9 absorbed) — the Quick add card on the expanded right rail:
/// - both providers empty → render the lifted `EmptyState` with the
///   "Find a food" CTA.
/// - only recents populated → render the Recent section, no EmptyState.
/// - only frequents populated → render the Frequent section, no
///   EmptyState.

Food _food(String id, String name) {
  return Food(
    id: id,
    name: name,
    source: FoodSource.user,
    isCustom: true,
    nutritionPer100g: NutritionPer100g(energyKcal: Decimal.fromInt(100)),
    servings: <Serving>[
      Serving(
        id: '${id}_s',
        name: '1 serving (100 g)',
        grams: Decimal.fromInt(100),
        isDefault: true,
        source: ServingSource.system,
      ),
    ],
  );
}

Widget _harness(Widget child) {
  final router = GoRouter(
    initialLocation: '/',
    routes: <RouteBase>[
      GoRoute(path: '/', builder: (_, __) => Scaffold(body: child)),
      GoRoute(
        path: '/foods/search',
        builder: (_, __) => const Scaffold(body: SizedBox.shrink()),
      ),
    ],
  );
  return MaterialApp.router(
    theme: buildLightTheme(),
    routerConfig: router,
  );
}

void main() {
  testWidgets(
    'both lists empty → EmptyState + "Find a food" CTA renders inside the card',
    (tester) async {
      tester.view.physicalSize = const Size(960, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_harness(
        QuickAddChips(
          recents: const <Food>[],
          frequents: const <Food>[],
          onTapFood: (_) {},
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(EmptyState), findsOneWidget);
      expect(find.text('No recents yet'), findsOneWidget);
      expect(find.text('Find a food'), findsOneWidget);
      // The CTA flows through the lifted PrimaryButton primitive (T-23).
      expect(find.byType(PrimaryButton), findsOneWidget);

      // The previous "Log a food and it will show up here." copy is gone.
      expect(find.text('Log a food and it will show up here.'), findsNothing);
    },
  );

  testWidgets(
    'recents populated, frequents empty → only Recent section renders',
    (tester) async {
      tester.view.physicalSize = const Size(960, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_harness(
        QuickAddChips(
          recents: <Food>[_food('r1', 'Greek yogurt')],
          frequents: const <Food>[],
          onTapFood: (_) {},
        ),
      ));
      await tester.pumpAndSettle();

      // Recent section header is present, Frequent is not.
      expect(find.text('Recent'), findsOneWidget);
      expect(find.text('Frequent'), findsNothing);
      // No empty-state should fire when one side is populated.
      expect(find.byType(EmptyState), findsNothing);
      expect(find.text('Greek yogurt'), findsOneWidget);
    },
  );

  testWidgets(
    'recents empty, frequents populated → only Frequent section renders',
    (tester) async {
      tester.view.physicalSize = const Size(960, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_harness(
        QuickAddChips(
          recents: const <Food>[],
          frequents: <Food>[_food('f1', 'Chicken breast')],
          onTapFood: (_) {},
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Frequent'), findsOneWidget);
      expect(find.text('Recent'), findsNothing);
      expect(find.byType(EmptyState), findsNothing);
      expect(find.text('Chicken breast'), findsOneWidget);
    },
  );
}
