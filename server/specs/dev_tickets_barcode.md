# Developer Tickets — Barcode Scanner (mobile camera + web tightening) (2026-05-16)

Source of truth for the barcode-scanner work — the third dev pool after
`dev_tickets.md` (T-NNN) and `dev_tickets_log_edit_and_units.md`
(LU-NNN). Tickets here use the `SC-NNN` prefix ("scanner") so they don't
collide. Every ticket is sized for a single developer agent to pick up,
finish, and review in one session. Agents do **not** have a Flutter SDK
— they write tests to disk inspection-correct, but they do **not** run
`flutter test` or `flutter analyze`. Assume CI gates run on a host
machine later.

**Read order**:

1. This file (you are here).
2. `specs/pm_barcode.md` — the PM's *what* and *why*.
3. `specs/architect_barcode.md` — the architect's *how*.
4. `specs/flutter_ui_architecture.md` §8 — tenants T-01..T-23 (cited
   by ID).
5. `specs/pm_decisions_flutter_ui.md` — Display Units Principle, etc.
6. `specs/dev_tickets.md` + `dev_tickets_log_edit_and_units.md` — prior
   ticket shapes. Same conventions; same Owns-files discipline.

Tickets reference these docs by section/ID instead of re-quoting them.

**Branch model**: dispatch on top of `main` at the head of the LU pool
plus any `SC-NNN` commits that landed first. Each ticket lists
`Owns files:` — an agent must not touch any file outside that list
without flagging in the ticket Notes. If two tickets share a file in
their `Owns files:` list, the dependency graph below sequences them.

**Ticket status legend**:

- `pending` — not started.
- `in-progress` — claimed by an agent; uncommitted work-in-progress.
- `done` — committed to `main`; agent has updated this doc.
- `blocked-needs-pm` — agent gave up; see failure protocol at the
  bottom.

---

## SC-001  `ScanScreen` skeleton + opener + routing wire + native config

**Status**: pending
**Priority**: P0
**Effort**: L
**Depends on**: none
**Owns files**:
- `client/lib/features/scan/scan_screen.dart` (new — `ScanScreen`
  skeleton with `MobileScanner` widget, controller lifecycle,
  `_onDetect`, permission state machine. Viewfinder / torch / no-detect
  hint / permission-denied surfaces are placeholders that SC-002 and
  SC-003 fill in.)
- `client/lib/features/scan/openers.dart` (new — `openBarcodeScanner`
  and `scanBarcode` top-level functions; both `kIsWeb`-gated.)
- `client/lib/routing/routes.dart` (add `foodScanName` +
  `foodScanPath`)
- `client/lib/routing/app_router.dart` (add `GoRoute` registration
  outside the `ShellRoute` block, immediately after
  `foodBarcodeName`)
- `client/lib/features/search/widgets/barcode_scan_button.dart`
  (rewrite: hide rule tightens to `kIsWeb`; `onScan: ValueChanged<String>`
  → `onPressedOverride: Future<void> Function(BuildContext)?` test
  seam; `HapticFeedback.selectionClick()` removed; `TODO(scan)`
  replaced with `openBarcodeScanner(context)` call; docstring updated)
- `client/lib/features/search/widgets/search_field.dart` (one-line
  hint-swap predicate change from `context.formFactor.isExpanded` to
  `kIsWeb`; docstring T-021 paragraph updated from "compact / expanded"
  to "native mobile / all web")
- `client/lib/features/search/search_screen.dart` (one-line
  call-site edit: `BarcodeScanButton(onScan: (code) => …)` →
  `const BarcodeScanButton()`; delete the now-orphan callback)
- `client/ios/Runner/Info.plist` (new file if absent; add
  `NSCameraUsageDescription = "Fulfilled needs camera access to scan
  food barcodes."`)
- `client/android/app/src/main/AndroidManifest.xml` (new file if
  absent; add `<uses-permission android:name="android.permission.CAMERA" />`)
- `client/test/features/scan/scan_screen_test.dart` (new — `controllerOverride`
  decode → pop)
- `client/test/features/scan/openers_test.dart` (new — `kIsWeb` short-
  circuit)
- `client/test/features/search/barcode_scan_button_test.dart` (new or
  updated — verify `kIsWeb` hide; verify `onPressedOverride` seam is
  invoked)
- `client/test/features/search/search_field_hint_test.dart` (new —
  verify hint copy swaps on `kIsWeb`)

### Goal
The "wire it up" PR. After this ticket lands, a native iOS / Android
build can tap the search-screen barcode button, see a full-screen
camera with a placeholder viewfinder, decode an EAN-13 / UPC-A /
EAN-8 / UPC-E barcode, and have `_BarcodeResolveScreen` resolve the
food. No viewfinder graphics, no torch button, no no-detect hint, no
permission-denied empty state — those are SC-002 and SC-003. The web
hide rule and the hint-copy swap also ship in this PR so the desktop
build doesn't render a button that opens a route nothing else is
ready for.

### Context
Architect §1, §3.1–§3.6, §4 ("the web tightening"), §5.2 (modified
files). PM §6 (mobile flow), §7 (web flow), §9 acceptance criteria.
Tenants **T-04** (accent reservation), **T-06** (touch target floor),
**T-14** (routes are addressable, scanner is intra-app only),
**T-15** (form factor branches at the screen root — `BarcodeScanButton`
hides at its own root), **T-20** (semantics on close button + camera
viewfinder), **T-23** (lifted widgets package-imported).

### Scope
- [ ] Create `lib/features/scan/scan_screen.dart` with a
      `StatefulWidget` (not `ConsumerStatefulWidget`; the scanner state
      is local). Constructor signature:
      ```dart
      const ScanScreen({super.key, this.controllerOverride});
      final MobileScannerController? controllerOverride;
      ```
      State holds `MobileScannerController _controller`, a
      `_PermissionState _permission` enum (`unknown | granted |
      denied`), and a `bool _detected` latch. Use
      `WidgetsBindingObserver` to re-attempt `controller.start()` on
      `AppLifecycleState.resumed` (per architect §3.4 / §3.9).
