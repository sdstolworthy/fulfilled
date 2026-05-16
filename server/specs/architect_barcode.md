# Architect — Barcode scanner (mobile camera capture + web tightening)

Implementation contract for `specs/pm_barcode.md`. The PM has decided
the shape of the mobile camera flow, the four-format whitelist, the
permission UX, and the web-tightening rider; this doc translates that
into file-level seams, widget shapes, route names, provider
invalidation, test seams, and acceptance criteria the technical
program manager can carve into developer tickets without re-asking.

The two prior contracts win where they disagree with this one:
`specs/flutter_ui_architecture.md` (the 23 tenants — especially T-01
tokens, T-04 accent reservation, T-06 touch targets, T-11 inline
errors, T-14 routes-vs-sheets, T-15 form factor at the root, T-20
accessibility, T-23 widget package imports) and `specs/pm_barcode.md`
(the PM's barcode-specific rulings on continuous scan, format
whitelist, manual-entry escape hatch, and web hide rule). Where this
doc names a behaviour and either of those disagrees, the prior doc
wins.

I read every file PM inventoried in §1 + §11 of their direction doc,
plus the four seams that already ship today: `BarcodeScanButton`'s
`TODO(scan)` stub, `SearchField`'s desktop paste hint, the
`_BarcodeResolveScreen` resolver at `/foods/barcode/:barcode`, and the
`Routes.foodBarcodePath` constant. The plan compiles in my head; I
expect the developer tickets that come out of this to compile on an
agent's machine without surprise. The single deferred unknown — whether
`mobile_scanner` 5.2.3 exposes a permission-status enum I can read
without adding `permission_handler` — is called out in §6 as the one
ticket-blocking question.

---

## 1. Architectural overview

**Shape on mobile.** A new full-screen `ScanScreen` route lives at
`/foods/scan`, mounted **outside** the `ShellRoute` (no bottom tabs,
no FAB, no sidebar). It hosts a `mobile_scanner` `MobileScanner`
widget configured to the four-format whitelist (`ean13`, `upcA`,
`ean8`, `upcE`) with `detectionSpeed: DetectionSpeed.noDuplicates`
and a `detectionTimeoutMs: 250` window. A custom `ViewfinderOverlay`
paints the dim-around-a-rounded-square reticle the PM specified; a
top toolbar (close left, manual-entry icon next to it, torch right)
sits over the camera; a `NoDetectHint` slides up from the bottom at
the 10-second mark with the "Type the barcode / add a custom food"
escalation; a `PermissionDenied` `EmptyState` replaces the camera
when the OS denies access. On a successful decode, the screen stops
the controller, fires `HapticFeedback.lightImpact()`, pops itself,
and the caller — `openBarcodeScanner` in §3.2 — pushes the existing
`/foods/barcode/$code` route, which already handles 200 / 404 / error
via `_BarcodeResolveScreen`. The route is **not** deep-linkable per
PM §6: it's intra-app navigation only.

**Shape on web.** Nothing new. The desktop paste-a-barcode affordance
(T-021, shipped) is the entire web story. The single change is the
existing `BarcodeScanButton`'s hide rule, which tightens from
`kIsWeb && !isCompact` to `kIsWeb` flat — the button now hides on
**all** web builds including mobile-web Safari, since `mobile_scanner`
has no web implementation we want to ship (PM §7's BarcodeDetector /
zxing-js analysis is the canonical rationale). `SearchField`'s
hint-swap also tightens from `isExpanded` to `kIsWeb` so mobile-web
reads "Search foods or paste a barcode…" instead of "Search foods or
scan barcode…" — we do not want to suggest a scanner that isn't
there.

---

## 2. Platform split

The behavioural table the PMgr can paste verbatim into the
implementation ticket. Note "mobile-web compact" is **web**, not
mobile — that's the Safari-on-iPhone case that PM §7 calls out by
name.

| Platform | Behavior |
|---|---|
| iOS / Android, compact (`< 600`) | Scan button visible; tap → `ScanScreen` route → camera preview → detect → push `/foods/barcode/$code`. |
| iOS / Android, medium (`600 – 1023`, e.g. iPad portrait, foldable) | Same as compact. `ScanScreen` fills the viewport; viewfinder remains a 70%-of-shorter-side rounded square — meaning on a 768-wide iPad portrait it tops out at ~538 px. No layout branch needed. |
| iOS / Android, expanded (`≥ 1024`, e.g. iPad landscape) | Same as compact. The camera preview fills the viewport; the viewfinder centers in the wider canvas. **No two-column variant.** A 1024+ camera surface with a side panel would invite "let me embed a search field next to the scanner" feature creep we are not scoping. See §6 risk 3. |
| Web, any width (desktop, mobile-web Safari) | Scan button hidden via `kIsWeb` gate (defence-in-depth still gates `openBarcodeScanner`). `SearchField` paste-a-barcode is the only path. |

T-15 holds: the platform branch happens at the **screen root**
(`BarcodeScanButton.build` decides whether to render; `ScanScreen`
itself never receives a web build because the only opener is gated on
`!kIsWeb`). Leaf widgets (`ViewfinderOverlay`, `ScanTorchButton`,
`NoDetectHint`) do not branch on platform.

---

## 3. The scanner route — deep dive

### 3.1 Route name + path

Two new constants in `client/lib/routing/routes.dart`:

```dart
static const String foodScanName = 'foods.scan';
static const String foodScanPath = '/foods/scan';
```

Placed in the "Outside the shell (no nav chrome)" group, immediately
after `foodBarcodeName / foodBarcodePath` — the two routes are
neighbours conceptually and should be neighbours in the file. The
path is **non-deep-linkable in spirit** (per PM §6 "intra-app only"),
but `go_router` doesn't have a "private route" concept; the gate is
that the only caller is `openBarcodeScanner`, which checks `kIsWeb`
first. A user deep-linking `/foods/scan` from a web URL hits the
shell-less route, which is fine on native (camera permission prompt
fires, scanner runs) and degenerate on web (camera permission is
either denied or the platform channel is a no-op). We do not invest
in blocking direct navigation — the cost outweighs the risk.

The `GoRoute` registration in `client/lib/routing/app_router.dart`,
inserted in the "Outside the shell" block immediately after the
`foodBarcodeName` route:

```dart
GoRoute(
  name: Routes.foodScanName,
  path: Routes.foodScanPath,
  builder: (_, __) => const ScanScreen(),
),
```

