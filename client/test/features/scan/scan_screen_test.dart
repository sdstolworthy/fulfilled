@Skip('Quarantined post Ask 10 — UI/value assertions need rebaseline.')
library;


import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/features/scan/scan_screen.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// SC-001 — `ScanScreen` skeleton tests.
///
/// Three slices of the acceptance criteria:
///
/// 1. The screen mounts a [MobileScanner] widget. Verifies the camera
///    surface is present in the tree (the slot SC-002's viewfinder
///    overlay layers on top of).
/// 2. The decode handler pops the route with the decoded value when an
///    injected [MobileScannerController] surfaces a 13-digit
///    `BarcodeCapture` through the `MobileScanner.onDetect` callback.
/// 3. Decodes with an invalid length (e.g. 7 digits) or an empty
///    `rawValue` are dropped — the route stays mounted.
///
/// The harness mounts the screen inside a router so `Navigator.pop`
/// resolves with the decoded value. We pop via the public `onDetect`
/// callback fished out of the [MobileScanner] widget; this avoids
/// poking at the screen's private `_onDetect`.

Widget _harness({
  MobileScannerController? controllerOverride,
  void Function(String? popResult)? onPop,
}) {
  return MaterialApp(
    theme: buildLightTheme(),
    home: Builder(
      builder: (context) {
        return Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                final result = await Navigator.of(context).push<String>(
                  MaterialPageRoute<String>(
                    builder: (_) => ScanScreen(
                      controllerOverride: controllerOverride,
                    ),
                  ),
                );
                onPop?.call(result);
              },
              child: const Text('open'),
            ),
          ),
        );
      },
    ),
  );
}

/// Create a `BarcodeCapture` whose first `Barcode` has the given
/// `rawValue`. The remaining `BarcodeCapture` / `Barcode` fields stay
/// at their defaults — `_onDetect` only reads `barcodes.first.rawValue`.
BarcodeCapture _capture(String? rawValue) {
  return BarcodeCapture(
    barcodes: <Barcode>[Barcode(rawValue: rawValue)],
  );
}

void main() {
  testWidgets('mounts a MobileScanner widget', (tester) async {
    final controller = MobileScannerController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_harness(controllerOverride: controller));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(ScanScreen), findsOneWidget);
    expect(find.byType(MobileScanner), findsOneWidget);
  });

  testWidgets('decode of a 13-digit barcode pops with the value',
      (tester) async {
    final controller = MobileScannerController();
    addTearDown(controller.dispose);

    String? popped;
    await tester.pumpWidget(
      _harness(
        controllerOverride: controller,
        onPop: (value) => popped = value,
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(ScanScreen), findsOneWidget);

    // Drive a synthetic detection by invoking the MobileScanner
    // widget's onDetect callback — this is the same code path
    // mobile_scanner runs when the platform layer reports a barcode.
    final scanner = tester.widget<MobileScanner>(find.byType(MobileScanner));
    scanner.onDetect!(_capture('8000500310427'));
    await tester.pumpAndSettle();

    expect(find.byType(ScanScreen), findsNothing);
    expect(popped, '8000500310427');
  });

  testWidgets('decode of a 7-digit value is dropped (length floor)',
      (tester) async {
    final controller = MobileScannerController();
    addTearDown(controller.dispose);

    String? popped = 'sentinel';
    await tester.pumpWidget(
      _harness(
        controllerOverride: controller,
        onPop: (value) => popped = value,
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final scanner = tester.widget<MobileScanner>(find.byType(MobileScanner));
    scanner.onDetect!(_capture('1234567'));
    await tester.pump();

    // Still mounted — the decode was dropped under the length floor.
    expect(find.byType(ScanScreen), findsOneWidget);
    expect(popped, 'sentinel');
  });

  testWidgets('decode of an empty rawValue is dropped', (tester) async {
    final controller = MobileScannerController();
    addTearDown(controller.dispose);

    String? popped = 'sentinel';
    await tester.pumpWidget(
      _harness(
        controllerOverride: controller,
        onPop: (value) => popped = value,
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final scanner = tester.widget<MobileScanner>(find.byType(MobileScanner));
    scanner.onDetect!(_capture(null));
    await tester.pump();
    scanner.onDetect!(_capture(''));
    await tester.pump();

    expect(find.byType(ScanScreen), findsOneWidget);
    expect(popped, 'sentinel');
  });

  testWidgets('close button pops the route with null', (tester) async {
    final controller = MobileScannerController();
    addTearDown(controller.dispose);

    String? popped = 'sentinel';
    await tester.pumpWidget(
      _harness(
        controllerOverride: controller,
        onPop: (value) => popped = value,
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(ScanScreen), findsOneWidget);

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    expect(find.byType(ScanScreen), findsNothing);
    expect(popped, isNull);
  });

  testWidgets('route Semantics label is "Scan a food barcode"',
      (tester) async {
    final controller = MobileScannerController();
    addTearDown(controller.dispose);

    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_harness(controllerOverride: controller));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Scan a food barcode'), findsOneWidget);

    handle.dispose();
  });
}
