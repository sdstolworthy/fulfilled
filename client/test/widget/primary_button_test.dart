import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/theme/context_extensions.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/theme/tokens.dart';
import 'package:fulfilled/widgets/button_loading_bar.dart';
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

  // QL-106 — `isLoading` used to render a `CircularProgressIndicator`.
  // The four-site sweep replaced every button-level spinner with the
  // lifted `ButtonLoadingBar` (T-08 / T-13: static skeleton, not an
  // indeterminate spinner; `pumpAndSettle()` finishes cleanly).
  testWidgets('isLoading swaps label for ButtonLoadingBar and ignores taps',
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
    expect(find.byType(ButtonLoadingBar), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

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
        },),
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
        },),
      ),
    );

    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    final bg = button.style?.backgroundColor?.resolve(<WidgetState>{});
    expect(bg, equals(danger));
    expect(danger, equals(AppColors.light.danger));
  });

  // SC-005: dense variant. Two cases, per the ticket scope —
  // (a) dense renders with a smaller visible pill than the default
  //     54-px sticky shape, and
  // (b) `onPressed` still fires through the smaller hit area.
  //
  // The dense path renders a 36-px pill inside a 44-px hit-slop
  // wrapper (T-06 floor) — so the outer widget reports 44 px and the
  // inner `FilledButton` reports 36 px. Both numbers are below the
  // 54-px default, satisfying "smaller than default".
  testWidgets('dense renders with smaller height than default',
      (tester) async {
    await tester.pumpWidget(
      _harness(
        SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              PrimaryButton(label: 'Default', onPressed: () {}),
              PrimaryButton(
                label: 'Dense',
                dense: true,
                onPressed: () {},
              ),
            ],
          ),
        ),
      ),
    );

    final buttons = find.byType(PrimaryButton);
    expect(buttons, findsNWidgets(2));
    final defaultOuter = tester.getSize(buttons.at(0));
    final denseOuter = tester.getSize(buttons.at(1));

    // Default's outer widget is the 54-px sticky-CTA SizedBox.
    expect(defaultOuter.height, 54);
    // Dense's outer widget is the 44-px hit-slop SizedBox; T-06 floor.
    expect(denseOuter.height, 44);
    expect(denseOuter.height, lessThan(defaultOuter.height));

    // The visible pill inside the dense wrapper is 36 px — the
    // FilledButton itself, smaller still than the outer hit region.
    final denseFilled = find.descendant(
      of: buttons.at(1),
      matching: find.byType(FilledButton),
    );
    expect(denseFilled, findsOneWidget);
    final densePillSize = tester.getSize(denseFilled);
    expect(densePillSize.height, 36);
  });

  testWidgets('dense still fires onPressed through the smaller hit area',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _harness(
        PrimaryButton(
          label: 'Try again',
          dense: true,
          onPressed: () => taps++,
        ),
      ),
    );

    // Tap the visible pill (inside the 36-px FilledButton); the
    // surrounding 44-px InkResponse slop is still the gesture floor
    // per T-06, but the pill itself is what users hit-test first.
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(taps, 1);
  });
}
