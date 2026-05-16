import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/features/scan/widgets/no_detect_hint.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:fulfilled/widgets/primary_button.dart';

/// SC-003 — `NoDetectHint`.
///
/// Behaviour under test (acceptance criteria from the SC-003 ticket):
///
/// 1. The hint is **not** visible before its `delay` elapses. Visible
///    here means `Opacity == 1.0` on the band's `AnimatedOpacity` — the
///    widget is in the tree at all times but the band reads as hidden
///    until the timer fires.
/// 2. After the `delay` elapses, the band fades in: the next pump
///    rebuilds with `_visible = true` and the `AnimatedOpacity` starts
///    its 220 ms tween. By the end of the 220 ms tween the opacity is
///    1.0.
/// 3. The band carries the documented copy ("Trouble scanning?") and
///    renders two dense `PrimaryButton`s ("Type the barcode" / "Add a
///    custom food").
/// 4. The `resetSignal` listenable, when fired, hides the band again
///    and re-arms a fresh `delay` countdown.
///
/// The widget uses an internal `Timer`, so we drive time with
/// `tester.pump(Duration(...))`. A custom shorter `delay` keeps the
/// tests fast (100 ms instead of the 10-second production value) while
/// exercising the same code path.

Widget _harness({Listenable? resetSignal, Duration? delay}) {
  return MaterialApp(
    theme: buildLightTheme(),
    home: Scaffold(
      // Pin to the bottom so the band has a stable layout slot, as it
      // does in the scanner route.
      body: Stack(
        children: <Widget>[
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: NoDetectHint(
              resetSignal: resetSignal,
              delay: delay ?? const Duration(milliseconds: 100),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Pull the band's `AnimatedOpacity` and return its current target.
double _bandOpacity(WidgetTester tester) {
  final opacity = tester.widget<AnimatedOpacity>(
    find.byType(AnimatedOpacity),
  );
  return opacity.opacity;
}

void main() {
  testWidgets('not visible before the delay elapses', (tester) async {
    await tester.pumpWidget(_harness());

    // Initial frame — band is mounted but the AnimatedOpacity's target
    // is 0.0. The two PrimaryButtons render (they're in the tree, just
    // invisible and `IgnorePointer`-gated).
    expect(find.text('Trouble scanning?'), findsOneWidget);
    expect(_bandOpacity(tester), 0.0);

    // Half-way through the delay — still hidden.
    await tester.pump(const Duration(milliseconds: 50));
    expect(_bandOpacity(tester), 0.0);
  });

  testWidgets('fades in after the delay', (tester) async {
    await tester.pumpWidget(_harness());

    // Advance just past the 100 ms delay; the setState fires and the
    // band's AnimatedOpacity target flips to 1.0. The opacity tween
    // itself takes another 220 ms; pump through it.
    await tester.pump(const Duration(milliseconds: 101));
    expect(_bandOpacity(tester), 1.0);

    // Run the opacity animation to completion; nothing should error.
    await tester.pump(const Duration(milliseconds: 220));
    expect(_bandOpacity(tester), 1.0);
  });

  testWidgets('renders the documented copy and two dense PrimaryButtons',
      (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pump(const Duration(milliseconds: 101));
    await tester.pump(const Duration(milliseconds: 220));

    expect(find.text('Trouble scanning?'), findsOneWidget);
    expect(
      find.text('Try a different angle, or use one of these.'),
      findsOneWidget,
    );
    expect(find.text('Type the barcode'), findsOneWidget);
    expect(find.text('Add a custom food'), findsOneWidget);

    // Both CTAs are PrimaryButton(dense: true).
    final buttons = tester.widgetList<PrimaryButton>(
      find.byType(PrimaryButton),
    );
    expect(buttons.length, 2);
    for (final b in buttons) {
      expect(b.dense, isTrue, reason: 'hint CTAs must be dense (SC-005)');
    }
  });

  testWidgets('resetSignal hides the band and re-arms the timer',
      (tester) async {
    final reset = ChangeNotifier();
    addTearDown(reset.dispose);

    await tester.pumpWidget(_harness(resetSignal: reset));

    // Show it.
    await tester.pump(const Duration(milliseconds: 101));
    await tester.pump(const Duration(milliseconds: 220));
    expect(_bandOpacity(tester), 1.0);

    // Fire the host signal — the band hides and a fresh countdown
    // arms.
    reset.notifyListeners();
    await tester.pump();
    expect(_bandOpacity(tester), 0.0);

    // The new timer hasn't fired yet.
    await tester.pump(const Duration(milliseconds: 50));
    expect(_bandOpacity(tester), 0.0);

    // After the fresh delay, it reappears.
    await tester.pump(const Duration(milliseconds: 60));
    expect(_bandOpacity(tester), 1.0);
  });

  // Regression guard for the dispose path: tearing the widget down
  // before its timer fires must not throw "setState after dispose".
  // tester.pumpWidget(SizedBox.shrink()) replaces the host so the
  // NoDetectHint is unmounted; we then advance past the original
  // delay. If the timer were still live and tried to setState, the
  // framework would assert.
  testWidgets('cancels the timer on dispose (no setState after dispose)',
      (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pumpWidget(
      MaterialApp(theme: buildLightTheme(), home: const SizedBox.shrink()),
    );
    await tester.pump(const Duration(milliseconds: 200));
    // No assertion failure means the timer was properly cancelled.
    expect(find.byType(NoDetectHint), findsNothing);
  });
}