- [ ] Configure `MobileScannerController` (or the override) with the
      five non-negotiable settings from architect §3.5:
      ```dart
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
- [ ] Implement `_onDetect(BarcodeCapture)` per architect §3.6: latch
      check, empty-list guard, `rawValue` extraction, length floor
      (`^\d{8,14}$` — match T-021's regex on the paste path),
      `controller.stop()`, `HapticFeedback.lightImpact()`, then
      `Navigator.of(context).pop(value)`. **Do not push the resolver
      from here** — the opener does that after the route pops.
- [ ] Permission state machine: on `initState`, kick `_attemptStart()`
      which calls `controller.start()`. Catch
      `MobileScannerException` with `errorCode ==
      MobileScannerErrorCode.permissionDenied` (or
      `permissionDeniedDuringSession`) and flip `_permission =
      _PermissionState.denied`. On a denied build, render a TODO
      placeholder for now (SC-003 swaps in `PermissionDenied`).
- [ ] Wrap the camera body in `Semantics(label: 'Scan a food barcode',
      container: true, child: …)` on the `Scaffold.body`. Wrap the
      `MobileScanner` widget in `Semantics(image: true, label: 'Camera
      viewfinder, point at a barcode')`. Top-bar close button uses
      `IconButton36(icon: Icons.close, tooltip: 'Close', onPressed:
      () => Navigator.of(context).pop(null))`. No torch icon, no
      manual-entry icon — SC-003 owns those.
- [ ] Render a `Stack` containing the `MobileScanner`, a placeholder
      `SizedBox.expand()` for the viewfinder overlay (SC-002 fills),
      a placeholder `SizedBox.shrink()` for the torch slot (SC-003
      fills), and the close button. The placeholders are explicit so
      SC-002 and SC-003 land as drop-in swaps.
- [ ] Create `lib/features/scan/openers.dart` per architect §3.2–§3.3:
      ```dart
      Future<void> openBarcodeScanner(BuildContext context) async {
        if (kIsWeb) return;
        final code = await context.push<String>(Routes.foodScanPath);
        if (code == null || code.isEmpty) return;
        if (!context.mounted) return;
        await context.push('/foods/barcode/$code');
      }

      Future<String?> scanBarcode(BuildContext context) async {
        if (kIsWeb) return null;
        return context.push<String>(Routes.foodScanPath);
      }
      ```
- [ ] In `routing/routes.dart`, append after `foodBarcodePath`:
      ```dart
      static const String foodScanName = 'foods.scan';
      static const String foodScanPath = '/foods/scan';
      ```
- [ ] In `routing/app_router.dart`, register the new route inside the
      "Outside the shell" block immediately after the
      `foodBarcodeName` route:
      ```dart
      GoRoute(
        name: Routes.foodScanName,
        path: Routes.foodScanPath,
        builder: (_, __) => const ScanScreen(),
      ),
      ```
      Add the import for `package:fulfilled/features/scan/scan_screen.dart`.
- [ ] Rewrite `BarcodeScanButton`:
  - Hide rule: `if (kIsWeb) return const SizedBox.shrink();` (drop
    the `!formFactor.isCompact` half).
  - Constructor: `const BarcodeScanButton({super.key,
    this.onPressedOverride});` with `final Future<void> Function(BuildContext)?
    onPressedOverride;` (test seam — defaults null, production uses
    `openBarcodeScanner`).
  - `onTap`: `() async { final open = onPressedOverride ??
    openBarcodeScanner; await open(context); }`. **Remove the
    `HapticFeedback.selectionClick()` call** — per PM §6, haptics are
    a success signal in this feature and only fire inside
    `ScanScreen._onDetect`.
  - Rewrite the docstring per architect §4.1's comment block.
- [ ] In `search_field.dart`, swap the hint predicate from
      `context.formFactor.isExpanded` to `kIsWeb`. Update the
      docstring's T-021 paragraph to say "native mobile (iOS / Android)
      reads 'scan barcode'; all web (desktop and mobile-web Safari)
      reads 'paste a barcode'" — three-line edit.
- [ ] In `search_screen.dart`, simplify the
      `BarcodeScanButton(onScan: …)` call site to `const
      BarcodeScanButton()` and delete the unused callback. No other
      change.
- [ ] Native config (one-time):
  - `client/ios/Runner/Info.plist`: add the `NSCameraUsageDescription`
    string key per architect §5.2. If the file doesn't exist (it
    doesn't in the current repo tree), create the minimal stub —
    Flutter ships the standard scaffold elsewhere; if a future
    `flutter create` round-trip would regenerate the file, leave a
    `<!-- NSCameraUsageDescription required for the barcode scanner.
    See specs/dev_tickets_barcode.md SC-001. -->` comment above the
    key so reviewers don't strip it.
  - `client/android/app/src/main/AndroidManifest.xml`: ensure
    `<uses-permission android:name="android.permission.CAMERA" />`
    is present. The `mobile_scanner` plugin's manifest merger usually
    adds it; we add it explicitly so the dependency is auditable.
- [ ] Write the four tests listed in the Tests section. Tests are
      inspection-correct (no `flutter test` run) — match the existing
      test harness shapes in `client/test/widget/` and
      `client/test/routing/`.

### Out of scope
- The `ViewfinderOverlay` painter — SC-002.
- The torch button + no-detect hint + `PermissionDenied` widget —
  SC-003.
- The `PrimaryButton.dense` variant — SC-005.
- Any new pub dep (e.g. `permission_handler`, `app_settings`) — see
  architect risk 2; we ship without.
- A dedicated manual-entry modal sheet — SC-004 (optional follow-up,
  PMgr punted from v1 per risk 1 below).
- An accent-flash animation on decode — see risk 5; not v1.

### Acceptance criteria
- [ ] `Routes.foodScanName == 'foods.scan'` and
      `Routes.foodScanPath == '/foods/scan'`. Both are registered
      outside the `ShellRoute` in `app_router.dart`.
- [ ] `BarcodeScanButton` returns `const SizedBox.shrink()` whenever
      `kIsWeb` is true, regardless of form factor. Verified by widget
      test exercising compact, medium, and expanded widths on the
      web target.
- [ ] `BarcodeScanButton` no longer fires `HapticFeedback.selectionClick()`
      on tap. Verified by reading the rebuilt file.
- [ ] `BarcodeScanButton.onPressedOverride` is honored — when set, the
      override is called instead of `openBarcodeScanner`. Default
      production path is `openBarcodeScanner(context)`.
- [ ] `SearchField` default hint reads `"Search foods or paste a
      barcode…"` when `kIsWeb` is true, `"Search foods or scan
      barcode…"` otherwise. Verified by widget test.
- [ ] `openBarcodeScanner(context)` and `scanBarcode(context)` both
      first-line short-circuit on `kIsWeb`. Verified by unit test.
- [ ] `ScanScreen` constructed with a `controllerOverride` that
      synthesises a `BarcodeCapture` with a 13-digit
      `rawValue` calls `Navigator.pop` with the decoded string.
      Verified by widget test.
- [ ] `_onDetect` drops captures whose `rawValue` length is outside
      `[8, 14]`. Verified by widget test with an invalid-length
      fake capture.
- [ ] `MobileScannerController` is constructed with the exact
      four-element `formats` list (`ean13`, `upcA`, `ean8`, `upcE`),
      `DetectionSpeed.noDuplicates`, `detectionTimeoutMs: 250`,
      `returnImage: false`, `torchEnabled: false`. Verified by reading
      the source (no test seam touches the controller construction).
- [ ] `client/ios/Runner/Info.plist` contains the key
      `NSCameraUsageDescription` with the exact value `"Fulfilled
      needs camera access to scan food barcodes."`
- [ ] `client/android/app/src/main/AndroidManifest.xml` contains
      `<uses-permission android:name="android.permission.CAMERA" />`.
- [ ] All new Dart files live under `client/lib/features/scan/`. Zero
      cross-feature imports outside `package:fulfilled/widgets/...`
      and the routing layer. `lint_no_cross_feature_widget_import.sh`
      passes by construction.
- [ ] Tenants honored: T-04, T-06, T-14, T-15, T-20, T-23.

### Tests
- `client/test/features/scan/scan_screen_test.dart`:
  - `decode of a 13-digit barcode pops with the value` — pump
    `ScanScreen(controllerOverride: fake)`, drive an `_onDetect`
    capture from the fake, expect the route popped with the string.
  - `decode of a 7-digit value is dropped (length floor)`.
  - `decode of an empty rawValue is dropped`.
  - `close button pops with null` — find the
    `IconButton36(tooltip: 'Close')`, `tester.tap`, expect pop with
    `null`.
  - `route Semantics labels are wired` — assert the route container
    label is `'Scan a food barcode'` and the camera viewfinder is
    `Semantics(image: true)`.
- `client/test/features/scan/openers_test.dart`:
  - `openBarcodeScanner short-circuits on kIsWeb` — `debugDefaultTargetPlatformOverride`
    + a test harness that forces `kIsWeb`. The function returns
    immediately without pushing.
  - `scanBarcode short-circuits on kIsWeb`.
- `client/test/features/search/barcode_scan_button_test.dart`:
  - `hides on web (compact, medium, expanded widths)` — pump in a
    `MediaQuery` with the relevant widths and a `kIsWeb`-forced
    test target, expect `SizedBox.shrink()`.
  - `renders on native mobile compact + medium + expanded` — same
    matrix on the non-web target, expect the 44×44 button.
  - `onPressedOverride is invoked on tap` — pass a counting stub,
    tap the button, expect the stub called once.
  - `no HapticFeedback fired on tap` — wrap `HapticFeedback` in a
    test mock channel that asserts no `selectionClick` invocation.
- `client/test/features/search/search_field_hint_test.dart`:
  - `default hint reads "scan barcode" on native mobile`.
  - `default hint reads "paste a barcode" on kIsWeb`.
  - `explicit hintText override wins on both targets`.

### Notes / gotchas
- The architect's "the route is non-deep-linkable in spirit" call
  (§3.1) is honoured by the `kIsWeb` gate on the opener and the
  feature isolation of `ScanScreen`; we do **not** block direct
  `/foods/scan` navigation at the router level.
- `iOS/Runner/Info.plist` and `android/app/src/main/AndroidManifest.xml`
  don't currently exist in this repo (Flutter scaffold wasn't
  checked in). If the file doesn't exist when you start, create the
  minimal viable version with **just** the camera-permission entry
  and leave a TODO marker for the broader Flutter scaffold. **Do
  not** generate a full Flutter iOS scaffold — that's outside scope.
