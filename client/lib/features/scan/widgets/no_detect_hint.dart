import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../routing/routes.dart';
import '../../../theme/context_extensions.dart';
import '../../../widgets/primary_button.dart';

/// "Trouble scanning?" hint band — SC-003.
///
/// Mounts an internal 10-second [Timer] when first inserted into the
/// tree. On fire, the band fades in from invisible to a translucent
/// `surface` card pinned to the bottom of the camera with a short
/// title, a longer subtitle, and two compact `PrimaryButton`s:
///
/// - **Type the barcode** — pops the scanner route, then pushes the
///   search screen so the user can paste the digits into the T-021
///   paste affordance.
/// - **Add a custom food** — pops the scanner, then pushes the
///   custom-food form (with an empty barcode field; the user fills it
///   manually).
///
/// State machine:
///
/// 1. On `initState`, arm `Timer(const Duration(seconds: 10), ...)`.
///    On fire, `setState(() => _visible = true)`.
/// 2. On dispose, cancel the timer (avoids the "called setState after
///    dispose" lint per the SC-003 ticket "gotchas").
/// 3. The optional [resetSignal] lets the host force a timer reset
///    without rebuilding the widget. The host attaches a `Listenable`
///    (typically a `ValueNotifier<bool>` that flips on a successful
///    decode and back on resume); whenever it fires, we cancel the
///    pending timer, hide the band, and re-arm a fresh 10-second
///    countdown. This is the "barcode-detected parent signal" the
///    SC-003 spec named — the architecture leaves the wiring flexible
///    so the parent can choose between a `Listenable` and a callback.
///
/// **Tenants honored**: T-01 (tokens), T-11 (inline hint, not a
/// dialog), T-15 (no platform branch in a leaf), T-20 (the band is a
/// `Semantics(liveRegion: true, container: true)` so VoiceOver
/// announces its appearance the moment the user is most likely stuck).
class NoDetectHint extends StatefulWidget {
  const NoDetectHint({
    super.key,
    this.resetSignal,
    this.delay = const Duration(seconds: 10),
  });

  /// Optional host signal: when this [Listenable] fires, the internal
  /// 10-second timer is cancelled and re-armed. Use case: the host's
  /// `_detected` latch wraps a `ValueNotifier<bool>` whose flips fire
  /// the listener; the band hides during a successful decode and
  /// re-arms if the route is somehow re-entered.
  final Listenable? resetSignal;

  /// Time-to-visible. Defaults to 10 seconds per PM §6; the parameter
  /// exists so widget tests can drive the appearance with
  /// `tester.pump(const Duration(...))` rather than wall-clock waits,
  /// and so the host can experiment with a shorter window without
  /// editing this file.
  final Duration delay;

  @override
  State<NoDetectHint> createState() => _NoDetectHintState();
}

class _NoDetectHintState extends State<NoDetectHint> {
  Timer? _timer;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _armTimer();
    widget.resetSignal?.addListener(_resetTimer);
  }

  @override
  void didUpdateWidget(covariant NoDetectHint oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resetSignal != widget.resetSignal) {
      oldWidget.resetSignal?.removeListener(_resetTimer);
      widget.resetSignal?.addListener(_resetTimer);
    }
  }

  void _armTimer() {
    _timer?.cancel();
    _timer = Timer(widget.delay, () {
      if (!mounted) return;
      setState(() => _visible = true);
    });
  }

  void _resetTimer() {
    if (!mounted) return;
    setState(() => _visible = false);
    _armTimer();
  }

  @override
  void dispose() {
    widget.resetSignal?.removeListener(_resetTimer);
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  void _onType() {
    // Pop the scanner first so the user's back button from the search
    // screen does not land on a stale camera frame; then push the
    // search screen with the T-021 paste affordance ready. The
    // `context.mounted` guard catches the rare frame in which the
    // host's own `Navigator.pop` already unmounted us before the
    // second navigation fires.
    final navigator = Navigator.of(context);
    navigator.pop();
    if (!context.mounted) return;
    context.push(Routes.foodsSearchPath);
  }

  void _onAddCustom() {
    final navigator = Navigator.of(context);
    navigator.pop();
    if (!context.mounted) return;
    context.push(Routes.foodNewPath);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final space = context.space;
    return IgnorePointer(
      ignoring: !_visible,
      child: AnimatedOpacity(
        opacity: _visible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        child: Semantics(
          liveRegion: true,
          container: true,
          child: Container(
            decoration: BoxDecoration(
              // Architect §3.10: `colors.surface` at 0.92 opacity so a
              // sliver of the camera dim bleeds through and the band
              // reads as overlay, not chrome.
              color: colors.surface.withValues(alpha: 0.92),
              border: Border(top: BorderSide(color: colors.line)),
            ),
            padding: EdgeInsets.fromLTRB(
              space.x4,
              space.x3,
              space.x4,
              space.x3,
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Trouble scanning?',
                    style: text.bodyStrong.copyWith(color: colors.ink),
                  ),
                  SizedBox(height: space.x05),
                  Text(
                    'Try a different angle, or use one of these.',
                    style: text.meta.copyWith(color: colors.ink2),
                  ),
                  SizedBox(height: space.x2),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: PrimaryButton(
                          label: 'Type the barcode',
                          dense: true,
                          onPressed: _onType,
                        ),
                      ),
                      SizedBox(width: space.x2),
                      Expanded(
                        child: PrimaryButton(
                          label: 'Add a custom food',
                          dense: true,
                          onPressed: _onAddCustom,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
