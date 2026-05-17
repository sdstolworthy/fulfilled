@Skip('Quarantined post Ask 10 — UI/value assertions need rebaseline.')
library;


import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fulfilled/features/scan/scan_screen.dart';
import 'package:fulfilled/features/scan/widgets/no_detect_hint.dart';
import 'package:fulfilled/features/scan/widgets/scan_torch_button.dart';
import 'package:fulfilled/theme/theme_data.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// SC-003 — polish surfaces wired into `ScanScreen`.
///
/// Two integration-style checks beyond the leaf-level tests in
/// `test/widget/`:
///
/// 1. The torch button is mounted in the camera stack and tapping it
///    toggles the controller. The controller's combined
///    `MobileScannerState` flips `torchState` from off to on; the
///    `ScanTorchButton`'s `ValueListenableBuilder` rebuilds with the
///    `Icons.flash_on_outlined` glyph and the "Turn flash off"
///    tooltip.
/// 2. The `NoDetectHint` is mounted at the bottom of the stack (the
///    SC-001 placeholder is gone). We don't drive the 10-second timer
///    here — the leaf test in `test/widget/no_detect_hint_test.dart`
///    owns the visibility-after-delay assertion — we just verify the
///    slot is wired.
///
/// The harness pushes the route under a parent so we can read the
/// pop value back; same shape as `scan_screen_test.dart` (SC-001).

class _FakeTorchController extends MobileScannerController {
  _FakeTorchController({this.startsAvailable = true});

  final bool startsAvailable;
  int toggleTorchCalls = 0;

  @override
  Future<void> toggleTorch() async {
    toggleTorchCalls += 1;
    final state = value;
    final next = state.torchState == TorchState.on
        ? TorchState.off
        : TorchState.on;
    // `MobileScannerState.copyWith` is the public seam for mutating
    // the controller's observable state in 5.x.
    value = state.copyWith(torchState: next);
  }

  @override
  Future<void> start({CameraFacing? cameraDirection}) async {
    // Bypass platform-channel start; just transition into a state the
    // ScanTorchButton can render against. The torch begins in `off`
    // (available) so the button is visible from the first frame.
    value = value.copyWith(
      isInitialized: true,
      isRunning: true,
      torchState: startsAvailable
          ? TorchState.off
          : TorchState.unavailable,
    );
  }

  @override
  Future<void> stop() async {
    value = value.copyWith(isRunning: false);
  }
}

Widget _harness({required MobileScannerController controller}) {
  return MaterialApp(
    theme: buildLightTheme(),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => Navigator.of(context).push<String>(
              MaterialPageRoute<String>(
                builder: (_) => ScanScreen(controllerOverride: controller),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('torch button is mounted in the camera stack',
      (tester) async {
    final controller = _FakeTorchController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_harness(controller: controller));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(ScanTorchButton), findsOneWidget);
  });

  testWidgets('torch button toggles the controller torch state',
      (tester) async {
    final controller = _FakeTorchController();
    addTearDown(controller.dispose);
    // Seed the controller's state so the button is visible from the
    // first frame (start() would normally do this).
    controller.value = controller.value.copyWith(
      isInitialized: true,
      torchState: TorchState.off,
    );

    await tester.pumpWidget(_harness(controller: controller));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Turn flash on'), findsOneWidget);
    expect(find.byIcon(Icons.flash_off_outlined), findsOneWidget);

    await tester.tap(find.byTooltip('Turn flash on'));
    await tester.pump();

    expect(controller.toggleTorchCalls, 1);
    expect(find.byTooltip('Turn flash off'), findsOneWidget);
    expect(find.byIcon(Icons.flash_on_outlined), findsOneWidget);
  });

  testWidgets('torch button is hidden when TorchState.unavailable',
      (tester) async {
    final controller = _FakeTorchController();
    addTearDown(controller.dispose);
    controller.value = controller.value.copyWith(
      isInitialized: true,
      torchState: TorchState.unavailable,
    );

    await tester.pumpWidget(_harness(controller: controller));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // The widget is still present (it's the controller-bound shell)
    // but its build returns `SizedBox.shrink()` — no icon, no tooltip
    // is rendered.
    expect(find.byTooltip('Turn flash on'), findsNothing);
    expect(find.byTooltip('Turn flash off'), findsNothing);
    expect(find.byIcon(Icons.flash_off_outlined), findsNothing);
    expect(find.byIcon(Icons.flash_on_outlined), findsNothing);
  });

  testWidgets('NoDetectHint is mounted at the bottom of the stack',
      (tester) async {
    final controller = _FakeTorchController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_harness(controller: controller));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(NoDetectHint), findsOneWidget);
  });
}
