import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../theme/context_extensions.dart';
import '../../../widgets/icon_button_36.dart';

/// Torch toggle for the scanner route — SC-003.
///
/// Architect §3.8: a feature-private control that wraps an
/// [IconButton36] and binds it to the [MobileScannerController]'s
/// observable state. The button:
///
/// 1. Reads the controller's combined [MobileScannerState] via a
///    `ValueListenableBuilder` (the controller itself extends
///    `ValueNotifier<MobileScannerState>` in `mobile_scanner` 5.x), so
///    the icon and tooltip flip the instant the platform layer reports
///    a new torch state.
/// 2. Hides itself with `SizedBox.shrink()` when the device reports
///    `TorchState.unavailable` (no hardware flashlight). PM §9: "the
///    button is hidden, not greyed" on cameraless / torchless devices.
/// 3. Toggles via `MobileScannerController.toggleTorch()` on tap. The
///    controller mutates its own state and the builder re-runs.
/// 4. Layers a translucent-`surface` circular backdrop behind the icon
///    so the white glyph is legible over arbitrary camera content
///    (architect §3.8, "Color over camera").
///
/// **Tenants honored**:
/// - **T-01** — no raw hex; opacity sits on a token (`colors.surface`),
///   matching the `MacroBar.line2` opacity pattern.
/// - **T-06** — `IconButton36` already enforces the 44-px hit slop; the
///   18 %-opacity backdrop is purely visual and does not change the
///   gesture target.
/// - **T-20** — the wrapper is a `Semantics(label: 'Camera light',
///   toggled: on)` so VoiceOver / TalkBack announces the on/off state
///   instead of just "button".
class ScanTorchButton extends StatelessWidget {
  /// Construct a torch button bound to the given [controller]. The
  /// controller's lifecycle is owned by the parent `ScanScreen` — this
  /// widget never calls `start()` or `dispose()`.
  const ScanTorchButton({super.key, required this.controller});

  /// The active scanner controller. Its `value` is a
  /// [MobileScannerState] holding the `torchState` field that drives
  /// the icon swap.
  final MobileScannerController controller;

  /// Backdrop opacity behind the icon. 18 % of `surface` reads as a
  /// glassy disc on most camera content — enough contrast for the
  /// white icon, not so much that the camera feels obscured.
  static const double _backdropOpacity = 0.18;

  /// Diameter of the translucent backdrop disc; matches the
  /// `IconButton36` visible footprint plus a small halo so the icon is
  /// centred on a generous circle.
  static const double _backdropDiameter = 36;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = context.radius;
    return ValueListenableBuilder<MobileScannerState>(
      valueListenable: controller,
      builder: (context, state, _) {
        final torch = state.torchState;
        // Hide on devices without a flashlight (PM §9). The scanner
        // route renders without a torch slot rather than greying one
        // the user can't actuate.
        if (torch == TorchState.unavailable) {
          return const SizedBox.shrink();
        }
        final on = torch == TorchState.on;
        return Semantics(
          label: 'Camera light',
          toggled: on,
          container: true,
          child: Container(
            width: _backdropDiameter,
            height: _backdropDiameter,
            decoration: BoxDecoration(
              color: colors.surface.withValues(alpha: _backdropOpacity),
              borderRadius: BorderRadius.circular(radius.rPill),
            ),
            child: IconButton36(
              icon: on
                  ? Icons.flash_on_outlined
                  : Icons.flash_off_outlined,
              tooltip: on ? 'Turn flash off' : 'Turn flash on',
              // White over the camera dim per the SC-003 spec; the
              // backdrop disc provides the legibility contrast.
              color: colors.surface,
              onPressed: () => unawaited(controller.toggleTorch()),
            ),
          ),
        );
      },
    );
  }
}