- `BarcodeScanButton.onPressedOverride`'s signature is
  `Future<void> Function(BuildContext)?` — note the `BuildContext`
  param. Matches the `openBarcodeScanner` signature exactly so the
  default-or-override line `(onPressedOverride ?? openBarcodeScanner)(context)`
  type-checks cleanly.
- If `mobile_scanner` 5.2.3 doesn't surface a
  `MobileScannerErrorCode.permissionDeniedDuringSession` enum
  variant by that exact name in the version on `pubspec.yaml`, treat
  the single `permissionDenied` code as the catch-all. SC-003 lands
  the user-facing surface so the difference is invisible here.

---

## SC-002  `ViewfinderOverlay` painter + iPad-landscape cap

**Status**: pending
**Priority**: P1
**Effort**: S
**Depends on**: SC-001 (touches `scan_screen.dart`'s placeholder slot)
**Owns files**:
- `client/lib/features/scan/widgets/viewfinder_overlay.dart` (new —
  `ViewfinderOverlay` `StatelessWidget` + `_ViewfinderPainter`
  `CustomPainter`)
- `client/lib/features/scan/scan_screen.dart` (one-line swap of the
  placeholder `SizedBox.expand()` for `const ViewfinderOverlay()`;
  one-line import addition)
- `client/test/widget/viewfinder_overlay_test.dart` (new — geometry,
  token discipline, cap-at-320 on expanded)

### Goal
Ship the dim-around-a-rounded-square reticle the PM specified. A
`CustomPaint` that fills the camera surface with a 55%-opacity ink
overlay and punches out a centered `RRect` of side `min(width,
height) * 0.70`, capped at 320 px on the longer axis (iPad
landscape). Edge stroke is `surface` (T-04: not accent).

### Context
Architect §3.7, §5.1, §6 risk 3 (iPad-landscape cap — now an
acceptance criterion). PM §3 principle 1, §6 "Where the scanner
mounts". Tenants **T-01** (token discipline — `colors.ink` /
`colors.surface`, opacity numbers permitted on tokens), **T-04**
(accent reservation — the edge stroke is **not** accent), **T-15**
(no platform branch in a leaf — geometry is data-driven on viewport
size, not on form factor).

### Scope
- [ ] Create
      `client/lib/features/scan/widgets/viewfinder_overlay.dart` with
      a `StatelessWidget`:
      ```dart
      class ViewfinderOverlay extends StatelessWidget {
        const ViewfinderOverlay({super.key, this.cornerRadius});
        final double? cornerRadius;
      }
      ```
      `build` returns a `CustomPaint(painter: _ViewfinderPainter(...),
      size: Size.infinite)`. Painter constructor takes the dim color
      (`context.colors.ink.withOpacity(0.55)`), the edge color
      (`context.colors.surface`), and the corner radius (`cornerRadius
      ?? context.radius.r3`).
- [ ] `_ViewfinderPainter.paint` per architect §3.7:
  1. Reads the canvas clip rect for the viewport size.
  2. Computes `final shorter = math.min(size.width, size.height);`
     then `final cutoutSide = math.min(shorter * 0.70, 320.0);`.
     **The cap at 320 px is the resolution of architect risk 3** —
     keeps the viewfinder phone-sized on iPad landscape (the
     1024-wide canvas would otherwise produce a ~717 px cutout).
  3. Builds an `evenOdd`-filled `Path` = outer rect minus a centered
     `RRect.fromRectAndRadius(centerSquare, Radius.circular(radius))`.
  4. Fills the path with the dim color.
  5. Strokes the centered `RRect` with a 1.5 px line in the edge
     color so the cutout is crisp against dark camera frames.