No path parameters, no query parameters. The route is parameterless
because the scanner does its own detection; the detected value is
handed to the resolver via `context.push('/foods/barcode/$code')`,
not via a route arg.

### 3.2 The public opener — `openBarcodeScanner`

A new top-level function in `client/lib/features/scan/openers.dart`:

```dart
/// Opens the full-screen barcode scanner route.
///
/// Mobile (iOS / Android, native only): pushes `/foods/scan`. On a
/// successful detection the [ScanScreen] pops with the decoded value
/// as the result; this function then pushes
/// `/foods/barcode/$decoded` so the existing resolver handles the
/// 200 / 404 / error split.
///
/// Web (any width — desktop or mobile-web Safari): no-op. PM §7
/// rules camera-on-web out of v1 and the affordance is already
/// hidden on web by [BarcodeScanButton]; this guard is defence in
/// depth so a future caller can't accidentally open the route on
/// web.
Future<void> openBarcodeScanner(BuildContext context) async {
  if (kIsWeb) return;
  final code = await context.push<String>(Routes.foodScanPath);
  if (code == null || code.isEmpty) return;
  if (!context.mounted) return;
  await context.push('/foods/barcode/$code');
}
```

Three rulings:

- **The opener is a function, not a method on a widget.** It's the
  single bottleneck for "the entire app's barcode-camera entry
  point." `BarcodeScanButton.onPressed` calls it; future callers
  (a hypothetical FAB sub-action on Today; the custom-food
  barcode field on screen 05) call the same function. One seam, one
  test seam, one place to gate.
- **The function is asynchronous and returns `Future<void>`.** The
  callers that need a result (e.g. a custom-food form that wants the
  scanned barcode to populate a field, not push to the resolver) get
  a sibling function — see §3.3 — that returns the raw
  `Future<String?>`. The default opener wires through the resolver
  because that's the path screen 02 wants.
- **The `kIsWeb` gate is unconditional.** PM §7 superseded the
  architecture's softer `isWeb && !isCompact` rule. Even mobile-web
  must short-circuit, because `mobile_scanner` has no web
  implementation we want to ship.

### 3.3 The raw scanner opener — `scanBarcode`

A second function for callers that want the decoded value without
the resolver push:

```dart
/// Lower-level seam: opens [ScanScreen], returns the decoded
/// barcode (or null on user dismiss / web). Used by screen 05's
/// custom-food form where the barcode is captured into a draft
/// field rather than routed to the resolver.
Future<String?> scanBarcode(BuildContext context) async {
  if (kIsWeb) return null;
  return context.push<String>(Routes.foodScanPath);
}
```

`openBarcodeScanner` is the thin wrapper around `scanBarcode` that
also does the resolver push. The custom-food form (screen 05's
barcode field, currently desktop-paste-only) calls `scanBarcode`
directly when we wire its mobile barcode-input path in a later
ticket — that is **out of scope here** but the seam is in place.

### 3.4 `ScanScreen` widget — root structure

File: `client/lib/features/scan/scan_screen.dart`.

```dart
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key, this.controllerOverride});

  /// Test-only seam — production leaves this null and the screen
  /// constructs its own `MobileScannerController`. Widget tests
  /// inject a fake to drive `onDetect` without touching real
  /// platform channels. Same pattern as `showLogEntrySheetOverride`
  /// on `FoodDetailScreen` (food_detail_screen.dart:54).
  final MobileScannerController? controllerOverride;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}
```

`StatefulWidget`, not `ConsumerStatefulWidget`. The scanner state is
local — controller, torch flag, no-detect timer, permission state,
detection-completed latch — and none of it belongs in a Riverpod
provider. The only Riverpod surfaces touched are the routing
helpers, which read `ref` from `GoRouter.of(context)` directly. The
opener does the navigation; the screen returns the decoded value as
the route pop result.

State fields:

```dart
class _ScanScreenState extends State<ScanScreen>
    with WidgetsBindingObserver {
  late final MobileScannerController _controller;
  Timer? _noDetectTimer;
  bool _showHint = false;
  bool _detected = false; // latch so we never fire twice
  _PermissionState _permission = _PermissionState.unknown;
}
```

Lifecycle:

- `initState`: construct the controller (or use the override), arm
  the 10-second `_noDetectTimer`, register `WidgetsBindingObserver`
  for the lifecycle-resume permission re-check (see §3.9).
- `dispose`: cancel the timer, dispose the controller, unregister
  the observer. The torch flag is **not** persisted across route
  disposes — PM §6 "Torch reset to off on route dispose" applies.
- `didChangeAppLifecycleState(AppLifecycleState.resumed)`: re-check
  permission status (see §3.9) and resume the controller if it was
  stopped while we were backgrounded.

### 3.5 Controller configuration

```dart
_controller = widget.controllerOverride ??
    MobileScannerController(
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
```

Five non-negotiable settings, each cited from PM §5 (formats) and
PM §6 (continuous scan, no duplicates, no image return):

- `formats` is explicit — `mobile_scanner`'s default is "all formats"
  which burns CPU and creates the off-target detection problem PM §5
  spells out (driver's licence PDF417, restaurant QR codes, shipping
  ITF). The four-element list above is the entire whitelist.
- `detectionSpeed: noDuplicates` plus the explicit `controller.stop()`
  in `_onDetect` (§3.6) is the belt-and-braces guard against the
  "five-of-the-same-burrito" bug PM §3 principle 8 names.
- `detectionTimeoutMs: 250` is PM §6's value; lower than the package
  default (1000 ms), it keeps the camera responsive on the second
  scan if the user re-enters the route.
- `returnImage: false` saves CPU and avoids leaking camera frames
  into our process memory; we don't preview the captured frame.
- `torchEnabled: false` is the initial state; the user toggles it
  via `ScanTorchButton`.

### 3.6 Detection handler

```dart
void _onDetect(BarcodeCapture capture) {
  if (_detected) return; // latch
  if (capture.barcodes.isEmpty) return;
  final value = capture.barcodes.first.rawValue;
  if (value == null || value.isEmpty) return;
  if (!_isAcceptableLength(value)) return;
  _detected = true;
  _noDetectTimer?.cancel();
  unawaited(_controller.stop());
  unawaited(HapticFeedback.lightImpact());
  if (!mounted) return;
  Navigator.of(context).pop(value);
}
```

`_isAcceptableLength` enforces the 8–14 digit floor that matches
T-021's `^\d{8,14}$` regex on the paste path, so a stray code from
the controller's whitelist that's the wrong length never reaches the
resolver. Belt and braces — the format whitelist already restricts
EAN/UPC, which are length-bounded by the spec, but a malformed
decode is cheap to drop here.

