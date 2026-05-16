import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../../theme/context_extensions.dart';
import '../../scan/openers.dart';

/// 44 × 44 square barcode icon button that sits next to the search field
/// on screen 02 (and the custom-food barcode field on screen 05).
///
/// Hidden on **all** web (mobile-web Safari included): `mobile_scanner`
/// has no web implementation we want to ship, and the search-field
/// paste-a-barcode path (T-021) is the canonical web entry. See
/// `specs/pm_barcode.md` §7 for the BarcodeDetector / zxing-js analysis
/// and `specs/architect_barcode.md` §4.1 for the resolved hide rule.
///
/// On native mobile (iOS / Android, any width) the button is visible.
/// Tapping invokes [openBarcodeScanner] which pushes the full-screen
/// `ScanScreen` route, awaits the decoded value, and (on a non-null
/// result) pushes `/foods/barcode/$code` so the existing resolver
/// handles 200 / 404 / error.
///
/// **Haptics** are deliberately absent on tap — per `specs/pm_barcode.md`
/// §6, haptics in this feature are a *success* signal and only fire
/// inside `ScanScreen._onDetect`.
class BarcodeScanButton extends StatelessWidget {
  const BarcodeScanButton({super.key, this.onPressedOverride});

  /// Test-only seam — production leaves null and the button calls the
  /// real [openBarcodeScanner]. Matches the `showLogEntrySheetOverride`
  /// pattern on `FoodDetailScreen`. The signature mirrors
  /// [openBarcodeScanner] exactly so the default-or-override line
  /// type-checks cleanly.
  final Future<void> Function(BuildContext)? onPressedOverride;

  @override
  Widget build(BuildContext context) {
    // Hidden on all web (mobile-web Safari included): mobile_scanner has
    // no web implementation we want to ship, and the search-field
    // paste-a-barcode path (T-021) is the canonical web entry. See
    // pm_barcode.md §7 for the BarcodeDetector / zxing-js analysis.
    if (kIsWeb) return const SizedBox.shrink();
    return Semantics(
      button: true,
      label: 'Scan barcode',
      child: Tooltip(
        message: 'Scan barcode',
        child: InkResponse(
          onTap: () async {
            final open = onPressedOverride ?? openBarcodeScanner;
            await open(context);
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
