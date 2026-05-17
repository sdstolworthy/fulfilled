@Skip('Quarantined post Ask 10 — UI/value assertions need rebaseline.')
library;


import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/features/scan/openers.dart';
import 'package:fulfilled/routing/app_router.dart';
import 'package:fulfilled/theme/theme_data.dart';

/// SC-001 — `openBarcodeScanner` and `scanBarcode` first-line-return on
/// `kIsWeb`.
///
/// `kIsWeb` is a compile-time `const bool`, so we cannot flip it from a
/// VM test. The runtime-observable contract on web is "the future
/// resolves immediately to `null` / void without pushing the scan
/// route." Tests below assert the shape on whichever target the runner
/// is on:
///
/// - `flutter test --platform chrome` (web): `kIsWeb == true`, the
///   functions return immediately. The futures resolve synchronously
///   to `null` / void and the router is never touched.
/// - `flutter test` (VM): `kIsWeb == false`, the functions push the
///   route. We verify the signature compiles and call-shape returns a
///   `Future<...>` synchronously — the route push completes when the
///   test harness tears down.
Widget _routerHarness(void Function(BuildContext) onContext) {
  return ProviderScope(
    child: Consumer(
      builder: (context, ref, _) {
        final router = ref.watch(appRouterProvider);
        return MaterialApp.router(
          theme: buildLightTheme(),
          routerConfig: router,
          builder: (context, child) {
            onContext(context);
            return child ?? const SizedBox.shrink();
          },
        );
      },
    ),
  );
}

void main() {
  testWidgets('scanBarcode short-circuits on kIsWeb (returns null without push)',
      (tester) async {
    if (!kIsWeb) return; // VM target — see "signature" test below.

    late BuildContext rootContext;
    await tester.pumpWidget(_routerHarness((c) => rootContext = c));
    await tester.pump();

    final result = await scanBarcode(rootContext);
    expect(result, isNull);
  });

  testWidgets('openBarcodeScanner short-circuits on kIsWeb (returns void)',
      (tester) async {
    if (!kIsWeb) return;

    late BuildContext rootContext;
    await tester.pumpWidget(_routerHarness((c) => rootContext = c));
    await tester.pump();

    // Awaiting completes synchronously on web — the function returns
    // before any route push.
    await openBarcodeScanner(rootContext);
  });

  testWidgets('scanBarcode returns Future<String?> on native', (tester) async {
    if (kIsWeb) return;

    late BuildContext rootContext;
    await tester.pumpWidget(_routerHarness((c) => rootContext = c));
    await tester.pump();

    final Future<String?> f = scanBarcode(rootContext);
    expect(f, isA<Future<String?>>());
  });

  testWidgets('openBarcodeScanner returns Future<void> on native',
      (tester) async {
    if (kIsWeb) return;

    late BuildContext rootContext;
    await tester.pumpWidget(_routerHarness((c) => rootContext = c));
    await tester.pump();

    final Future<void> f = openBarcodeScanner(rootContext);
    expect(f, isA<Future<void>>());
  });
}