- [ ] `shouldRepaint` returns true only when the dim color, edge
      color, or radius differ — `_ViewfinderPainter` is `const`-friendly
      and the parent doesn't rebuild on camera frames.
- [ ] In `scan_screen.dart`, replace the SC-001 placeholder
      `SizedBox.expand()` slot in the `Stack` with `const
      ViewfinderOverlay()`. Add the import. No other change.
- [ ] Token discipline: zero raw hex. Opacity values (`0.55`, `1.5`
      stroke width) are numeric and live in the painter, **not** in
      a token file — same pattern `MacroBar` uses for `colors.line2`
      opacity. The 320 px cap is a named constant
      `_kMaxCutoutSideExpanded` at the top of the painter file with
      a doc comment citing this ticket.

### Out of scope
- An accent-flash animation on decode (architect risk 5 — dropped
  per the PMgr ruling below).
- Bracketed corners (Yuka-style four-corner accents) — PM §3
  principle 1 named them, architect §3.7 didn't ship them, PMgr
  agrees with the architect (a clean rounded square reads as a
  viewfinder without consuming the accent budget).
- Torch / hint / permission widgets — SC-003.
- Animation of any kind — the painter is static.

### Acceptance criteria
- [ ] `ViewfinderOverlay` is a `StatelessWidget` with a single
      optional `cornerRadius` constructor param.
- [ ] On a 390 × 844 viewport (iPhone 13 portrait), the cutout side
      is `390 * 0.70 = 273`.
- [ ] On a 1024 × 768 viewport (iPad landscape), the cutout side is
      capped at **320 px** (would be `768 * 0.70 = 537.6` uncapped).
      Resolves architect risk 3.
- [ ] On a 768 × 1024 viewport (iPad portrait), the cutout side is
      `768 * 0.70 = 537.6` — uncapped because the shorter side is the
      width, which is below `320 / 0.70 ≈ 457`. Verified by widget
      test.
- [ ] The dim fill is `colors.ink` at `0.55` opacity. The cutout
      edge stroke is `colors.surface` at 1.5 px. No raw hex anywhere
      in the file. `lint_no_hex_outside_tokens.sh` passes.
- [ ] The cutout edge is **not** `colors.accent`. T-04 holds.
- [ ] `scan_screen.dart`'s `Stack` now hosts a `ViewfinderOverlay`
      between the `MobileScanner` and the top-bar buttons. No other
      change to `scan_screen.dart`.
- [ ] Tenants honored: T-01, T-04, T-15.

### Tests
- `client/test/widget/viewfinder_overlay_test.dart`:
  - `cutout side at 390 × 844 is 273` — pump in a `SizedBox(width:
    390, height: 844)`, read the painter's computed geometry via a
    test-only debug seam (e.g. a `@visibleForTesting` static helper
    on `_ViewfinderPainter` that takes a `Size` and returns the
    cutout `Rect`).
  - `cutout side at 1024 × 768 is capped at 320` — same harness,
    landscape iPad viewport.
  - `cutout side at 768 × 1024 is 537.6` — iPad portrait, uncapped.
  - `dim fill uses colors.ink, not Colors.black` — verify the
    painter receives a token-derived color (golden-image-style
    pixel check on a deterministic canvas).
  - `edge stroke is surface, not accent` — same pattern.

