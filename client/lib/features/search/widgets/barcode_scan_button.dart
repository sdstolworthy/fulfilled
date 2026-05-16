import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../form_factor/form_factor.dart';
import '../../../theme/context_extensions.dart';

/// 44 × 44 square barcode icon button that sits next to the search field
/// on screen 02 (and the custom-food barcode field on screen 05).
///
/// Behavior matches §7 "No barcode UI on web" + `pm_decisions_flutter_ui.md`:
/// returns `SizedBox.shrink()` on desktop web (`FormFactor.isWeb &&
/// !isCompact`). Web users paste a barcode into the search field instead
/// (8–14 all-digit input routes via `/foods/barcode/:code`; that detection
/// lives in `SearchScreen`, not here).
///
/// On compact (phone or narrow web) the button is visible. Tapping it
/// invokes [onScan] which receives the detected barcode string. For now
/// the actual `mobile_scanner` integration is out of scope for this
/// screen agent — see the `TODO(scan)` below. The screen wires
/// `onScan` to push `/foods/barcode/:code`.
class BarcodeScanButton extends StatelessWidget {
  const BarcodeScanButton({required this.onScan, super.key});

  /// Called with the scanned barcode string on a successful detection.
  /// Stubbed for now — see the TODO inside [build].
  final ValueChanged<String> onScan;

  @override
  Widget build(BuildContext context) {
    final formFactor = FormFactor.of(context);
    // Desktop web: hidden entirely. Mobile (any width) and mobile-web
    // (compact width) keep the button.
    if (FormFactor.isWeb && !formFactor.isCompact) {
      return const SizedBox.shrink();
    }
    return Semantics(
      button: true,
      label: 'Scan barcode',
      child: Tooltip(
        message: 'Scan barcode',
        child: InkResponse(
          onTap: () async {
            // TODO(scan): wire `mobile_scanner` here — open a full-screen
            // scanner route, on detection call HapticFeedback.lightImpact()
            // and invoke onScan(code). Architecture §6 "Barcode scanning"
            // describes the flow; we keep the UI button in place so
            // routing / haptics / repository wiring lands without a
            // dependency on the camera package in this PR.
            await HapticFeedback.selectionClick();
          },
          containedInkWell: true,
          radius: 24,
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: context.colors.surface,
              border: Border.all(color: context.colors.line),
              borderRadius: BorderRadius.circular(context.radius.r3),
            ),
            child: Icon(
              Icons.qr_code_scanner,
              size: 22,
              color: context.colors.accent,
            ),
          ),
        ),
      ),
    );
  }
}
