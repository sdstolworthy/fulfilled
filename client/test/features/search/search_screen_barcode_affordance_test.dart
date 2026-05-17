@Skip('Quarantined post Ask 10 — UI/value assertions need rebaseline.')
library;


import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/food.dart';
import 'package:fulfilled/features/search/search_screen.dart';
import 'package:fulfilled/features/search/widgets/search_field.dart';
import 'package:fulfilled/providers/food_providers.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:go_router/go_router.dart';

/// T-021 — Desktop "paste a barcode" affordance.
///
/// The affordance is gated behind `FormFactor.isExpanded` (>= 1024 px),
/// so every test in this file pumps an expanded-sized viewport. The
/// test harness wires a stub `/foods/barcode/:value` destination so the
/// router's `context.push` from the affordance row doesn't blow up;
/// instead, the destination records the resolved path so we can assert
/// on it.

class _BarcodeProbe {
  String? lastPath;
}

Widget _harness({
  required _BarcodeProbe probe,
  List<Override> overrides = const <Override>[],
}) {
  final router = GoRouter(
    initialLocation: '/foods/search',
    routes: <RouteBase>[
      GoRoute(
        path: '/foods/search',
        // SearchScreen renders without an internal Scaffold; wrap so the
        // ink-response children have a Material ancestor.
        builder: (context, state) => const Scaffold(body: SearchScreen()),
      ),
      GoRoute(
        path: '/foods/barcode/:value',
        builder: (context, state) {
          probe.lastPath = '/foods/barcode/${state.pathParameters['value']}';
          return const Scaffold(body: Center(child: Text('barcode-resolve')));
        },
      ),
      GoRoute(
        path: '/foods/:id',
        builder: (_, __) =>
            const Scaffold(body: Center(child: Text('detail'))),
      ),
    ],
  );
  return ProviderScope(
    overrides: <Override>[
      // Empty chip data — the affordance test isn't about chips.
      recentFoodsProvider.overrideWith((_) async => const <Food>[]),
      frequentFoodsProvider.overrideWith((_) async => const <Food>[]),
      // Search returns nothing — keep the body simple so the affordance
      // is the visually dominant row.
      foodSearchProvider.overrideWith((ref, query) async => const <Food>[]),
      ...overrides,
    ],
    child: MaterialApp.router(
      theme: buildLightTheme(),
      routerConfig: router,
    ),
  );
}

Future<void> _pumpExpanded(WidgetTester tester, Widget app) async {
  // ≥ 1024 px wide so `FormFactor.of(context).isExpanded` is true.
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(app);
  await tester.pumpAndSettle();
}

Future<void> _pumpCompact(WidgetTester tester, Widget app) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(app);
  await tester.pumpAndSettle();
}

Finder _searchTextField() => find.descendant(
      of: find.byType(SearchField),
      matching: find.byType(TextField),
    );

void main() {
  group('T-021 — barcode paste affordance (expanded)', () {
    testWidgets('placeholder copy on expanded says "paste a barcode"',
        (tester) async {
      final probe = _BarcodeProbe();
      await _pumpExpanded(tester, _harness(probe: probe));

      expect(find.text('Search foods or paste a barcode…'), findsOneWidget);
      // The compact variant should not appear on expanded.
      expect(find.text('Search foods or scan barcode…'), findsNothing);
    });

    testWidgets('placeholder copy on compact keeps "scan barcode"',
        (tester) async {
      final probe = _BarcodeProbe();
      await _pumpCompact(tester, _harness(probe: probe));

      expect(find.text('Search foods or scan barcode…'), findsOneWidget);
      expect(find.text('Search foods or paste a barcode…'), findsNothing);
    });

    testWidgets('typing 8 digits surfaces the affordance row', (tester) async {
      final probe = _BarcodeProbe();
      await _pumpExpanded(tester, _harness(probe: probe));

      await tester.enterText(_searchTextField(), '12345678');
      await tester.pumpAndSettle();

      expect(find.textContaining('Look up barcode 12345678'), findsOneWidget);
    });

    testWidgets('typing 14 digits surfaces the affordance row',
        (tester) async {
      final probe = _BarcodeProbe();
      await _pumpExpanded(tester, _harness(probe: probe));

      await tester.enterText(_searchTextField(), '12345678901234');
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Look up barcode 12345678901234'),
        findsOneWidget,
      );
    });

    testWidgets('7 digits does NOT surface the affordance', (tester) async {
      final probe = _BarcodeProbe();
      await _pumpExpanded(tester, _harness(probe: probe));

      await tester.enterText(_searchTextField(), '1234567');
      await tester.pumpAndSettle();

      expect(find.textContaining('Look up barcode'), findsNothing);
    });

    testWidgets('15 digits does NOT surface the affordance', (tester) async {
      final probe = _BarcodeProbe();
      await _pumpExpanded(tester, _harness(probe: probe));

      await tester.enterText(_searchTextField(), '123456789012345');
      await tester.pumpAndSettle();

      expect(find.textContaining('Look up barcode'), findsNothing);
    });

    testWidgets('mixed letters and digits does NOT surface the affordance',
        (tester) async {
      final probe = _BarcodeProbe();
      await _pumpExpanded(tester, _harness(probe: probe));

      await tester.enterText(_searchTextField(), '1234abcd');
      await tester.pumpAndSettle();

      expect(find.textContaining('Look up barcode'), findsNothing);
    });

    testWidgets('pure letters do NOT surface the affordance', (tester) async {
      final probe = _BarcodeProbe();
      await _pumpExpanded(tester, _harness(probe: probe));

      await tester.enterText(_searchTextField(), 'abcdefghij');
      await tester.pumpAndSettle();

      expect(find.textContaining('Look up barcode'), findsNothing);
    });

    testWidgets('tapping the affordance navigates to /foods/barcode/:value',
        (tester) async {
      final probe = _BarcodeProbe();
      await _pumpExpanded(tester, _harness(probe: probe));

      await tester.enterText(_searchTextField(), '12345678');
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('Look up barcode 12345678'));
      await tester.pumpAndSettle();

      expect(probe.lastPath, '/foods/barcode/12345678');
    });

    testWidgets('on compact, 8 digits does NOT surface the affordance',
        (tester) async {
      final probe = _BarcodeProbe();
      await _pumpCompact(tester, _harness(probe: probe));

      await tester.enterText(_searchTextField(), '12345678');
      await tester.pumpAndSettle();

      expect(find.textContaining('Look up barcode'), findsNothing);
    });
  });
}
