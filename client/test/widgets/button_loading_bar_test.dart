import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/button_loading_bar.dart';
import 'package:fulfilled/widgets/primary_button.dart';

/// QL-106 — `ButtonLoadingBar` primitive + integration with
/// `PrimaryButton`.
///
/// Acceptance:
/// 1. The bar renders at its pinned 96 × 12 px size — the lift from
///    `_SaveButtonSkeleton` is pixel-equivalent.
/// 2. The bar exposes a Semantics label hinting at loading ("Saving")
///    so screen-reader users hear the right phrase when a save flow
///    flips the button into its loading state (T-20).
/// 3. `PrimaryButton(isLoading: true)` renders one `ButtonLoadingBar`
///    in place of the label, and **no** `CircularProgressIndicator`
///    (T-08 / T-13 — static skeleton, never a spinner).

Widget _harness(Widget child) {
  return MaterialApp(
    theme: buildLightTheme(),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders at 96 × 12 px', (tester) async {
    await tester.pumpWidget(_harness(const ButtonLoadingBar()));

    final size = tester.getSize(find.byType(ButtonLoadingBar));
    expect(size.width, ButtonLoadingBar.width);
    expect(size.height, ButtonLoadingBar.height);
    // Lock the lift's pixel contract — the visual must match the
    // original `_SaveButtonSkeleton` byte-for-byte.
    expect(ButtonLoadingBar.width, 96);
    expect(ButtonLoadingBar.height, 12);
  });

  testWidgets('exposes a Semantics label hinting at loading',
      (tester) async {
    await tester.pumpWidget(_harness(const ButtonLoadingBar()));

    // The widget wraps a Semantics(label: 'Saving') node. Find it via
    // the semantic finder so screen-reader users get the right phrase.
    expect(find.bySemanticsLabel('Saving'), findsOneWidget);
  });

  testWidgets('PrimaryButton(isLoading: true) renders ButtonLoadingBar',
      (tester) async {
    await tester.pumpWidget(
      _harness(
        PrimaryButton(
          label: 'Save to log',
          isLoading: true,
          onPressed: () {},
        ),
      ),
    );

    // The label is replaced by the bar, and no `CircularProgressIndicator`
    // exists anywhere in the tree (regression guard for the T-08 sweep —
    // QL-106's whole point is that the four button-level sites no
    // longer flash an indeterminate spinner).
    expect(find.text('Save to log'), findsNothing);
    expect(find.byType(ButtonLoadingBar), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('PrimaryButton(isLoading: false) renders the label',
      (tester) async {
    await tester.pumpWidget(
      _harness(
        PrimaryButton(
          label: 'Save to log',
          onPressed: () {},
        ),
      ),
    );

    expect(find.text('Save to log'), findsOneWidget);
    expect(find.byType(ButtonLoadingBar), findsNothing);
  });
}
