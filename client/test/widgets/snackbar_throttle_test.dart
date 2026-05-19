// UX-112 Theme E — per-screen 3-second cooldown helper.
//
// `SnackbarThrottle.show(context, snackBar, key: ...)` swallows
// same-(context, key) calls within 3 seconds. The cooldown is the
// PM-modified Theme E ship (PM UX pack §3 — global debounced SnackBar
// is deferred to v1.1; this pack ships an opt-in per-screen helper).
//
// Acceptance:
// 1. Stacked same-key calls within 3 s render only one SnackBar.
// 2. Same-key calls beyond the cooldown render two SnackBars.
// 3. Different keys are independent — both render even within the
//    cooldown window.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/widgets/snackbar_throttle.dart';

Widget _harness({required Widget child}) {
  return MaterialApp(home: Scaffold(body: child));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SnackbarThrottle.resetForTest();
  });

  testWidgets('stacked same-key calls within 3s are swallowed',
      (tester) async {
    BuildContext? captured;
    await tester.pumpWidget(_harness(
      child: Builder(
        builder: (ctx) {
          captured = ctx;
          return const SizedBox.shrink();
        },
      ),
    ),);

    final ctx = captured!;
    final t0 = DateTime(2026, 5, 16, 12, 0, 0);

    final firstShown = SnackbarThrottle.show(
      ctx,
      const SnackBar(content: Text('Boom — first')),
      key: 'log-create-failure',
      now: t0,
    );
    final secondShown = SnackbarThrottle.show(
      ctx,
      const SnackBar(content: Text('Boom — second')),
      key: 'log-create-failure',
      now: t0.add(const Duration(milliseconds: 100)),
    );

    expect(firstShown, isTrue, reason: 'first call should show');
    expect(secondShown, isFalse,
        reason: 'second call within 3 s should be swallowed',);

    await tester.pump();
    // Only the first SnackBar's content text renders. The second
    // SnackBar never entered the messenger, so its "second" content
    // is absent from the tree.
    expect(find.text('Boom — first'), findsOneWidget);
    expect(find.text('Boom — second'), findsNothing);
  });

  testWidgets('same-key calls beyond the cooldown render again',
      (tester) async {
    BuildContext? captured;
    await tester.pumpWidget(_harness(
      child: Builder(
        builder: (ctx) {
          captured = ctx;
          return const SizedBox.shrink();
        },
      ),
    ),);
    final ctx = captured!;
    final t0 = DateTime(2026, 5, 16, 12, 0, 0);

    final firstShown = SnackbarThrottle.show(
      ctx,
      const SnackBar(content: Text('Boom 1')),
      key: 'log-create-failure',
      now: t0,
    );
    // 4 s later — cooldown elapsed.
    final secondShown = SnackbarThrottle.show(
      ctx,
      const SnackBar(content: Text('Boom 2')),
      key: 'log-create-failure',
      now: t0.add(const Duration(seconds: 4)),
    );

    expect(firstShown, isTrue);
    expect(secondShown, isTrue,
        reason: 'second call after 3 s cooldown should render',);
  });

  testWidgets('different keys render independently within the cooldown',
      (tester) async {
    BuildContext? captured;
    await tester.pumpWidget(_harness(
      child: Builder(
        builder: (ctx) {
          captured = ctx;
          return const SizedBox.shrink();
        },
      ),
    ),);
    final ctx = captured!;
    final t0 = DateTime(2026, 5, 16, 12, 0, 0);

    final firstShown = SnackbarThrottle.show(
      ctx,
      const SnackBar(content: Text('Network failure')),
      key: 'network-failure',
      now: t0,
    );
    // Different key — should not be swallowed even within 100 ms.
    final secondShown = SnackbarThrottle.show(
      ctx,
      const SnackBar(content: Text('Auth failure')),
      key: 'auth-failure',
      now: t0.add(const Duration(milliseconds: 100)),
    );

    expect(firstShown, isTrue);
    expect(secondShown, isTrue,
        reason: 'a different key bypasses the cooldown',);
  });
}