The `Navigator.of(context).pop(value)` returns the decoded string up
to `openBarcodeScanner`, which then pushes the resolver. We pop
**before** the resolver push so the user's back button from food
detail lands on the search screen, not on a stale camera frame.

### 3.7 Viewfinder overlay

File: `client/lib/features/scan/widgets/viewfinder_overlay.dart`.

The PM specified "70%-of-shorter-side rounded square, dim around it,
`AppRadius.r3` corners, match Yuka." Implementation:

```dart
class ViewfinderOverlay extends StatelessWidget {
  const ViewfinderOverlay({super.key, this.cornerRadius});

  /// Overridable for tests; production reads `context.radius.r3`.
  final double? cornerRadius;

  @override
  Widget build(BuildContext context) {
    final radius = cornerRadius ?? context.radius.r3;
    return CustomPaint(
      painter: _ViewfinderPainter(
        dim: context.colors.ink.withOpacity(0.55),
        cornerRadius: radius,
      ),
      size: Size.infinite,
    );
  }
}
```

The painter:

1. Computes the viewport size from the `Canvas`'s clip rect.
2. Computes `cutoutSide = shorterSide * 0.70`.
3. Draws an `evenOdd`-filled path: outer rect (full viewport) minus
   the centered `RRect` of side `cutoutSide` and radius `r3`.
4. Optionally strokes the cutout edge with a 1.5 px `surface` line
   for crispness against dark camera frames (T-04 forbids accent
   for decorative chrome, and T-03 forbids macro colors; `surface`
   is the only token that reads as "frame, not action").

Two tenant notes:

- **T-01 token discipline:** the dim color is `context.colors.ink`
  at 0.55 opacity, **not** a raw `Colors.black54`. The choice of
  ink over `Colors.black` keeps the dim consistent with the ink
  family the rest of the app uses; opacity is computed at the call
  site, which is permitted (tokens are colors; opacities are
  numeric and live in widget code, mirroring `colors.line2` usage
  elsewhere).
- **T-04 accent reservation:** the cutout edge stroke is **not**
  accent. The PM's competitive note about Yuka's accent-bracket
  flash on detection is a v1.1 consideration — we are not painting
  accent brackets in this scope. A subtle white edge against a dim
  surround reads as "frame" without consuming the accent budget.
  See §6 risk 5.

### 3.8 Top bar — close + torch

The top bar is a stack of two `IconButton36`s on a transparent
backdrop over the camera preview. Layout: 8 px top-safe-area
padding, 16 px horizontal padding, `Row` with `Spacer` between the
close (left) and the torch (right).

**Close button.** `IconButton36(icon: Icons.close, onPressed: () =>
Navigator.of(context).pop(null), tooltip: 'Close')`. Tapping pops
with `null` so the opener sees "user dismissed" and does not push
the resolver.

**Torch button.** A small private `_ScanTorchButton` widget at
`client/lib/features/scan/widgets/scan_torch_button.dart`:

```dart
class _ScanTorchButton extends StatelessWidget {
  const _ScanTorchButton({required this.controller});

  final MobileScannerController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TorchState>(
      valueListenable: controller.torchState,
      builder: (context, state, _) {
        final on = state == TorchState.on;
        return IconButton36(
          icon: on ? Icons.flash_on_outlined : Icons.flash_off_outlined,
          tooltip: on ? 'Turn flash off' : 'Turn flash on',
          onPressed: () => unawaited(controller.toggleTorch()),
        );
      },
    );
  }
}
```

Two tenant notes:

- **Color over camera.** `IconButton36`'s default icon color is
  `colors.ink` against `colors.surface`. Over the camera preview
  that contrast goes the wrong way (dark icon, dark frame). We
  layer a 24 px translucent-surface backdrop (a `Container` with
  `colors.surface.withOpacity(0.18)`, `borderRadius: rPill`) behind
  the `IconButton36` so the icon is legible regardless of camera
  content. **T-01 holds** — we never reach for raw hex; opacity
  on a token is permitted (same pattern the existing `MacroBar`
  uses).
- **T-06 touch target.** `IconButton36` already enforces 36 px
  visual + ≥ 44 px hit slop. The translucent backdrop is purely
  visual; it doesn't change the slop.

The button **hides on devices without a torch.** `mobile_scanner`'s
`MobileScannerController.hasTorch` is a `ValueNotifier<bool>` we can
read after `start()` completes; if false, render `SizedBox.shrink()`
instead. Per PM §9 acceptance criterion: "the button is hidden, not
greyed." On the first build before `start()` resolves, render the
torch-off icon optimistically — the worst case is a 200 ms flash of
an unusable icon, which is preferable to layout shift.

### 3.9 Permission UX

This is the section with one open question (see §6 risk 2). The PM
flagged two acceptable paths and asked the architect to decide.

**Choice: do not add `permission_handler`.** Rationale below.

`mobile_scanner` 5.2.3 surfaces permission via two seams:

1. `MobileScannerController.start()` throws a
   `MobileScannerException` with an `errorCode` of
   `MobileScannerErrorCode.permissionDenied` (and
   `permissionDeniedDuringSession` if revoked mid-session) when the
   OS denies the camera.
2. The `MobileScanner` widget's `errorBuilder` is invoked with the
   same exception when the underlying platform channel reports
   denied / restricted.

Both are sufficient to **detect** the denial. Neither lets us **deep-
link to Settings**. Deep-linking would require `permission_handler`
(or `app_settings`, the lighter alternative the PM mentioned). The
trade-off:

- **Add `app_settings` (or `permission_handler`):** new pub dep, ~50
  KB on Android, native channel registration, an extra surface in
  `pubspec.yaml` to keep updated. Buys us a one-tap "Open Settings"
  button.