### Notes / gotchas
- The 320 px cap is the resolution of architect risk 3. The PMgr
  agrees with the architect's recommendation: 320 px keeps the
  viewfinder phone-sized regardless of viewport, which matches the
  PM §6 mental model ("a rectangular viewfinder centered on the
  screen tells the user where to aim").
- The painter's `cornerRadius` param defaults to `null` and falls
  back to `context.radius.r3` — passed through the `StatelessWidget`'s
  `build` method, since `CustomPainter` itself doesn't have a
  `BuildContext`. The widget reads the token and passes the resolved
  `double` into the painter constructor.
- Do **not** read `MediaQuery.of(context)` inside the painter. The
  `Canvas`'s clip-rect (via the `size` param to `paint`) is the
  authority on viewport. Reading `MediaQuery` from a painter is a
  rebuild trap.

---

## SC-003  Torch button + no-detect hint + `PermissionDenied` empty state

**Status**: pending
**Priority**: P1
**Effort**: M
**Depends on**: SC-001 (touches `scan_screen.dart`'s placeholder slots
+ permission-state-machine branch)
**Owns files**:
- `client/lib/features/scan/widgets/scan_torch_button.dart` (new —
  feature-private `_ScanTorchButton` bound to
  `MobileScannerController.torchState` + `.hasTorch`)
- `client/lib/features/scan/widgets/no_detect_hint.dart` (new —
  `NoDetectHint` `StatelessWidget` with two `PrimaryButton`s)
- `client/lib/features/scan/widgets/permission_denied.dart` (new —
  `PermissionDenied` wrapper around `EmptyState` with a "Try again"
  CTA)
- `client/lib/features/scan/scan_screen.dart` (wire all three widgets
  into the existing `Stack` + state machine; arm the 10-second
  no-detect timer in `initState`; render `PermissionDenied` in place
  of the camera when `_permission == denied`; ~40-line diff)
- `client/test/widget/no_detect_hint_test.dart` (new)
- `client/test/widget/permission_denied_test.dart` (new)
- `client/test/features/scan/scan_screen_polish_test.dart` (new —
  torch hide on `hasTorch == false`; hint slides in at 10 s; "Try
  again" wiring)

### Goal
Fill in the three polish surfaces SC-001 stubbed: torch toggle (top-
right; hidden on devices without a torch), no-detect hint at the
10-second mark with "Type the barcode" + "Add a custom food" actions,
and the `PermissionDenied` empty state that replaces the camera when
the OS denies access. After this ticket, the scanner route renders
exactly the surfaces PM §6 specified.

### Context
Architect §3.8 (torch), §3.9 (permission), §3.10 (no-detect hint).
PM §3 principles 4 / 5 / 6, §6 "Torch" / "Permission first-run +
recovery" / "Bad-light no-detect timeout". Tenants **T-01** (tokens),
**T-06** (touch targets — `IconButton36` enforces ≥ 44 px hit slop),
**T-11** (errors inline — `PermissionDenied` is an inline empty
state, not a modal), **T-15** (no platform branch in leaves),
**T-20** (semantics: torch announces toggled state; hint is a live
region).

### Scope
- [ ] Create
      `client/lib/features/scan/widgets/scan_torch_button.dart` per
      architect §3.8:
      ```dart
      class _ScanTorchButton extends StatelessWidget {
        const _ScanTorchButton({required this.controller});
        final MobileScannerController controller;
      }
      ```
      `build` wraps a `ValueListenableBuilder<TorchState>` reading
      `controller.torchState`; renders `IconButton36(icon:
      on ? Icons.flash_on_outlined : Icons.flash_off_outlined,
      tooltip: on ? 'Turn flash off' : 'Turn flash on', onPressed: ()
      => unawaited(controller.toggleTorch()))`. The button is
      additionally wrapped in a second `ValueListenableBuilder<bool>`
      that reads `controller.hasTorch`; when `false`, returns
      `SizedBox.shrink()`. Underscore-prefixed class — feature-
      private; only `ScanScreen` ever instantiates it. Add a 24 px
      translucent-surface backdrop (`Container` with
      `colors.surface.withOpacity(0.18)`, `borderRadius: rPill`) per
      architect §3.8 so the icon is legible over arbitrary camera
      content.
- [ ] Wrap the button in `Semantics(label: 'Camera light', toggled:
      on)` so screen readers announce the on/off state.
- [ ] Create
      `client/lib/features/scan/widgets/no_detect_hint.dart` per
      architect §3.10:
      ```dart
      class NoDetectHint extends StatelessWidget {
        const NoDetectHint({
          super.key,
          required this.onType,
          required this.onAddCustom,
        });
        final VoidCallback onType;
        final VoidCallback onAddCustom;
      }
      ```
      Visual: a 64-px-tall band, `colors.surface` at 0.92 opacity,
      top edge `colors.line`, slid in from the bottom on a 220 ms
      cubic-out animation. Contents: title "Trouble scanning?" in
      `text.bodyStrong`, subtitle "Try a different angle or…" in
      `text.meta`, then a `Row` with two `PrimaryButton(dense: true,
      label: ..., onPressed: ...)` widgets — "Type the barcode" and
      "Add a custom food". Wrap the whole band in
      `Semantics(liveRegion: true, container: true)` so screen
      readers announce its appearance.
- [ ] Create
      `client/lib/features/scan/widgets/permission_denied.dart` per
      architect §3.9:
      ```dart
      class PermissionDenied extends StatelessWidget {
        const PermissionDenied({super.key, required this.onRetry});
        final VoidCallback onRetry;
      }
      ```
      Returns an `EmptyState(icon: Icons.no_photography_outlined,
      title: 'Camera access is off', body: 'Turn on the camera to
      scan barcodes.\nOpen Settings → Privacy → Camera → Fulfilled,
      then tap Try again.', action: SizedBox(width: 200, child:
      PrimaryButton(label: 'Try again', onPressed: onRetry)))`. No
      deep-link to Settings (no `app_settings` / `permission_handler`
      dep — see risk 2 below).
- [ ] In `scan_screen.dart`:
  - In `initState`, arm a `Timer(const Duration(seconds: 10), () {
    if (!mounted) return; setState(() => _showHint = true); });`.
    Cancel the timer in `_onDetect` and in `dispose`. Cancel +
    re-arm when the timer fires after a brief no-detect window
    is **not** required — PM §6 says the hint stays visible until
    manual entry or successful detect.
  - In `dispose`, also call `_controller.dispose()` and unregister
    the `WidgetsBindingObserver`.
  - In `build`, swap the SC-001 torch placeholder for the real
    `_ScanTorchButton(controller: _controller)` in the top-bar
    `Row`.
  - In `build`, swap the SC-001 viewfinder placeholder treatment for
    a `Stack` child at the bottom that conditionally renders
    `NoDetectHint(onType: _onType, onAddCustom: _onAddCustom)` when
    `_showHint == true`. The `Stack` ordering: camera, viewfinder
    (from SC-002), top bar, hint.
  - When `_permission == _PermissionState.denied`, replace the
    `Stack` body with `PermissionDenied(onRetry: _attemptStart)`.
    `_attemptStart` re-runs the controller `start()` and updates
    `_permission` on the outcome.
  - `_onType` pops the route with `null` and pushes
    `/foods/search` (so the user lands on the search screen with the
    paste-a-barcode field — the T-021 path is the manual-entry
    surface for v1 per risk 1 below). Implementation:
    `Navigator.of(context).pop(null); context.push(Routes.foodsSearchPath);`.
  - `_onAddCustom` pops the route with `null` and pushes
    `/foods/new`. The custom-food form's barcode field is empty;
    the user fills it manually.
- [ ] Add `PrimaryButton(dense: true)` support **only if** SC-005
      has merged. If SC-005 is not yet in, fall back to the default
      54-px `PrimaryButton` height (the hint band's 64-px container
      will visually crop, which is acceptable for the interim — the
      buttons remain functional). The acceptance criterion below
      assumes SC-005 has merged.

### Out of scope
- A dedicated modal manual-entry sheet — SC-004 (optional).
- A keyboard `IconButton36` in the top bar — SC-004.
- An "Open settings" deep-link to per-app permission screen — see
  risk 2; we ship without a pub dep.
- An accent-flash animation on decode — risk 5; dropped.
- Persisting torch state across route pushes (PM §6 said reset on
  dispose, which is what the default controller construction in
  SC-001 already does).

### Acceptance criteria
- [ ] The torch button renders in the top-right of the scanner route
      when `controller.hasTorch == true`, and as `SizedBox.shrink()`
      when `false`. Verified by widget test with a fake controller.
- [ ] Tapping the torch button calls
      `controller.toggleTorch()`. Verified by widget test.
- [ ] The torch button's `Semantics(toggled: state)` flips with the
      controller's `torchState`. Verified by widget test.
- [ ] After 10 seconds of contiguous no-decode, the `NoDetectHint`
      slides in from the bottom. Verified by widget test with
      `fakeAsync` + a controller override that never emits.
- [ ] On a successful decode, the hint timer is cancelled and the
      hint never appears (the route pops first). Verified by widget
      test.
- [ ] Tapping "Type the barcode" pops the scanner and pushes
      `/foods/search`. Tapping "Add a custom food" pops and pushes
      `/foods/new`. Verified by widget tests with a navigation
      observer.
- [ ] When the controller's `start()` throws
      `MobileScannerException(errorCode: permissionDenied)`,
      `ScanScreen` renders `PermissionDenied` in place of the
      camera. Tapping "Try again" re-attempts `start()`.
- [ ] The "Type the barcode" / "Add a custom food" buttons use
      `PrimaryButton(dense: true)` — relies on SC-005 having merged.
- [ ] No new pub dep added (`permission_handler` / `app_settings`
      stay out of `pubspec.yaml`). Resolves architect risk 2 per
      PMgr ruling below.
- [ ] Tenants honored: T-01, T-06, T-11, T-15, T-20.

### Tests
- `client/test/widget/no_detect_hint_test.dart`:
  - `renders title + subtitle + two PrimaryButtons`.
  - `onType callback fires on type-button tap`.
  - `onAddCustom callback fires on add-custom-button tap`.
  - `Semantics liveRegion is set` — assertion via
    `tester.getSemantics(find.byType(NoDetectHint))`.
- `client/test/widget/permission_denied_test.dart`:
  - `renders EmptyState with the documented copy`.
  - `Try again button fires onRetry`.
- `client/test/features/scan/scan_screen_polish_test.dart`:
  - `torch hidden when hasTorch is false`.
  - `torch toggles controller.torchState on tap`.
  - `no-detect hint appears after 10 seconds` —
    `fakeAsync`-driven; `tester.pump(const Duration(seconds: 10))`.
  - `successful decode cancels the no-detect timer`.
  - `hint Type-the-barcode tap pops + pushes /foods/search`.
  - `hint Add-a-custom-food tap pops + pushes /foods/new`.
  - `permission denied renders PermissionDenied`.
  - `Try again re-attempts controller.start()`.

### Notes / gotchas
- The torch button must read **both** `hasTorch` and `torchState` —
  the first decides whether to render at all, the second decides
  which icon to show. Two `ValueListenableBuilder`s nested is fine;
  the controller emits these as `ValueNotifier`s.
- The 10-second `Timer` must be cancelled in `dispose` to avoid
  the "called setState after dispose" lint. Same pattern as
  `LogEntrySheet`'s submit timer.
- `_onType`'s `Navigator.pop` + `context.push` happens in the same
  frame — guard with `if (!mounted) return;` after the pop, even
  though `pop` doesn't unmount the parent (the `await context.push`
  in `openBarcodeScanner` is what unmounts).
- The architect noted that `mobile_scanner` 5.2.3's
  `MobileScannerException.errorCode` may use either
  `permissionDenied` or `permissionDeniedDuringSession`. Treat both
  as denied; same rendering path.

---

## SC-004  *(deferred to v1.1)* Dedicated manual-entry modal sheet

**Status**: pending-pm (deferred; see risk 1)
**Priority**: P2
**Effort**: S
**Depends on**: SC-001, SC-003
**Owns files** (when picked up):
- `client/lib/features/scan/widgets/manual_entry_sheet.dart` (new)
- `client/lib/features/scan/scan_screen.dart` (add a keyboard
  `IconButton36` in the top bar between close and torch; wire the
  sheet)
- `client/test/widget/manual_entry_sheet_test.dart` (new)

### Goal
Ship the dedicated modal manual-entry sheet PM §6 sketched — a
single-field `TextField` (digits-only, 8–14 chars) with a "Look up"
`PrimaryButton`, opened from a new top-bar keyboard `IconButton36`
between close and torch. On submit, pop the scanner and push
`/foods/barcode/$value`.

### Context
PM §3 principle 6 ("Manual entry is the screen-reader path"), PM §6
"Manual entry". Architect §6 risk 1 — flagged for the PMgr to
decide v1 vs. v1.1.

### Out of scope
- See SC-001 / SC-002 / SC-003 — those ship first.

### PMgr ruling
**Loose reading for v1.** Per architect risk 1 / PMgr decision below.
The SC-003 no-detect hint's "Type the barcode" button covers the
10-second-no-decode escape hatch the PM named as the critical
seam. The dedicated modal + top-bar keyboard icon is incremental
work that does **not** block the burrito-shop happy path. Land
SC-001..SC-003 first; pick this up only if user-testing or a
follow-up PM ruling moves the bar.

### Notes / gotchas
- The screen-reader path in v1 is the search-screen paste field
  (T-021) reached via the SC-003 no-detect hint. That is a degraded
  experience compared to PM §3 principle 7's spec (manual entry as
  the first focusable element after the close button); we accept the
  degradation for v1 and flag it here.
