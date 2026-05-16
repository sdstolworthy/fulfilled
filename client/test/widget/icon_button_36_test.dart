import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/theme/context_extensions.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/theme/tokens.dart';
import 'package:fulfilled/widgets/icon_button_36.dart';

/// T-003 — `IconButton36` primitive.
///
/// Acceptance criteria:
/// - Tooltip prop renders (find by tooltip text).
/// - Tap emits `onPressed`.
/// - Default icon color comes from the `ink` token (no raw hex).
Widget _harness(Widget child) {
  return MaterialApp(
    theme: buildLightTheme(),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  testWidgets('renders tooltip and tap emits onPressed', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _harness(
        IconButton36(
          icon: Icons.close,
          tooltip: 'Close',
          onPressed: () => taps++,
        ),
      ),
    );

    expect(find.byTooltip('Close'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('visual size is 36 x 36', (tester) async {
    await tester.pumpWidget(
      _harness(
        IconButton36(
          icon: Icons.qr_code_2,
          tooltip: 'Scan barcode',
          onPressed: () {},
        ),
      ),
    );

    // The widget's SizedBox is 36 px square; that's the visual footprint
    // T-20 / T-06 enforce. Match the specific SizedBox by its width/height
    // pair so we don't accidentally pick up an unrelated SizedBox.
    final box = tester.getSize(find.descendant(
      of: find.byType(IconButton36),
      matching: find.byWidgetPredicate(
        (w) => w is SizedBox && w.width == 36 && w.height == 36,
      ),
    ));
    expect(box.width, 36);
    expect(box.height, 36);
  });

  testWidgets('default icon color is ink token', (tester) async {
    Color? ink;
    await tester.pumpWidget(
      _harness(
        Builder(builder: (context) {
          ink = context.colors.ink;
          return IconButton36(
            icon: Icons.close,
            tooltip: 'Close',
            onPressed: () {},
          );
        }),
      ),
    );

    final iconWidget = tester.widget<Icon>(find.byIcon(Icons.close));
    expect(iconWidget.color, equals(ink));
    expect(ink, equals(AppColors.light.ink));
  });
}
