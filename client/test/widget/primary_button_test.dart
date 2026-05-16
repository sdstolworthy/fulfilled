import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/theme/context_extensions.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/theme/tokens.dart';
import 'package:fulfilled/widgets/primary_button.dart';

/// T-003 — `PrimaryButton` primitive.
///
/// Acceptance criteria:
/// - `onPressed: null` disables the button.
/// - `isLoading: true` shows a spinner (no label text).
/// - `isDestructive: true` uses `colors.danger` background.
/// - Default uses `colors.accent`.
Widget _harness(Widget child) {
  return MaterialApp(
    theme: buildLightTheme(),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  testWidgets('null onPressed disables the button', (tester) async {
    await tester.pumpWidget(
      _harness(
        const PrimaryButton(label: 'Save to log', onPressed: null),
      ),
    );

    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
    expect(button.enabled, isFalse);
  });

  testWidgets('tap invokes onPressed when enabled', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _harness(
        PrimaryButton(
          label: 'Save to log',
          onPressed: () => taps++,
        ),
      ),
    );

    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('isLoading swaps label for spinner and ignores taps',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _harness(
        PrimaryButton(
          label: 'Save to log',
          isLoading: true,
          onPressed: () => taps++,
        ),
      ),
    );

    expect(find.text('Save to log'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    expect(taps, 0);
  });

  testWidgets('default background is accent token', (tester) async {
    Color? accent;
    await tester.pumpWidget(
      _harness(
        Builder(builder: (context) {
          accent = context.colors.accent;
          return PrimaryButton(label: 'Save', onPressed: () {});
        }),
      ),
    );

    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    final bg = button.style?.backgroundColor?.resolve(<WidgetState>{});
    expect(bg, equals(accent));
    expect(accent, equals(AppColors.light.accent));
  });

  testWidgets('isDestructive uses danger token', (tester) async {
    Color? danger;
    await tester.pumpWidget(
      _harness(
        Builder(builder: (context) {
          danger = context.colors.danger;
          return PrimaryButton(
            label: 'Sign out',
            isDestructive: true,
            onPressed: () {},
          );
        }),
      ),
    );

    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    final bg = button.style?.backgroundColor?.resolve(<WidgetState>{});
    expect(bg, equals(danger));
    expect(danger, equals(AppColors.light.danger));
  });
}