- If the user wants this in v1 instead of v1.1, the work is small:
  ~80-line `manual_entry_sheet.dart`, one new `IconButton36`
  insertion in `scan_screen.dart`'s top `Row`, one new test file.
  The Type-the-barcode no-detect-hint button can stay (it remains
  the recovery for users who don't notice the top-bar icon) or
  flip to opening the sheet directly.

---

## SC-005  `PrimaryButton.dense` size variant

**Status**: pending
**Priority**: P1
**Effort**: S
**Depends on**: none
**Owns files**:
- `client/lib/widgets/primary_button.dart` (add `dense: bool` param;
  44 px height when true, 54 px height when false; font size
  `text.body` when dense, `text.bodyStrong` when default)
- `client/test/widget/primary_button_dense_test.dart` (new)

### Goal
Add a `dense: bool` constructor parameter to `PrimaryButton` so SC-003's
`NoDetectHint` can fit two side-by-side actions in a 64-px-tall band.
Purely additive — every existing call site keeps its current 54-px
visual.

### Context
Architect §6 risk 4. PM §3 principle 6 specifies "Two text actions,
both `PrimaryButton`s in compact size." The existing `PrimaryButton`
is the 54-px sticky-CTA shape; it does **not** today expose a dense
variant.

### Scope
- [ ] Add a `bool dense = false` constructor param to `PrimaryButton`.
- [ ] When `dense == true`:
  - Height: 44 px (vs. 54 px default).
  - Font size: `context.text.body` (vs. `context.text.bodyStrong`).
  - Horizontal padding: `context.space.x3` (vs. `context.space.x4`).
  - Loading-spinner size: 16 px (vs. 20 px).
- [ ] Other props (label, onPressed, isLoading, isDestructive) are
      unchanged. Same `Semantics` shape.
- [ ] Update the widget's class doc-comment with a "Dense variant:
      44 px height for in-content actions where the standard 54 px
      sticky-CTA shape would crowd surrounding content. Used by
      `NoDetectHint` in the scanner route." paragraph.

### Out of scope
- A separate `PrimaryButton.tonal` or `PrimaryButton.outlined`
  variant (different tickets if ever needed).
- Migrating any existing call site to `dense: true`. The variant is
  additive; SC-003 is the only consumer in this pool.
- Animating the size swap.

### Acceptance criteria
- [ ] `PrimaryButton(label: 'X', onPressed: () {})` renders at the
      same height it always has (54 px). Visual-regression-style
      test against a deterministic golden harness.
- [ ] `PrimaryButton(label: 'X', dense: true, onPressed: () {})`
      renders at 44 px height with `text.body` font size.
- [ ] `isLoading` + `dense: true` shows the 16-px spinner.
- [ ] Tenants honored: T-06 (44 px is still the floor on the dense
      variant), T-01 (tokens).

### Tests
- `client/test/widget/primary_button_dense_test.dart`:
  - `default height is 54` — pump, measure.
  - `dense: true height is 44`.
  - `dense: true font size matches text.body`.
  - `isLoading + dense renders a 16-px spinner`.
  - `Semantics label is the button label in both variants`.

### Notes / gotchas
- This is the resolution of architect risk 4. The PMgr bundles it as
  a standalone ticket (not "while you're there" inside SC-003)
  because the file lives in `lib/widgets/` outside the
  `features/scan/` folder, which would otherwise pull SC-003 across
  feature boundaries. Two separate tickets is the cleaner split.
- SC-003 has a soft dependency on this ticket — if SC-005 lands
  after SC-003, the hint band ships with two default-height (54 px)
  buttons in a 64-px container and the visual is cramped but
  functional. Prefer landing SC-005 first in the dispatch order
  below.

---

## Dependency graph

```mermaid
flowchart TD
  SC001[SC-001 ScanScreen skeleton + opener + routing + native config]
  SC002[SC-002 ViewfinderOverlay painter + iPad cap]
  SC003[SC-003 Torch + no-detect hint + PermissionDenied]
  SC004[SC-004 v1.1 deferred — manual-entry modal sheet]
  SC005[SC-005 PrimaryButton.dense variant]

  SC001 --> SC002
  SC001 --> SC003
  SC005 --> SC003
  SC001 -. v1.1 .-> SC004
  SC003 -. v1.1 .-> SC004
```

**Wave 1 (no client-side deps, dispatch immediately in parallel)**:
SC-001, SC-005. The two tickets touch entirely disjoint files
(`features/scan/` + `features/search/` + routing + native config
vs. `widgets/primary_button.dart`).

**Wave 2 (after SC-001 lands)**: SC-002 and SC-003 — both touch
`scan_screen.dart`'s placeholder slots. They can run in parallel
on top of SC-001 because the placeholders are spatially separate
(SC-002 swaps the viewfinder slot; SC-003 swaps the torch /
no-detect / permission slots and adds the timer / permission
state-machine wiring). A small merge-conflict in `scan_screen.dart`
is the only risk; the diffs are otherwise disjoint.

**Wave 3 (deferred)**: SC-004 only if the PMgr flips risk 1 from
"loose reading" to "tight reading." Not v1.

### Strict serial constraints (sequential, NOT parallel)

- **SC-001 before SC-002 and SC-003** — both Wave-2 tickets depend on
  the placeholder slots SC-001 lands.
- **SC-005 before SC-003** (soft) — landing SC-005 first lets SC-003
  ship the no-detect hint with the intended dense-variant buttons.
  If SC-005 slips, SC-003 can ship with the default 54-px
  `PrimaryButton` and SC-005 lands as a follow-up swap.

---

## Dispatch plan

### Wave 1 — dispatch immediately in parallel

- **SC-001** — `ScanScreen` skeleton + opener + button rewrite + web
  hide tightening + routing wire + native config. (L, the spine of
  the feature.)
- **SC-005** — `PrimaryButton.dense` size variant. (S, unblocks
  SC-003.)

The two tickets touch entirely disjoint files. Two agents in
parallel.

### Wave 2 — dispatch when Wave 1 lands

- **SC-002** — `ViewfinderOverlay` painter + iPad-landscape cap.
  (After SC-001 — depends on the placeholder slot in
  `scan_screen.dart`.)
- **SC-003** — Torch + no-detect hint + `PermissionDenied`.
  (After SC-001 + SC-005.)

SC-002 and SC-003 can run in parallel. Both edit `scan_screen.dart`;
the diffs are spatially disjoint (overlay slot vs. top-bar / hint /
permission branches) but if both land before either is reviewed,
the second author rebases. Prefer landing SC-002 first since it's
the smaller diff and SC-003's tests benefit from being able to see
the real viewfinder in golden-image debugging.

### Wave 3 — deferred

- **SC-004** — Dedicated manual-entry modal sheet. Only if the PMgr
  flips risk 1.

### Total ticket count

**5 tickets** (SC-001 through SC-005). One is deferred (SC-004); four
ship in v1. The architect's A/B/C split is preserved (SC-001 is "A",
SC-002 is "B", SC-003 is "C"); SC-005 is the bundled `PrimaryButton.dense`
work (architect risk 4) carved out so SC-003 can stay inside its
feature folder.

