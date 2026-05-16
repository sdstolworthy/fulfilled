import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../routing/routes.dart';

/// Opens the full-screen barcode scanner route.
///
/// **Mobile (iOS / Android, native only):** pushes [Routes.foodScanPath].
/// On a successful detection the `ScanScreen` pops with the decoded value
/// as the result; this function then pushes `/foods/barcode/$decoded` so
/// the existing `_BarcodeResolveScreen` handles the 200 / 404 / error
/// split.
///
/// **Web (any width — desktop or mobile-web Safari):** no-op. PM §7 rules
/// camera-on-web out of v1 and the affordance is already hidden on web by
/// [BarcodeScanButton]; this guard is defence in depth so a future caller
/// can't accidentally open the route on web.
///
/// See `specs/architect_barcode.md` §3.2 and `specs/pm_barcode.md` §6/§7
/// for the design contract.
Future<void> openBarcodeScanner(BuildContext context) async {
  if (kIsWeb) return;
  final code = await context.push<String>(Routes.foodScanPath);
  if (code == null || code.isEmpty) return;
  if (!context.mounted) return;
  await context.push('/foods/barcode/$code');
}

/// Lower-level seam: opens the scanner route and returns the decoded
/// barcode (or `null` on user dismiss / web). Callers that want the raw
/// value without the resolver push — e.g. a custom-food form that captures
/// the barcode into a draft field — call this directly.
///
/// Mirrors [openBarcodeScanner]'s `kIsWeb` short-circuit (defence in
/// depth). See `specs/architect_barcode.md` §3.3.
Future<String?> scanBarcode(BuildContext context) async {
  if (kIsWeb) return null;
  return context.push<String>(Routes.foodScanPath);
}
