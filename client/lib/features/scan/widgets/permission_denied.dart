import 'package:flutter/material.dart';

import '../../../widgets/empty_state.dart';
import '../../../widgets/primary_button.dart';

/// Full-screen "camera access is off" surface — SC-003.
///
/// Rendered by `ScanScreen` in place of the `MobileScanner` when
/// `MobileScannerController.start()` surfaces
/// `MobileScannerErrorCode.permissionDenied` (or
/// `permissionDeniedDuringSession`). Per the SC-003 spec and architect
/// §3.9 we ship v1 **without** `permission_handler` / `app_settings`:
/// the body copy walks the user manually through the Settings flow,
/// matching MyFitnessPal's minimal-recovery pattern.
///
/// The single action is "Go back" — pops the scanner route so the user
/// returns to the search screen. The lifecycle resume hook in
/// `ScanScreen` (`didChangeAppLifecycleState(resumed)`) is the path
/// that re-tries the camera if the user actually flipped the toggle in
/// Settings; we do not require a button for that here.
///
/// **Tenants honored**: T-11 (errors inline as an empty state, not a
/// modal dialog), T-01 (every visual sits on a token via [EmptyState]
/// and [PrimaryButton]), T-20 ([EmptyState]'s title and body propagate
/// to the semantics tree by default — see
/// `test/widget/empty_state_test.dart`).
class PermissionDenied extends StatelessWidget {
  const PermissionDenied({super.key});

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.no_photography_outlined,
      title: 'Camera access is off',
      body: 'We need camera access to scan barcodes. '
          'Open Settings → Privacy → Camera → Fulfilled '
          'to turn it on, then come back here.',
      action: SizedBox(
        width: 200,
        child: PrimaryButton(
          label: 'Go back',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }
}
