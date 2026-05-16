import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../theme/context_extensions.dart';
import '../../widgets/icon_button_36.dart';
import 'widgets/no_detect_hint.dart';
import 'widgets/permission_denied.dart';
import 'widgets/scan_torch_button.dart';
import 'widgets/viewfinder_overlay.dart';

/// Permission state machine for [ScanScreen]. SC-003 swaps in the
/// user-facing surfaces; SC-001 ships placeholders.
enum _PermissionState { unknown, granted, denied }

/// Full-screen barcode scanner route at [Routes.foodScanPath].
///
/// Hosts a `mobile_scanner` [MobileScanner] widget configured to a
/// four-format whitelist (EAN-13, UPC-A, EAN-8, UPC-E) per
/// `specs/pm_barcode.md` §5 and `specs/architect_barcode.md` §3.5. On a
/// successful decode the controller is stopped, a haptic fires, and the
/// route pops with the decoded string. The caller — `openBarcodeScanner`
/// — then pushes `/foods/barcode/$code` so the existing resolver handles
/// the 200 / 404 / error split.
///
/// SC-001 ships the skeleton: the [MobileScanner] widget, the controller
/// lifecycle, `_onDetect`, the permission state machine, the close
/// button, and explicit placeholder slots in the [Stack] for SC-002's
/// viewfinder overlay and SC-003's torch + no-detect hint +
/// permission-denied surfaces.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key, this.controllerOverride});

  /// Test-only seam — production leaves this null and the screen
  /// constructs its own [MobileScannerController]. Widget tests inject
  /// a fake to drive `_onDetect` without touching real platform
  /// channels. Same pattern as `showLogEntrySheetOverride` on
  /// `FoodDetailScreen`.
  final MobileScannerController? controllerOverride;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen>
    with WidgetsBindingObserver {
  late final MobileScannerController _controller;
  bool _detected = false;
  _PermissionState _permission = _PermissionState.unknown;
  // The controller is feature-private (constructed locally) unless the
  // test seam wins. Only dispose it on dispose() if we constructed it
  // ourselves, otherwise tests that share controllers across pumps would
  // double-dispose.
  bool _ownsController = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final override = widget.controllerOverride;
    if (override != null) {
      _controller = override;
      _ownsController = false;
    } else {
      _controller = MobileScannerController(
        formats: const <BarcodeFormat>[
          BarcodeFormat.ean13,
          BarcodeFormat.upcA,
          BarcodeFormat.ean8,
          BarcodeFormat.upcE,
        ],
        detectionSpeed: DetectionSpeed.noDuplicates,
        detectionTimeoutMs: 250,
        returnImage: false,
        torchEnabled: false,
      );
      _ownsController = true;
    }
    // Defer the start so the widget is mounted before any error surface
    // wants to setState.
    WidgetsBinding.instance.addPostFrameCallback((_) => _attemptStart());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      // The OS may have changed the camera permission while we were
      // backgrounded; re-attempt the start so the camera resumes
      // silently when the user enabled access in Settings. SC-003's
      // permission-denied surface delegates to this same path via its
      // "Try again" button.
      _attemptStart();
    }
  }

  Future<void> _attemptStart() async {
    if (!mounted) return;
    try {
      await _controller.start();
      if (!mounted) return;
      setState(() => _permission = _PermissionState.granted);
    } on MobileScannerException catch (err) {
      if (!mounted) return;
      // Treat both `permissionDenied` and `permissionDeniedDuringSession`
      // (when the enum surfaces it) as denied; same rendering path. The
      // exception's `errorCode` enum varies slightly across plugin
      // versions, so we name-match the toString as a fallback per the
      // ticket's gotcha note.
      final code = err.errorCode.toString();
      if (code.contains('permissionDenied') ||
          code.contains('permissionDeniedDuringSession')) {
        setState(() => _permission = _PermissionState.denied);
      }
    } catch (_) {
      // Other errors (camera busy, plugin init failure) leave the
      // permission state at `unknown` — SC-003 will widen the surface
      // if needed. SC-001 keeps the skeleton minimal.
    }
  }

  /// Decode handler. Architect §3.6:
  /// latch check → empty-list guard → rawValue extraction → length
  /// floor (8..14 digits) → `controller.stop()` →
  /// `HapticFeedback.lightImpact()` → `Navigator.pop(value)`.
  ///
  /// We pop **before** the resolver push so the user's back button from
  /// food detail lands on the search screen, not on a stale camera
  /// frame. The opener (`openBarcodeScanner`) does the resolver push.
  void _onDetect(BarcodeCapture capture) {
    if (_detected) return;
    if (capture.barcodes.isEmpty) return;
    final value = capture.barcodes.first.rawValue;
    if (value == null || value.isEmpty) return;
    if (!_isAcceptableLength(value)) return;
    _detected = true;
    unawaited(_controller.stop());
    unawaited(HapticFeedback.lightImpact());
    if (!mounted) return;
    Navigator.of(context).pop(value);
  }

  /// 8–14-digit floor matches T-021's `^\d{8,14}$` paste path. The
  /// format whitelist already restricts to EAN/UPC (which are
  /// length-bounded by spec) but a malformed decode is cheap to drop
  /// here.
  static bool _isAcceptableLength(String value) {
    final n = value.length;
    if (n < 8 || n > 14) return false;
    for (var i = 0; i < value.length; i++) {
      final c = value.codeUnitAt(i);
      if (c < 0x30 || c > 0x39) return false;
    }
    return true;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final denied = _permission == _PermissionState.denied;
    return Scaffold(
      // When the camera surface is hidden behind a denied state, swap
      // the dark `ink` backdrop for the standard `bg` so the EmptyState
      // reads on a light page rather than over an empty black void.
      backgroundColor:
          denied ? context.colors.bg : context.colors.ink,
      body: Semantics(
        label: 'Scan a food barcode',
        container: true,
        child: denied
            ? const PermissionDenied()
            : _buildCameraStack(context),
      ),
    );
  }

  Widget _buildCameraStack(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // Camera surface. Wrapped in `Semantics(image: true, ...)` so
        // screen readers describe it rather than try to interact with
        // it. T-20.
        Semantics(
          image: true,
          label: 'Camera viewfinder, point at a barcode',
          child: MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
          ),
        ),
        // SC-002 fills this slot with `ViewfinderOverlay`.
        const Positioned.fill(child: ViewfinderOverlay()),
        // Top bar: close (left), torch (right). SC-003 wires the torch.
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 8,
            ),
            child: Row(
              children: <Widget>[
                IconButton36(
                  icon: Icons.close,
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(null),
                  color: context.colors.surface,
                ),
                const Spacer(),
                // SC-003: torch toggle. The button hides itself when
                // the controller reports `TorchState.unavailable`, so
                // we mount it unconditionally and let the leaf decide.
                ScanTorchButton(controller: _controller),
              ],
            ),
          ),
        ),
        // SC-003: 10-second no-detect hint. The widget owns its own
        // timer; we only mount it. `IgnorePointer` inside the leaf
        // means it occupies the bottom of the stack without stealing
        // taps before the band is visible.
        const Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: NoDetectHint(),
        ),
      ],
    );
  }

}