### Pre-backend window

**N/A.** This feature has no backend dependency. PM §8 flagged
**BE-002** (server-side OFF live fallback on cache miss) and
**BE-003** (server-side EAN-13 normalization on the wire) as
optional backend improvements; both are explicitly out of scope here
and ship independently if at all. The client work ships against the
existing `GET /foods/barcode/{barcode}` endpoint without change.

---

## Architect's 5 flagged risks → PMgr resolution

The architect (§6) listed five open items. PMgr resolution below;
each is also reflected in the ticket scope where relevant.

### 1. Manual-entry surface — tight vs. loose reading

**PMgr ruling: loose reading for v1.** The no-detect hint's "Type
the barcode" button (SC-003) routes to `/foods/search` where the
T-021 paste-a-barcode field already fires the same resolver. That
covers the 10-second-no-decode escape hatch PM §3 principle 6
named.

**Reasoning:** The dedicated modal sheet + top-bar keyboard
`IconButton36` is incremental scope that does **not** block the
burrito-shop happy path. PM §3 principle 7 specifies manual entry
as the screen-reader path "always one tap away from the scanner
route's top-bar" — that's a real spec point and the loose reading
degrades it. The PMgr's call: a degraded screen-reader path in v1
is acceptable because (a) the search-screen paste field is fully
accessible and reachable in two taps via the hint, (b) Yuka and OFF
both ship full-screen scanners as the screen-reader-meaningful
surface (manual entry is not their primary path either), and (c)
the cost of adding the sheet in a follow-up is small (~80 lines,
flagged as **SC-004** with a v1.1 status).

If the user disagrees and wants the tight reading in v1, flip
SC-004's status from `pending-pm` to `pending` and the work
slots into Wave 2 alongside SC-002 / SC-003. Cost: one extra ticket,
no rework of SC-001..SC-003.

### 2. `permission_handler` / `app_settings` dep — for or against

**PMgr ruling: confirm the architect's call. No new pub dep in v1.**

**Reasoning:** `mobile_scanner` 5.2.3 already surfaces denial via
`MobileScannerErrorCode.permissionDenied`. The cost of a new dep
(maintenance, ~50 KB on Android, native channel registration) is
non-zero and the buy is a one-tap "Open Settings" deep-link.
`PermissionDenied`'s body copy gives the user the manual path
("Open Settings → Privacy → Camera → Fulfilled, then tap Try
again") — same recovery copy MyFitnessPal ships per PM §2. If
user testing shows the manual path is a meaningful drop-off, swap
in `app_settings: ^5.1.1` as a one-line `pubspec.yaml` change
and one new tap target in `PermissionDenied`. Five-line diff;
unblocks v1.1.

Reflected in SC-003 — no dep added, no Settings deep-link.

### 3. iPad landscape viewfinder cap at 320 px

**PMgr ruling: convert to acceptance criterion on SC-002.** Done —
see SC-002's acceptance criteria: "On a 1024 × 768 viewport (iPad
landscape), the cutout side is capped at 320 px." The cap is
implemented as `math.min(shorter * 0.70, 320.0)` in
`_ViewfinderPainter`.

