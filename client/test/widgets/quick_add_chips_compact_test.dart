// UX-107 F2 — `QuickAddChips.compact` flag behavior.
//
// Acceptance:
// 1. `compact: false` (default) renders the existing right-rail card
//    branch — eyebrow "Quick add" + section headers visible. The card
//    chrome is unchanged; this is the regression-guard against the
//    expanded right rail (architect §4.6 / dev-ticket UX-107).
// 2. `compact: true` renders the horizontal-scroll strip — no card
//    chrome, no eyebrow, no section headers, and the inner `ListView`
//    has `scrollDirection: Axis.horizontal`.
// 3. `compact: true` respects `maxChips` — `maxChips: 4` with 6 recents
//    renders four chips, not six.
// 4. `compact: true, recents: const []` short-circuits to
//    `SizedBox.shrink()` (zero size) — the empty-state placeholder
//    behavior lives in the caller's gate, not in the widget.
//
// The compact strip is recents-only by construction; the `frequents`
// argument is ignored. We pass an empty `frequents` in the compact
// tests so a regression that *did* render frequents would surface as
// extra chips.

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/food.dart';
import 'package:fulfilled/domain/nutrition.dart';
import 'package:fulfilled/domain/serving.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/quick_add_chips.dart';
import 'package:go_router/go_router.dart';

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

List<Food> _foods(int n) =>
    List<Food>.generate(n, (i) => _food('r$i', 'Food $i'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'compact false renders the card branch (eyebrow + section headers)',
    (tester) async {
      tester.view.physicalSize = const Size(960, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_harness(
        QuickAddChips(
          recents: <Food>[_food('r1', 'Greek yogurt')],
          frequents: <Food>[_food('f1', 'Chicken breast')],
          onTapFood: (_) {},
        ),
      ));
      await tester.pumpAndSettle();

      // Eyebrow + section headers identify the card branch.
      expect(find.text('Quick add'), findsOneWidget);
      expect(find.text('Recent'), findsOneWidget);
      expect(find.text('Frequent'), findsOneWidget);
      // The card branch wraps in a vertical `Wrap`, never a horizontal
      // `ListView` — the compact strip's signature widget is absent.
      expect(find.byType(ListView), findsNothing);
    },
  );

  testWidgets(
    'compact true renders a horizontal-scroll strip — no card chrome, no eyebrow',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_harness(
        QuickAddChips(
          compact: true,
          recents: _foods(5),
          frequents: const <Food>[],
          onTapFood: (_) {},
        ),
      ));
      await tester.pumpAndSettle();

      // No eyebrow, no section headers — the card chrome is gone.
      expect(find.text('Quick add'), findsNothing);
      expect(find.text('Recent'), findsNothing);
      expect(find.text('Frequent'), findsNothing);

      // The inner ListView is horizontal.
      final listView = tester.widget<ListView>(find.byType(ListView));
      expect(listView.scrollDirection, Axis.horizontal);
    },
  );

  testWidgets(
    'compact true respects maxChips (4 of 6 render)',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_harness(
        QuickAddChips(
          compact: true,
          maxChips: 4,
          recents: _foods(6),
          frequents: const <Food>[],
          onTapFood: (_) {},
        ),
      ));
      await tester.pumpAndSettle();

      // Food 0..3 render; Food 4 and 5 do not.
      expect(find.text('Food 0'), findsOneWidget);
      expect(find.text('Food 1'), findsOneWidget);
      expect(find.text('Food 2'), findsOneWidget);
      expect(find.text('Food 3'), findsOneWidget);
      expect(find.text('Food 4'), findsNothing);
      expect(find.text('Food 5'), findsNothing);
    },
  );

  testWidgets(
    'compact true with empty recents short-circuits to SizedBox.shrink',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_harness(
        QuickAddChips(
          compact: true,
          recents: const <Food>[],
          frequents: const <Food>[],
          onTapFood: (_) {},
        ),
      ));
      await tester.pumpAndSettle();

      // The widget renders nothing — no ListView, no card, no eyebrow.
      expect(find.byType(ListView), findsNothing);
      expect(find.text('Quick add'), findsNothing);
      // The QuickAddChips widget itself still exists in the tree, but
      // its render output has zero size (it returned SizedBox.shrink).
      final size = tester.getSize(find.byType(QuickAddChips));
      expect(size, Size.zero);
    },
  );

  testWidgets(
    'compact true tap fires onTapFood with the tapped food',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final tapped = <String>[];
      await tester.pumpWidget(_harness(
        QuickAddChips(
          compact: true,
          recents: <Food>[
            _food('r1', 'Greek yogurt'),
            _food('r2', 'Oatmeal'),
          ],
          frequents: const <Food>[],
          onTapFood: (food) => tapped.add(food.id),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Greek yogurt'));
      await tester.pumpAndSettle();

      expect(tapped, <String>['r1']);
    },
  );
}
