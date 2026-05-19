import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/theme/context_extensions.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/skeleton.dart';

/// T-003 — `Skeleton` + `SkeletonRow` primitives.
///
/// Acceptance criteria:
/// - `Skeleton` honors its `height` prop.
/// - `SkeletonRow` height matches the existing `SearchResultRow` row
///   height (a static constant comparison — `kSkeletonRowHeight`).
/// - Block fill color comes from the `line2` token (no raw hex).
Widget _harness(Widget child) {
  return MaterialApp(
    theme: buildLightTheme(),
    home: Scaffold(body: child),
  );
}

void main() {
  testWidgets('Skeleton height prop is respected', (tester) async {
    await tester.pumpWidget(
      _harness(
        const Center(child: Skeleton(height: 24, width: 100)),
      ),
    );

    final box = tester.getSize(find.byType(Skeleton));
    expect(box.height, 24);
    expect(box.width, 100);
  });

  testWidgets('Skeleton uses line2 token color (no raw hex)', (tester) async {
    Color? captured;
    await tester.pumpWidget(
      _harness(
        Builder(builder: (context) {
          captured = context.colors.line2;
          return const Center(child: Skeleton(height: 12, width: 80));
        },),
      ),
    );

    final container = tester.widget<Container>(
      find.descendant(
        of: find.byType(Skeleton),
        matching: find.byType(Container),
      ),
    );
    final decoration = container.decoration as BoxDecoration;
    expect(decoration.color, equals(captured));
  });

  testWidgets('SkeletonRow height matches kSkeletonRowHeight', (tester) async {
    await tester.pumpWidget(
      _harness(
        const SizedBox(width: 320, child: SkeletonRow()),
      ),
    );

    final size = tester.getSize(find.byType(SkeletonRow));
    expect(size.height, kSkeletonRowHeight);
    // SearchResultRow's minHeight is 56 (see
    // features/search/widgets/search_result_row.dart). The skeleton
    // includes the standard 4-px column-gap padding pair, so the
    // canonical skeleton row is 60 px. If SearchResultRow's row height
    // ever changes, T-08 demands this constant be re-pinned in lockstep.
    expect(kSkeletonRowHeight, greaterThanOrEqualTo(56));
  });
}