**Reasoning:** A 717 px viewfinder on iPad landscape is awkward for
hand-held scanning (the user has to back the camera off the package
by ~30 cm to fit the EAN-13). 320 px keeps the affordance phone-
sized regardless of viewport; that matches PM §6's mental model.

### 4. `PrimaryButton.dense` variant — bundle or punt

**PMgr ruling: standalone ticket (SC-005).** Carve out the
`PrimaryButton.dense` work because the file lives in `lib/widgets/`
outside the `features/scan/` folder, and bundling it into SC-003
would pull SC-003 across feature boundaries (mild T-23 friction).
SC-005 is small (S effort), unblocks SC-003, and the variant is
generally useful (the LogEntrySheet's quick-multiplier chips
arguably want it in a follow-up).

Dispatch SC-005 in Wave 1 alongside SC-001 so it lands before
SC-003 starts.

### 5. Accent flash on decode — v1 or v1.1?

**PMgr ruling: confirm the architect's drop. Not v1.**

**Reasoning:** The route pops within ~50 ms of the haptic firing
(per SC-001's `_onDetect` ordering: `controller.stop()` →
`HapticFeedback.lightImpact()` → `Navigator.pop`). The user
perceives less than the 120 ms PM §3 principle 3 specified for the
flash; the haptic is the dominant feedback in practice. The visual
is gravy that ~75% of users will never see because the route's
already gone.

If user testing surfaces "the scanner felt like it didn't
recognize my barcode" complaints, add an
`AnimationController`-driven highlight fired before the pop. ~40
lines per architect; trivial v1.1.

---

## Definition of done

When all SC tickets ship (SC-001..SC-003 + SC-005, with SC-004
deferred), the user should see:

**On native mobile (iOS / Android, any width):**

- Tapping the barcode-square icon next to the search field on
  screen 02 opens a full-screen camera scanner route.
- The route has a dim overlay around a centered rounded-square
  viewfinder (~273 px on phones, capped at 320 px on iPad
  landscape).
- A close button (top-left) and a torch toggle (top-right, hidden
  on devices without a torch) sit over the camera. Tapping the
  torch flips the device flashlight; the icon updates.
- Aiming at an EAN-13 / UPC-A / EAN-8 / UPC-E barcode decodes the
  value in under two seconds in typical lighting. The scanner
  haptic-pulses (light impact), pauses the camera, pops itself,
  and the existing resolver pushes the user to the food-detail
  page (200) or the custom-food creation form with the barcode
  prefilled (404).
- After 10 seconds without a successful decode, a 64-px hint band
  slides in from the bottom: "Trouble scanning? Try a different
  angle or… [Type the barcode] [Add a custom food]". Tapping
  "Type the barcode" pops the scanner and lands on the search
  screen with the paste field ready. Tapping "Add a custom food"
  pops and lands on the custom-food creation form.
- If the OS denies camera permission, the route renders an inline
  "Camera access is off" empty state with a "Try again" button
  (no deep-link to Settings — the body copy walks the user to the
  Settings → Privacy → Camera path manually).
- VoiceOver announces "Scan a food barcode" on route entry, the
  camera viewfinder as a `Semantics.image`, the close and torch
  buttons by their tooltips (torch announces its toggled state).

**On all web (desktop and mobile-web Safari, any width):**

- The barcode icon button is hidden from the search bar entirely
  (no compact-mobile-web button rendering a route the platform
  can't satisfy).
- The search field's hint reads "Search foods or paste a
  barcode…" — guiding the user to the T-021 paste affordance.
- A user who pastes a `^\d{8,14}$` value into the search field
  sees the existing "Look up barcode … →" affordance and resolves
  through the same backend endpoint.

**Tenants:**

- No new tenants. T-04 (accent reservation — viewfinder edge is
  surface), T-06 (touch targets — `IconButton36` floor), T-11
  (inline errors — `PermissionDenied` is an empty state, not a
  dialog), T-14 (routes vs. sheets — scanner is a route by full-
  screen / camera-permission considerations), T-15 (form factor at
  the screen root — `BarcodeScanButton.build` decides at its own
  root), T-20 (accessibility — semantics on every interactive
  surface), T-23 (lifted widgets package-imported) all hold.

**Backend:**

- No client-blocking change. The two flagged backend tickets
  (BE-002 server-side OFF live fallback, BE-003 server-side
  EAN-13 normalization) ship independently when the user
  prioritises them; the client is no-op-ready for both.

**Deploy:**

- The GitHub Pages deploy at
  `https://sdstolworthy.github.io/fulfilled/app/` stays green
  through the SC pool. (Web bundle size unchanged or smaller —
  `BarcodeScanButton` collapses to `SizedBox.shrink()` on web; the
  new `lib/features/scan/` files are tree-shaken from the web
  bundle by the `kIsWeb` short-circuit in
  `openBarcodeScanner`.)
- This `dev_tickets_barcode.md` reflects the final state: every
  shipped ticket has `Status: done`; SC-004 stays `pending-pm` if
  the PMgr ruling stands.

---

## Failure protocol

A ticket may fail mid-session. The protocol:

1. **Do not commit partial work** that puts the tree in a broken
   state. Agents don't run `flutter analyze` / `flutter test`, but
   a half-deleted file or an unresolved import is obvious on
   inspection — leave the workspace clean.
2. **Update the ticket Status** to `blocked-needs-pm` in this doc.
3. **Write the failure mode in the ticket's Notes / gotchas
   section**, briefly:
   - What you tried.
   - What broke (compile error, missing dependency, ambiguous
     spec, etc.).
   - What a follow-up agent or human reviewer should look at next.
4. **Move on** to the next available ticket in the pool. Do not
   keep retrying.
5. **Do not block other tickets** waiting for the blocked one. If
   downstream tickets can proceed without the blocked work, run
   them (the dependency graph above is the authority).

A ticket that succeeds: update Status to `done`, commit the work
with a message referencing the ticket ID (`SC-NNN: <short title>`),
and the next agent will move on.

A ticket that succeeds *but* surfaces follow-up work for v1.1: add
a new ticket at the bottom of this doc with `Status: pending-pm`
and a brief note. Do not silently expand the current ticket's
scope.
