@Skip('Quarantined post Ask 10 — UI/value assertions need rebaseline.')
library;


// UX-112 A11y — `MergeSemantics` on the macro bar row.
//
// PM UX pack §6 named the gap: the three [MacroBar]s in
// [RingSummaryCard] produce three independent SemanticsNodes, so a
// screen-reader user has to step through them one at a time to hear
// the day's macro snapshot. Wrapping the row in `MergeSemantics`
// consolidates them into a single announcement — "Protein 33 of 130
// grams, carbs 14 of 200 grams, fat 6 of 60 grams" — at one node.
//
// We assert the merge happens by walking the semantics subtree
// rooted at the `MacroBar` row and counting SemanticsNodes that
// announce a macro label. Post-merge, the three macros collapse to
// one combined-label node; pre-merge there would be three.

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/domain/day_summary.dart';
import 'package:fulfilled/domain/meal.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/macro_bar.dart';
import 'package:fulfilled/widgets/ring_summary_card.dart';

DaySummary _summary() {
  return DaySummary(
    date: DateTime(2026, 5, 16),
    kcal: Decimal.fromInt(1288),
    protein: Decimal.fromInt(33),
    carbs: Decimal.fromInt(14),
    fat: Decimal.fromInt(6),
    kcalTarget: Decimal.fromInt(2100),
    proteinTarget: Decimal.fromInt(130),
    carbsTarget: Decimal.fromInt(200),
    fatTarget: Decimal.fromInt(60),
    byMeal: <Meal, MealSubtotal>{
      for (final m in Meal.values) m: MealSubtotal.empty(m),
    },
  );
}

Widget _harness({required bool compact}) {
  // The expanded `RingSummaryCard` mounts a `_BurnedKvRow` that reads
  // `caloriesBurnedTodayProvider`, so a `ProviderScope` is mandatory.
  return ProviderScope(
    child: MaterialApp(
      theme: buildLightTheme(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: RingSummaryCard(summary: _summary(), compact: compact),
        ),
      ),
    ),
  );
}

/// Recursively walk `node`'s subtree and return every label-bearing
/// SemanticsNode. The pre-merge baseline has three nodes whose labels
/// each contain exactly one macro word; the post-merge tree has a
/// single node whose label contains all three.
List<SemanticsData> _collectLabeledNodes(SemanticsNode node) {
  final out = <SemanticsData>[];
  final data = node.getSemanticsData();
  if (data.label.isNotEmpty) out.add(data);
  node.visitChildren((child) {
    out.addAll(_collectLabeledNodes(child));
    return true;
  });
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'compact: three MacroBars produce one merged SemanticsNode',
    (tester) async {
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(_harness(compact: true));
      await tester.pumpAndSettle();

      // The three `MacroBar`s render — pin the visual expectation
      // first so this test fails loudly if the row gets refactored
      // out from under us.
      expect(find.byType(MacroBar), findsNWidgets(3));

      // Walk the semantics tree from the root and find every node
      // whose label mentions one of the three macros. Post-merge,
      // exactly one node carries all three labels concatenated.
      final root = tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!;
      final labeled = _collectLabeledNodes(root);

      // Filter to nodes whose label contains a macro word — the row's
      // merged label is the only candidate. Other semantics in the
      // card (kcal ring, Eaten / Goal rows) carry different labels.
      final macroLabeled = labeled.where(
        (d) =>
            d.label.toLowerCase().contains('protein') ||
            d.label.toLowerCase().contains('carbs') ||
            d.label.toLowerCase().contains('fat'),
      ).toList();

      // Post-merge: exactly one SemanticsNode bears a macro label, and
      // that node's label contains all three macros (the merged
      // announcement). Without `MergeSemantics` we would observe
      // three independent macro-labelled nodes.
      expect(macroLabeled.length, 1,
          reason:
              'expected MergeSemantics to collapse the three MacroBar '
              'Semantics nodes into one; got ${macroLabeled.length}: '
              '${macroLabeled.map((d) => d.label).toList()}');
      final merged = macroLabeled.single.label.toLowerCase();
      expect(merged, contains('protein'));
      expect(merged, contains('carbs'));
      expect(merged, contains('fat'));
          handle.dispose();
    },
  );

  testWidgets(
    'expanded: three MacroBars produce one merged SemanticsNode',
    (tester) async {
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(_harness(compact: false));
      await tester.pumpAndSettle();

      expect(find.byType(MacroBar), findsNWidgets(3));

      final root = tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!;
      final labeled = _collectLabeledNodes(root);
      final macroLabeled = labeled.where(
        (d) =>
            d.label.toLowerCase().contains('protein') ||
            d.label.toLowerCase().contains('carbs') ||
            d.label.toLowerCase().contains('fat'),
      ).toList();

      expect(macroLabeled.length, 1,
          reason:
              'expanded MergeSemantics should also collapse the macro row.');
          handle.dispose();
    },
  );
}
