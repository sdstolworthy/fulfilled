import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/enums.dart';
import 'package:fulfilled/domain/food.dart';
import 'package:fulfilled/domain/serving.dart';
import 'package:fulfilled/domain/unit.dart';
import 'package:fulfilled/features/search/widgets/search_result_row.dart';
import 'package:fulfilled/theme/theme_data.dart';

/// F5-T4 — Widget-level tests for the search-result row's logged /
/// never-logged rendering, plus the a11y label prepend.
///
/// We exercise the row directly (no provider scope) — the row reads its
/// `Food` argument and the theme tokens, nothing else.

Food _food({
  required String id,
  required String name,
  String? brand,
  FoodSource source = FoodSource.off,
  int kcal = 130,
  DateTime? lastLoggedAt,
  int? logCount,
  String? lastServingId,
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
        label: '1 cup',
        amount: Decimal.fromInt(245),
        unit: Unit.g,
        kcal: Decimal.fromInt(kcal),
        isDefault: true,
        source: ServingSource.off,
      ),
    ],
    lastLoggedAt: lastLoggedAt,
    logCount: logCount,
    lastServingId: lastServingId,
  );
}

Widget _harness(Widget child) {
  return MaterialApp(
    theme: buildLightTheme(),
    home: Scaffold(body: child),
  );
}

void main() {
  // Pin "today" relative to the rows so DateFormat output is predictable.
  // The widget itself doesn't accept a clock parameter — these tests
  // verify rendering, not the formatter (`logged_subline_test.dart`
  // covers the formatter end). To keep the brand-line vs. logged-line
  // branch deterministic regardless of the host clock, we use
  // `DateTime.now()` as the seed so "Today" always wins.
  testWidgets('never-logged row renders brand · serving sub-line',
      (tester) async {
    final food = _food(
      id: 'h1',
      name: 'Greek yogurt, plain',
      brand: 'Chobani',
      kcal: 130,
    );

    await tester.pumpWidget(_harness(
      SearchResultRow(food: food, query: 'greek'),
    ),);
    await tester.pumpAndSettle();

    // Brand + serving — "Chobani · 1 cup".
    expect(find.text('Chobani · 1 cup'), findsOneWidget);
    // No "Logged" sub-line.
    expect(
      find.byWidgetPredicate(
        (w) => w is Text && (w.data ?? '').startsWith('Logged '),
      ),
      findsNothing,
    );
  });

  testWidgets('logged row renders "Logged Today · 4×" sub-line',
      (tester) async {
    final now = DateTime.now();
    final food = _food(
      id: 'h2',
      name: 'Greek yogurt, plain',
      brand: 'Chobani',
      kcal: 130,
      lastLoggedAt: now,
      logCount: 4,
    );

    await tester.pumpWidget(_harness(
      SearchResultRow(food: food, query: 'greek'),
    ),);
    await tester.pumpAndSettle();

    // The sub-line says "Logged Today · 4×".
    expect(find.text('Logged Today · 4×'), findsOneWidget);
  });

  testWidgets(
      'logged row drops the brand sub-line — "Chobani · 1 cup" is absent',
      (tester) async {
    final now = DateTime.now();
    final food = _food(
      id: 'h3',
      name: 'Greek yogurt, plain',
      brand: 'Chobani',
      kcal: 130,
      lastLoggedAt: now,
      logCount: 2,
    );

    await tester.pumpWidget(_harness(
      SearchResultRow(food: food, query: 'greek'),
    ),);
    await tester.pumpAndSettle();

    expect(find.text('Logged Today · 2×'), findsOneWidget);
    // The brand-line is swapped out, not stacked alongside.
    expect(find.text('Chobani · 1 cup'), findsNothing);
  });

  testWidgets('logged row with count == 1 drops the count suffix',
      (tester) async {
    final now = DateTime.now();
    final food = _food(
      id: 'h4',
      name: 'Greek yogurt, plain',
      brand: 'Chobani',
      kcal: 130,
      lastLoggedAt: now,
      logCount: 1,
    );

    await tester.pumpWidget(_harness(
      SearchResultRow(food: food, query: 'greek'),
    ),);
    await tester.pumpAndSettle();

    expect(find.text('Logged Today'), findsOneWidget);
    expect(find.text('Logged Today · 1×'), findsNothing);
  });

  testWidgets('a11y label on a logged row starts with "Previously logged. "',
      (tester) async {
    final handle = tester.ensureSemantics();
    final now = DateTime.now();
    final food = _food(
      id: 'h5',
      name: 'Greek yogurt, plain',
      brand: 'Chobani',
      kcal: 130,
      lastLoggedAt: now,
      logCount: 4,
    );

    await tester.pumpWidget(_harness(
      SearchResultRow(food: food, query: 'greek'),
    ),);
    await tester.pumpAndSettle();

    // The composed semantic label is on the wrapping Semantics node — find
    // any node whose label starts with the F5 prepend.
    expect(
      find.bySemanticsLabel(
        RegExp(r'^Previously logged\. Greek yogurt, plain'),
      ),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('a11y label on a never-logged row has no prepend',
      (tester) async {
    final handle = tester.ensureSemantics();
    final food = _food(
      id: 'h6',
      name: 'Greek yogurt, plain',
      brand: 'Chobani',
      kcal: 130,
    );

    await tester.pumpWidget(_harness(
      SearchResultRow(food: food, query: 'greek'),
    ),);
    await tester.pumpAndSettle();

    // Label starts with the food name, not the F5 prepend.
    expect(
      find.bySemanticsLabel(RegExp(r'^Greek yogurt, plain')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp(r'^Previously logged\. ')),
      findsNothing,
    );
    handle.dispose();
  });
}