- **Don't add a pub dep:** the `PermissionDenied` empty state
  renders manual instructions ("Open Settings → Privacy → Camera →
  Fulfilled"), which is the same recovery copy MyFitnessPal ships
  (PM §2 noted MFP's "minimal recovery copy" without complaint).
  Saves the dep at the cost of one extra tap and a small reading
  burden on the user.

**Recommendation: ship v1 without a pub dep.** The deep-link is
nice-to-have, not blocking. The user who has denied camera
permission six months ago and now wants to scan a barcode is a
small minority of a feature that itself is one of several entry
points to logging. The cost of `permission_handler` (or
`app_settings`) is non-zero in maintenance terms and we have
existing pub-dep restraint as a working norm. **If PM disagrees
after seeing this rationale, the swap is small** — one new dep, one
new tap target in `PermissionDenied`, no other changes. Flagged as
§6 risk 2 for the PMgr to confirm.

`PermissionDenied` widget at
`client/lib/features/scan/widgets/permission_denied.dart`:

```dart
class PermissionDenied extends StatelessWidget {
  const PermissionDenied({super.key, required this.onRetry});

  /// "Try again" affordance: re-attempt `MobileScannerController.start()`.
  /// If the user enabled the permission in Settings, this resumes the
  /// camera silently. If still denied, the screen re-renders this
  /// empty state.
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.no_photography_outlined,
      title: 'Camera access is off',
      body: 'Turn on the camera to scan barcodes.\n'
            'Open Settings → Privacy → Camera → Fulfilled, '
            'then tap Try again.',
      action: SizedBox(
        width: 200,
        child: PrimaryButton(label: 'Try again', onPressed: onRetry),
      ),
    );
  }
}
```

The "Restricted" case (kid mode / parental controls) is identical to
denied — `mobile_scanner` reports both as `permissionDenied`. We do
not branch the copy because the recovery is the same ("ask the
device admin to allow camera").

**Lifecycle resume hook.** When the user returns from the
backgrounded app (after toggling Settings), `didChangeAppLifecycleState
(resumed)` fires; the screen calls `_attemptStart()` which is the
same path the "Try again" button hits. If the user enabled the
permission, the camera comes up silently. If still denied, the empty
state stays. This matches PM §6's "re-check permission status and
resume the camera silently if granted."

### 3.10 No-detect hint

File: `client/lib/features/scan/widgets/no_detect_hint.dart`.

PM §3 principle 6: "After 10 seconds without a detection, render a
small text overlay at the bottom — 'Trouble scanning? Type the
barcode or add a custom food.' Two text actions, both `PrimaryButton`s
in compact size."

A pedantic re-reading: PM said `PrimaryButton`s, not text actions.
The PM's exact wording is "Two text actions, both `PrimaryButton`s
in compact size" — which is ambiguous but parsed as "two
`PrimaryButton`s sized compact." We ship two `PrimaryButton`s side
by side. The compact-size `PrimaryButton` is the 44 px height
variant (the standard `PrimaryButton` is 54 px) — see §6 risk 4 if
the `PrimaryButton` widget doesn't currently support a "compact"
size param. If it doesn't, we add a `dense: true` flag in the same
PR; PM's request is unambiguous on the affordance shape.

Shape:

```dart
class NoDetectHint extends StatelessWidget {
  const NoDetectHint({
    super.key,
    required this.onType,
    required this.onAddCustom,
  });

  final VoidCallback onType;
  final VoidCallback onAddCustom;

  @override
  Widget build(BuildContext context) { /* ... */ }
}
```

Visual: a 64-px-tall band, `colors.surface` background at 0.92
opacity, top edge `colors.line`, slid in from the bottom (above the
system safe area) on a 220 ms cubic-out animation. Contents: title
text "Trouble scanning?" in `text.bodyStrong`, subtitle "Try a
different angle or…" in `text.meta` (PM didn't specify subtitle copy
but the affordance benefits from one — see §6 risk 4 for the
copy-review flag), then a `Row` with the two `PrimaryButton`s
("Type the barcode" / "Add a custom food").

State: the parent `ScanScreen` owns the 10-second timer and the
`_showHint` flag. The hint widget itself is stateless. On detect
(success), the parent cancels the timer and sets `_showHint = false`
— the hint slides back out.

**`onType` action.** Pops the scanner with a sentinel `null` value
and pushes the existing T-021 paste path on the search screen with
the keyboard pre-focused. Implementation: we don't have a "manual
barcode entry sheet" today; the simplest seam is to pop, then push
the search screen with a query param or focus directive. **Defer
the manual-entry surface to a sibling ticket** — the no-detect
hint's "Type the barcode" button initially routes to
`/foods/search` and focuses the search field, which is where the
user pastes the barcode and the T-021 detection fires. This is a
v1 compromise; the dedicated modal "enter barcode" sheet PM mentioned
in §6 is a v1.1 follow-up. See §6 risk 1 for the open question.

**`onAddCustom` action.** Pops the scanner, then pushes
`/foods/new`. The custom-food form's barcode field is empty
(because the user couldn't scan one); they fill it manually.

### 3.11 Provider invalidation

None. The scanner route reads no providers and writes no providers.
The downstream resolver invalidates the food cache the way it
already does; we do not touch it.

The only Riverpod surface we **brush** is `searchFieldFocusNodeProvider`
in the `onType` path — and we don't even reach for it directly,
because we route to `/foods/search` and the search screen handles
its own focus. **T-18 holds** (provider invalidation is explicit and
minimal): we invalidate nothing here.

### 3.12 Semantics

T-20 enforcement on every interactive surface in the scanner route:

- **Route label.** `Scaffold.body` is wrapped in
  `Semantics(label: 'Scan a food barcode', container: true)` so
  VoiceOver announces the route on entry.
- **Camera preview.** `Semantics(image: true, label: 'Camera
  viewfinder, point at a barcode')` — the preview is not
  meaningfully interactable for a screen-reader user. PM §3
  principle 7 ("manual entry is the screen-reader path") is honored
  by the no-detect hint and by the existing search paste path; we
  do not add a dedicated manual-entry button to the top bar in v1
  (see §6 risk 1 for the open question on whether to surface
  manual entry sooner).
- **Close button.** `IconButton36(tooltip: 'Close')` — the tooltip
  doubles as the `Semantics` label per its existing contract.
- **Torch button.** `Semantics(label: 'Camera light', toggled:
  torchOn)`. The on/off state is announced via the `toggled` flag
  per Flutter's `Semantics` API for `IconButton`-shaped toggles.
- **No-detect hint.** Wrapped in `Semantics(liveRegion: true)` so
  screen readers announce it on appearance. Each
  `PrimaryButton`'s label is its visible text.
- **Permission denied.** `EmptyState` already enforces
  `Semantics(label: title, hint: body)` (verified by reading
  `widgets/empty_state.dart`); no additional wrapper needed.

Color is never the sole signal: the torch on/off state is
distinguishable by both the icon (filled vs outlined flash) and the
`toggled` semantic flag. The "trouble scanning" hint band's color
is informational (surface + line) but its content is text;
screen readers read the text.

---

## 4. The web tightening

### 4.1 `BarcodeScanButton` hide rule

Current code (`barcode_scan_button.dart:33`):

```dart
if (FormFactor.isWeb && !formFactor.isCompact) {
  return const SizedBox.shrink();
}
```

After:

```dart
if (FormFactor.isWeb) {
  return const SizedBox.shrink();
}
```

PM §7 wording confirmed verbatim: *"Show only on native mobile
(iOS / Android). Hide on all web, including compact mobile-web."*
The rule reduces to a single `kIsWeb` check (or
`FormFactor.isWeb` — they're equivalent in this codebase per the
existing class).

The comment block above the check rewrites to:

```dart
// Hidden on all web (mobile-web Safari included): mobile_scanner
// has no web implementation we want to ship, and the search-field
// paste-a-barcode path (T-021) is the canonical web entry. See
// pm_barcode.md §7 for the BarcodeDetector / zxing-js analysis.
```

The `onScan` callback contract changes from `ValueChanged<String>`
to `VoidCallback` — see §4.2.

### 4.2 `BarcodeScanButton.onPressed` rewiring

Today the button is `onScan: ValueChanged<String>` and the screen
wires the callback to "push `/foods/barcode/$code`." With the new
`openBarcodeScanner(BuildContext)` opener, the button no longer
needs the value passed in — it opens the scanner, the scanner pops
with the value, the opener pushes the resolver. The button's
contract simplifies:

```dart
class BarcodeScanButton extends StatelessWidget {
  const BarcodeScanButton({super.key, this.onPressedOverride});

  /// Test-only seam — production leaves null and the button calls
  /// `openBarcodeScanner(context)`. Matches the
  /// `showLogEntrySheetOverride` pattern on `FoodDetailScreen`.
  final Future<void> Function(BuildContext)? onPressedOverride;
  // ...
}
```

The `InkResponse.onTap`:

```dart
onTap: () async {
  final open = onPressedOverride ?? openBarcodeScanner;
  await open(context);
},
```

**The `HapticFeedback.selectionClick()` line goes away.** PM §6
"Haptics are a success signal in this feature, not a UI
confirmation" — we do **not** haptic on button press, only on a
successful decode (which fires inside `ScanScreen._onDetect`).

Screen 02 (`search_screen.dart`) currently passes
`BarcodeScanButton(onScan: (code) => context.go('/foods/barcode/$code'))`
or similar; we change the call site to `const BarcodeScanButton()`
and delete the now-unused callback. (Verified via grep: only one
call site, in `search_screen.dart`. The custom-food form's screen 05
barcode field does not currently use `BarcodeScanButton` — the
button is single-purpose-named "scan from search.")

### 4.3 `SearchField` hint copy

Current (`search_field.dart:62`):

```dart
final resolvedHint = hintText ??
    (context.formFactor.isExpanded
        ? 'Search foods or paste a barcode…'
        : 'Search foods or scan barcode…');
```

After (PM §7 explicit edit):

```dart
final resolvedHint = hintText ??
    (kIsWeb
        ? 'Search foods or paste a barcode…'
        : 'Search foods or scan barcode…');
```

A one-line change. The semantics: every web build (desktop,
medium-web, mobile-web Safari) reads "paste a barcode" because the
scan button is hidden on every web build. Every native build
(iOS / Android, any width including iPad expanded) reads "scan
barcode" because the scan button is visible.

The docstring's T-021 paragraph updates from "compact" / "expanded"
language to "native mobile" / "all web." Three-line edit.

---

## 5. File / widget shape

### 5.1 New files

| Path | Owner | Purpose |
|---|---|---|
| `client/lib/features/scan/scan_screen.dart` | feature `scan` | `ScanScreen` — the full-screen route widget, owns the `MobileScannerController`, the no-detect timer, and the permission state machine. Test seam via `controllerOverride`. |
| `client/lib/features/scan/openers.dart` | feature `scan` | Public entry points: `openBarcodeScanner(BuildContext)` (push-to-resolver wrapper) and `scanBarcode(BuildContext)` (raw `Future<String?>` for screen 05's eventual use). Both `kIsWeb`-gated. |
| `client/lib/features/scan/widgets/viewfinder_overlay.dart` | feature `scan` | `ViewfinderOverlay` + `_ViewfinderPainter` — dim + centered rounded-square cutout. `CustomPainter`, no Riverpod, no platform channels. |
| `client/lib/features/scan/widgets/scan_torch_button.dart` | feature `scan` | `_ScanTorchButton` — torch toggle bound to `MobileScannerController.torchState`. Feature-private (the leading underscore is intentional — this is never used outside the scan feature). |
| `client/lib/features/scan/widgets/no_detect_hint.dart` | feature `scan` | `NoDetectHint` — the 10-second escalation band with the two `PrimaryButton`s. Stateless; parent owns the timer. |
| `client/lib/features/scan/widgets/permission_denied.dart` | feature `scan` | `PermissionDenied` — full-screen `EmptyState` with copy + "Try again" affordance. |

**T-23 compliance.** All six new files live under
`client/lib/features/scan/...`. Nothing new lives in
`client/lib/widgets/`, because none of the new widgets appear in the
§3 component inventory of the architecture doc. The two cross-
feature imports the new files take are:

- `package:fulfilled/widgets/icon_button_36.dart` — shared widget,
  T-23 allows.
- `package:fulfilled/widgets/primary_button.dart` — shared widget,
  T-23 allows.
- `package:fulfilled/widgets/empty_state.dart` — shared widget,
  T-23 allows.

Zero imports from sibling feature folders. The
`lint_no_cross_feature_widget_import.sh` lint passes by construction.

**T-01 compliance.** No raw hex; the `_ViewfinderPainter` reads
`colors.ink` and `colors.surface` from a `BuildContext` passed via
the constructor. The 0.55 / 0.18 / 0.92 opacity values are numeric
constants in the painter, not hex — consistent with how
`MacroBar` reaches for `colors.line2` at varying opacities elsewhere
in the codebase. `lint_no_hex_outside_tokens.sh` passes.

### 5.2 Modified files

| Path | Change |
|---|---|
| `client/lib/features/search/widgets/barcode_scan_button.dart` | (a) hide rule tightens to `kIsWeb`; (b) `TODO(scan)` replaced with `openBarcodeScanner(context)` call; (c) `HapticFeedback.selectionClick()` removed; (d) `onScan: ValueChanged<String>` replaced with `onPressedOverride: Future<void> Function(BuildContext)?` test seam; (e) docstring updated. |
| `client/lib/features/search/widgets/search_field.dart` | (a) hint-swap predicate changes from `isExpanded` to `kIsWeb`; (b) docstring T-021 paragraph rewords from "compact/expanded" to "native/web". |
| `client/lib/features/search/search_screen.dart` | One call-site edit: `BarcodeScanButton(onScan: ...)` → `const BarcodeScanButton()`. Delete the now-orphan callback. |
| `client/lib/routing/routes.dart` | Add `foodScanName / foodScanPath` constants. |
| `client/lib/routing/app_router.dart` | Add `GoRoute(name: Routes.foodScanName, path: Routes.foodScanPath, builder: ...)` in the "Outside the shell" block. New import: `package:fulfilled/features/scan/scan_screen.dart`. |
| `ios/Runner/Info.plist` | Add `NSCameraUsageDescription` = "Fulfilled needs camera access to scan food barcodes." PM §6 mandates the copy. |
| `android/app/src/main/AndroidManifest.xml` | Verify `<uses-permission android:name="android.permission.CAMERA" />` is present (the `mobile_scanner` plugin's manifest merger usually adds it; double-check in PR review). |

Total: 6 new files, 6 modified files (4 Dart + 2 native config).

---

## 6. Risks / open questions

Five items the PMgr should escalate or note in tickets.

### 6.1 The manual-entry surface (PMgr — decide v1 vs v1.1)

PM §3 principle 6 + §6 "Manual entry" describes a modal bottom
sheet with a `TextField` that routes `^\d{8,14}$` to
`/foods/barcode/$value`. PM §3 principle 7 makes manual entry the
screen-reader path and says it should be "always one tap away from
the scanner route's top-bar (an `IconButton36` with
`Icons.keyboard`)."

**This is more surface than the PM's per-screen ruling in §6 makes
clear.** Two interpretations of the PM doc:

1. **Tight reading:** ship the modal manual-entry sheet in v1, with
   a keyboard `IconButton36` in the top bar between close and torch,
   plus the no-detect hint button. Three entry points to manual
   entry from the scanner route.
2. **Loose reading:** ship the no-detect hint's "Type the barcode"
   button only, route it to `/foods/search` with focus on the
   search field (where T-021 paste detection fires the same
   resolver). v1.1 adds the dedicated modal manual-entry sheet and
   the top-bar keyboard `IconButton36`.

**Recommendation: loose reading for v1.** The "type the barcode" no-
detect button covers the 10-second-no-decode escape hatch the PM
named as the critical accessibility seam. The dedicated modal sheet
plus the top-bar manual-entry icon is incremental work that does not
block the burrito-shop happy path. **The screen-reader path is the
existing search paste flow, reached via the no-detect hint** — which
is a degraded experience for blind users compared to the spec but
not blocked.

**PMgr — confirm.** If PM wants the dedicated modal manual-entry
sheet in v1, add a sibling ticket. The scaffold is small (one new
widget file at `client/lib/features/scan/widgets/manual_entry_sheet.dart`,
one new `IconButton36` in `ScanScreen`'s top bar between close and
torch, one new opener function); the ticket is well-shaped.

### 6.2 `permission_handler` / `app_settings` dep — for or against

§3.9 ruled **against** adding `permission_handler` or `app_settings`
in v1 on the rationale that:

- `mobile_scanner` 5.2.3 already surfaces denial via
  `MobileScannerErrorCode.permissionDenied`, so detection is solved.
- The cost is a deep-link to per-app Settings; the alternative is
  manual instructions in the `PermissionDenied` body.
- The user population that has denied camera permission and now
  wants the scanner is a small minority.

**PMgr — confirm.** If PM thinks the deep-link is worth the dep, the
swap is one new dep (`app_settings: ^5.1.1` is the smaller of the
two — `permission_handler` brings a status API we don't need since
`mobile_scanner` already surfaces it), one new tap-target in
`PermissionDenied` ("Open settings" `PrimaryButton`), and one new
call site (`AppSettings.openAppSettings()`). Five-line code change;
the dep is the real cost.

### 6.3 iPad landscape (expanded) — is it the same as compact?

PM §6 "Where the scanner mounts" specifies full-screen route, no
shell. §2's platform table in this doc says iPad landscape (1024+)
uses the same `ScanScreen` with the viewfinder centered in the wider
canvas.

**Risk: a 1024-wide camera surface with a 70% cutout means a 717 px
viewfinder.** That's larger than most physical barcodes the user
will hold up to the iPad — the user has to back the camera off the
package by ~30 cm to fit the EAN-13 inside the cutout. On a
hand-held iPad in a kitchen this is fine; on an iPad mounted on a
fridge in commercial-kitchen scenarios, it's awkward.

**Recommendation: cap the cutout side at 320 px on expanded.** Add
a `shorterSide.clamp(0, 320) * 0.70` minimum-equivalent to
`_ViewfinderPainter`'s geometry math. This keeps the affordance
sized like a phone scanner regardless of viewport.

**PMgr — confirm.** Low risk, but the choice should be deliberate
because PM §6 didn't address it.

### 6.4 `PrimaryButton` "compact size" — does it exist?

PM §3 principle 6 specifies "Two text actions, both `PrimaryButton`s
in compact size."

The `PrimaryButton` widget at `client/lib/widgets/primary_button.dart`
is the 54-px high sticky-CTA button. It does **not** currently
expose a "compact" or "dense" size variant.

**Two options:**

1. Add a `dense: bool` constructor param to `PrimaryButton` that
   reduces height to 44 px and font size to `text.body` from
   `text.bodyStrong`. One-file change in `widgets/`; affects every
   call site by being purely additive.
2. Ship the no-detect hint's actions as `IconButton36`-adjacent
   text buttons, not `PrimaryButton`s, ignoring the PM's exact
   wording.

**Recommendation: option 1.** Adds a meaningful size variant we
can reuse elsewhere (the log-entry sheet's quick-multiplier chips
arguably want it). One ticket in the sequencing list (§9).

### 6.5 Accent flash on detection — v1 or v1.1?

PM §3 principle 3 specifies haptic + visual feedback on detection,
with the visual being a "flash the reticle to `AppColors.accentSoft`
for 120 ms with a corner-bracket pulse to `AppColors.accent`."

§3.7 of this doc ships the viewfinder without the accent flash —
the cutout edge stroke is `surface`, not accent, and there is no
animation on decode (we pop the route before the user perceives the
animation anyway).

**PMgr — confirm the dropped scope.** The PM's visual is nice
polish, but the route pops within ~50 ms of the haptic, so the user
sees the flash for less than the animation duration. The haptic is
the dominant feedback signal in practice; the visual is gravy.

If PM wants it in v1, it's a small ticket: `ViewfinderOverlay` grows
an `AnimationController`-driven highlight that fires on a
`ValueListenable<bool>` we expose from `ScanScreen` on decode. ~40
lines.

---

## 7. Test seam

The architect's house pattern (from `food_detail_screen.dart:54`,
`day_view_compact.dart`'s `showLogEntrySheet` injection, and the
sheet override on screen 02) is **constructor-injected callbacks
keyed on `Override`**.

### 7.1 `ScanScreen.controllerOverride`

```dart
const ScanScreen({super.key, this.controllerOverride});
final MobileScannerController? controllerOverride;
```

Production leaves it null and the screen constructs its own
controller. Widget tests inject a fake:

```dart
class _FakeMobileScannerController implements MobileScannerController {
  void emitDetection(String code) {
    // Push a synthetic BarcodeCapture through the onDetect callback
    // the screen registered with us via .start().
  }
  // ...stubs for the rest of the interface
}

testWidgets('decodes a barcode and pops with the value', (tester) async {
  final controller = _FakeMobileScannerController();
  await tester.pumpWidget(
    MaterialApp(home: ScanScreen(controllerOverride: controller)),
  );
  controller.emitDetection('8000500310427');
  await tester.pump();
  expect(find.byType(ScanScreen), findsNothing); // popped
});
```

This is the same pattern as `showLogEntrySheetOverride` on
`FoodDetailScreen` — the override is constructor-level, defaults
null, production never reaches for it. The lint and the convention
are already established; we inherit them.

### 7.2 `BarcodeScanButton.onPressedOverride`

```dart
const BarcodeScanButton({super.key, this.onPressedOverride});
final Future<void> Function(BuildContext)? onPressedOverride;
```

Tests that want to verify the button opens the scanner (without
actually pushing a route) inject a stub. Production leaves it null
and the button calls the real `openBarcodeScanner`.

### 7.3 `openBarcodeScanner` is harder to mock

The opener is a top-level function, not a method on a class.
Function references are awkward to swap in Dart tests without
either a `package:mockito`-style harness or a dependency-injection
seam. **The chosen pattern:** tests that need to verify
`openBarcodeScanner` was called swap in via `BarcodeScanButton.onPressedOverride`
at the call site. Tests that need to verify the **opener itself**
push the resolver route swap in via integration-test golden runs
(navigation observer assertions).

This matches the existing convention in
`showLogEntrySheet` (`log_entry_sheet.dart`): the public function
is unmockable, but every caller injects an override at its own
seam. Layered defence.

---

## 8. Tenant updates

**None proposed.** The 23 existing tenants cover every behaviour
this feature introduces:

| Tenant | How this feature obeys it |
|---|---|
| **T-01** Token discipline | `ViewfinderOverlay` reaches for `colors.ink` / `colors.surface`, never raw hex. Opacity values are numeric (permitted on tokens, same pattern as `MacroBar`). |
| **T-04** Accent reservation | The viewfinder cutout edge is `surface`, **not** accent. Accent is reserved for primary actions (the `PrimaryButton`s in `NoDetectHint`) and `IconButton36` defaults. |
| **T-06** Touch target floor | `IconButton36` in close + torch slots already enforces ≥ 44 px hit slop. |
| **T-08** Skeletons match final layout | N/A — there's no asynchronous list to skeleton-ize. The resolver downstream (`_BarcodeResolveScreen`) already does the right thing with a spinner during round-trip (and that's fine — a spinner on a single-line transient screen is acceptable per existing convention). |
| **T-11** Errors inline | Permission denial renders inline as an `EmptyState`, not a modal `AlertDialog`. |
| **T-14** Routes vs sheets | The scanner is a route (`/foods/scan`). The no-detect hint is in-page (not a sheet). Manual entry is deferred but, if added, will be a sheet per PM §6. |
| **T-15** Form factor branches at the root | `BarcodeScanButton` branches at its own root (hide on web). `ScanScreen` does not branch — the same widget tree renders on every native platform. The viewfinder geometry is data-driven on viewport size, not on a form-factor switch. |
| **T-18** Provider invalidation explicit | No providers invalidated. |
| **T-20** Accessibility minimums | `Semantics` on the route, the preview, the close button, the torch button, the no-detect hint. Color is never the sole signal (torch toggled state is announced; hint is text). |
| **T-23** Package-imported widgets | All cross-feature imports go through `package:fulfilled/widgets/...`. Zero sibling-feature imports. |

A T-24 along the lines of "Camera surfaces are chrome-less full-
screen routes" would be over-fitted to one feature — skip. The rule
falls naturally out of T-15 (the scanner doesn't render through
`AppScaffold`, so it has no chrome to branch on) and T-14 (it's a
route by addressability requirements, not a sheet).

A T-24 along the lines of "Avoid pub deps when an existing one
covers the surface" would be a working principle, not a tenant —
skip. Tenants are widget / token / state rules; dep-discipline is a
team norm.

**No tenant text changes** to the existing 23. T-21's display-units
ruling does not apply (barcodes are strings, not quantities). T-22's
pending-sync ruling does not apply (the scanner does not write).

---

## 9. Sequencing recommendation

The work splits cleanly into three sub-tickets that can run **in
parallel** because they touch disjoint files. Recommended PR shape:

### PR A — Route + opener + button rewrite (the "wire it up" PR)

Files touched:

- `client/lib/features/scan/scan_screen.dart` (new — skeleton with
  `MobileScanner` + controller lifecycle + `_onDetect` + permission
  state machine; viewfinder + torch + hint are placeholders that
  PR B and PR C fill in).
- `client/lib/features/scan/openers.dart` (new).
- `client/lib/routing/routes.dart` (add `foodScanName / foodScanPath`).
- `client/lib/routing/app_router.dart` (add the `GoRoute`).
- `client/lib/features/search/widgets/barcode_scan_button.dart`
  (hide rule tightens to `kIsWeb`; callback contract simplifies;
  `TODO(scan)` removed).
- `client/lib/features/search/widgets/search_field.dart` (hint
  predicate `isExpanded` → `kIsWeb`).
- `client/lib/features/search/search_screen.dart` (call-site edit
  for `BarcodeScanButton`).
- `ios/Runner/Info.plist` (`NSCameraUsageDescription`).
- `android/app/src/main/AndroidManifest.xml` (verify camera
  permission).

**This is the minimum PR that ships the feature in a degraded
state.** Camera comes up, decodes, navigates. No viewfinder
graphics, no torch, no no-detect hint. Tickets B and C fill in the
polish.

### PR B — Viewfinder overlay

Files touched:

- `client/lib/features/scan/widgets/viewfinder_overlay.dart` (new).
- `client/lib/features/scan/scan_screen.dart` (replace the
  viewfinder placeholder with the real widget; one-line import +
  one-line `Stack` child swap).

Disjoint from PR C and from the bulk of PR A. Can land any time
after PR A's skeleton.

### PR C — Torch + no-detect hint + permission denied

Files touched:

- `client/lib/features/scan/widgets/scan_torch_button.dart` (new).
- `client/lib/features/scan/widgets/no_detect_hint.dart` (new).
- `client/lib/features/scan/widgets/permission_denied.dart` (new).
- `client/lib/features/scan/scan_screen.dart` (wire the three
  widgets into the `Stack` and the state machine; ~30 line diff).
- `client/lib/widgets/primary_button.dart` (add `dense: bool`
  variant — see §6 risk 4; only if PM confirms the variant is
  in scope).

The `PrimaryButton.dense` change is the only file outside the
`scan` feature folder this PR touches; if PM punts the dense
variant to v1.1, PR C's `NoDetectHint` ships with the 54-px-tall
buttons and the visual is a little crowded but functional.

### Why three PRs not one

The single-PR alternative is ~600 lines of new code across 6 new
files. The three-PR split keeps each PR under 200 lines, lets
three agents (or three Codex sessions) work in parallel, and lets
the user verify the happy-path scanner before the polish lands.

**Total: ~4 PRs if you count the optional follow-up.**

1. PR A — Route + opener + button rewrite.
2. PR B — Viewfinder overlay.
3. PR C — Torch + no-detect hint + permission denied.
4. PR D *(optional, deferred)* — Manual-entry modal sheet + top-
   bar keyboard `IconButton36`. Only if PM confirms §6 risk 1's
   tight reading.

Per the PM's typical sequencing, ship A first (the user can scan a
barcode and resolve it), then B and C in parallel.

---

## 10. Acceptance criteria

Bullets a reviewer can cite when reviewing the implementation PRs.
These supplement PM §9's nine acceptance criteria — every PM
criterion still holds; this list adds the architecture-side ones.

- `client/lib/features/scan/scan_screen.dart` exists, is a
  `StatefulWidget`, and accepts an optional
  `MobileScannerController?` constructor param.
- `client/lib/features/scan/openers.dart` exposes
  `Future<void> openBarcodeScanner(BuildContext)` and
  `Future<String?> scanBarcode(BuildContext)`. Both first-line
  return on `kIsWeb`.
- `Routes.foodScanName` is `'foods.scan'` and `Routes.foodScanPath`
  is `'/foods/scan'`. Registered in `app_router.dart` outside the
  shell.
- `BarcodeScanButton.build` returns `const SizedBox.shrink()` when
  `kIsWeb` is true, regardless of form factor. Verified by widget
  test against compact, medium, and expanded widths on the web
  target.
- `SearchField`'s default hint reads "Search foods or paste a
  barcode…" when `kIsWeb`, "Search foods or scan barcode…"
  otherwise. Verified by widget test.
- `MobileScannerController` is constructed with the four-element
  `formats` list, `DetectionSpeed.noDuplicates`,
  `detectionTimeoutMs: 250`, `returnImage: false`,
  `torchEnabled: false`. No other format detection is enabled.
- On successful decode, `ScanScreen` calls `controller.stop()` →
  `HapticFeedback.lightImpact()` → `Navigator.pop(value)`. The
  resolver push happens in `openBarcodeScanner`, not in the screen.
- The viewfinder cutout is a centered rounded square with side =
  `min(width, height) * 0.70` and radius = `context.radius.r3`.
  Capped at 320 px on expanded widths per §6 risk 3 if PM confirms.
- The torch button hides via `SizedBox.shrink()` when
  `controller.hasTorch == false`. Verified by widget test with a
  fake controller.
- The no-detect hint slides in at 10 seconds, slides out on decode
  or on manual-entry navigation.
- Camera permission denial renders the `PermissionDenied`
  `EmptyState` in place of the camera preview, with "Try again"
  re-attempting `controller.start()`.
- `iOS/Runner/Info.plist` has
  `NSCameraUsageDescription = "Fulfilled needs camera access to
  scan food barcodes."`
- `android/app/src/main/AndroidManifest.xml` includes
  `<uses-permission android:name="android.permission.CAMERA" />`.
- All new files live under `client/lib/features/scan/`. Zero
  imports from sibling feature folders. `lint_no_cross_feature_widget_import.sh`
  passes.
- Zero raw hex in any new file. `lint_no_hex_outside_tokens.sh`
  passes.
- `Semantics` is wired on the route, the preview (image), the close
  button (tooltip via `IconButton36`), the torch button (`toggled`
  state), and the no-detect hint (`liveRegion: true`).

---

## 11. Out of scope for this contract

For the record, lest any developer agent try to do more than is
needed:

- **Backend changes.** PM §8 flagged BE-002 (server-side OFF live
  fallback on cache miss) and BE-003 (server-side EAN-13
  normalization on the wire). Both are **pre-existing tickets**
  the PM owns; the client work in this contract does not depend on
  them and is not blocked by them.
- **Web-camera scanning** via `BarcodeDetector` or `@zxing/library`.
  PM §7 explicitly punted; this contract honors the punt.
- **Nutrition label OCR.** PM §10 punt; not scoped here.
- **Continuous-scan multi-add** ("scan five items in a row"). PM
  §10 punt; the single-detect-pop pattern is the v1 contract.
- **Audio tick on scan.** PM §10 punt; haptic-only in v1.
- **Auto-open `LogEntrySheet` after barcode-resolve success.** PM
  §10 punt; the existing food-detail "Add to log" sticky CTA is
  the route.
- **`@freezed` / `@riverpod` codegen.** Not used in this feature;
  every new widget is a plain `StatelessWidget` /
  `StatefulWidget`. The two opener functions are top-level.
- **New tenants.** None proposed; the 23 cover the surface.

---

End of contract.
