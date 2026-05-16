# PM Requirements: Barcode scanning (mobile camera + web parity)

The user asked us to actually scope the barcode-scanner feature instead of
hand-waving at the existing `TODO(scan)` stub. This doc does that. It is
the contract for the implementation of the mobile camera-capture
experience and the (small) web companion change. The frontend architect
writes the implementation plan after this; the doc is the tiebreaker
above the architecture doc on barcode-specific calls.

`specs/pm_decisions_flutter_ui.md` (§10 item 3, the desktop barcode call),
`specs/pm_overnight_features.md` §B10 (desktop paste-a-barcode), the
architect's `specs/flutter_ui_architecture.md` §6 "Barcode scanning" +
§7 "No barcode UI on web", and `specs/openapi.yaml`'s
`GET /foods/barcode/{barcode}` are all upstream of this doc. Where this
doc conflicts with either architecture-side rider, this doc wins for the
mobile camera flow; the rest of the architecture is left alone.

---

## 1. Context

We declared `mobile_scanner: ^5.2.3` in `client/pubspec.yaml` and shipped
the `BarcodeScanButton` widget in
`client/lib/features/search/widgets/barcode_scan_button.dart`, but the
actual camera-capture path is still a `TODO(scan)` stub —
`HapticFeedback.selectionClick()` and nothing else. Desktop paste-a-
barcode (T-021) is wired through `SearchField` in `search_field.dart`
and the resolver `_BarcodeResolveScreen` at `/foods/barcode/:barcode`
already does the right thing on success (push to food detail) and on 404
(push to `/foods/new?barcode=…` with the draft prefilled). The user
wants the mobile camera flow filled in *now* because the mobile user
story — "pulling out my phone in line at a burrito shop, scan a barcode,
log the entry in under ten seconds" — is the single strongest signal in
`pm_decisions_flutter_ui.md`'s Context section, and the feature has been
half-shipped for a release. We are not designing from scratch. We are
finishing the mobile half of a feature whose route, resolver,
repository, error path, and button placement all already exist.

---

## 2. Competitive survey

I read product pages, support docs, app-store listings, and independent
reviews for five competitors. Each row below has at least one source
URL inline so the architect can revisit.

### MyFitnessPal

- **Affordance.** From the Diary page, "Scan Barcode" sits below the
  search box; from the Dashboard, tap `+` → Barcode Scan. The scanner
  is accessed from two surfaces — the search context and a global add
  context — and both are top-level. Notable: behind Premium paywall
  (US-only as of 2026, per support docs).
- **Viewfinder.** Camera fills the screen; a rectangular "scanner
  square" overlay tells the user where to put the barcode. Single-shot
  detect: as soon as a barcode is recognized, the camera closes and
  the app navigates to the matched food's "Add Item" screen.
- **Permission UX.** System prompt on first invocation. Subsequent
  denials show "may need to grant permission for MyFitnessPal to
  access the camera on your device" — minimal recovery copy, doesn't
  deep-link to settings.
- **Success.** Auto-navigate to the food edit screen with serving and
  meal preselected; user confirms with a checkmark.
- **Unknown barcode.** Surfaces a search-style result list or "No
  matches found" with an option to add the food manually; the user
  has to re-enter the barcode in the custom-food form (it isn't
  carried through automatically).
- **Notable.** They paywall the scanner. We don't have a Premium tier
  to gate behind — irrelevant for us but worth knowing the segment
  has moved this direction.
- **Sources.**
  https://support.myfitnesspal.com/hc/en-us/articles/360032624771-How-do-I-use-the-barcode-scanner-to-log-foods
  ,
  https://eathealthy365.com/myfitnesspal-barcode-scanner-your-ultimate-how-to-guide/

### Lose It!

- **Affordance.** "Scan It" / "Snap It" lives behind the camera icon
  on the main bottom action; it's a multi-modal capture (barcode +
  nutrition-label OCR + food-photo recognition all on the same
  button). Single tap → camera opens.
- **Viewfinder.** Full-screen camera with a horizontal scan band; the
  app detects whether the camera sees a barcode, a label, or a meal
  and routes accordingly. Their selling point is that *the camera is
  the entry point* for everything, not just barcodes.
- **Success.** Barcode detect → auto-fill nutrition and serving; user
  confirms.
- **Unknown barcode.** Falls back to label OCR ("we'll read the
  nutrition panel") — a different experience but the same intent
  ("don't make me type"). For our v1, label OCR is a punt (§10).
- **Notable.** Their North Star is "one button on the home screen
  that solves three problems." We are not committing to the OCR
  surface in v1, but the *placement* (close to the user's primary
  add affordance) is a good signal we should keep the affordance
  near search, not buried.
- **Sources.**
  https://apps.apple.com/us/app/lose-it-calorie-counter/id297368629
  ,
  https://www.engadget.com/2016-09-29-lose-it-snap-it-app.html

### Cronometer

- **Affordance.** Search → Barcode icon, similar to where ours lives.
  Critically, Cronometer offers the scanner *free*, which a 2026 garage-
  gym review specifically calls out as a competitive differentiator
  against MyFitnessPal.
- **Viewfinder.** Rectangular overlay, single-shot. Reviews describe
  it as "lightning fast and super responsive" and explicitly call out
  the same failure modes the architect needs to design for — dirty,
  shiny, or curved packaging, plus low light.
- **Permission UX.** Standard system prompt; reviewers don't complain
  about it, which suggests it's adequate.
- **Success.** Auto-jumps to the matched food's detail screen with
  serving + quantity, log-style.
- **Unknown barcode.** Offers to add the food manually; nutrition
  label OCR (via picture of the label, even in Spanish, per reviews)
  is the fallback.
- **Notable.** Their value prop is "scanner that works on the free
  tier." Our v1 doesn't have a tier story, so we inherit their
  positioning by default.
- **Sources.**
  https://cronometer.com/blog/how-to-use-the-barcode-scanner/
  ,
  https://cronometer.com/blog/best-barcode-scanner/
  ,
  https://www.garagegymreviews.com/cronometer-review

### Yuka

- **Affordance.** The app is built around the scanner — it's the
  default landing surface on open. The viewfinder is the home page.
- **Viewfinder.** Continuous scan. No tap, no shutter — point the
  camera, see the score appear. The "wow effect" the company's own
  marketing names is exactly this: zero ceremony. Yuka uses Scandit's
  commercial SDK under the hood, which gives them top-tier detection
  on blurry / angled barcodes that ZXing and ML-Kit can struggle
  with — but the *UX pattern* (continuous, scan-as-default) is the
  thing to steal, not the SDK.
- **Permission UX.** Walks the user through the camera permission as
  the very first thing post-onboarding. If permission is denied, the
  app still works as a search + history surface but the home tab is
  visibly degraded.
- **Success.** Animated reveal of the product score; haptic + small
  audio tick on capture; product detail slides up as a sheet.
- **Unknown barcode.** "Help us add this product" — invites the user
  to contribute the missing product to Open Food Facts. (Yuka is
  largely OFF-powered, same as us.)
- **Notable.** Best-in-class for "lowest friction barcode flow." The
  pattern to steal is **continuous scan with no shutter, scanner is
  the surface, not a sub-screen**. We won't replicate the
  "home-page-is-the-scanner" placement (our home is the day view,
  for good reason), but inside the scanner route, continuous-mode
  is the right choice.
- **Sources.**
  https://yuka.io/en/app/
  ,
  https://www.scandit.com/resources/case-studies/yuka/

### Open Food Facts (the data source itself)

- **Affordance.** The OFF app *is* a scanner-first experience too,
  built in Flutter (informative: same stack as us). Continuous
  barcode scan is the headline UX feature in their press release for
  the most-recent rewrite.
- **Viewfinder.** Continuous scan; the press release specifically
  pitches "scan several products in one aisle without having to
  click a button" — the same pattern as Yuka.
- **Success.** Scans queue and resolve in sequence; the user sees
  Nutri-Score and NOVA group pop in as each product resolves.
- **Unknown barcode.** OFF's whole purpose is contribution — the
  app prompts the user to add the missing product. (Our v1
  equivalent is "push to `/foods/new?barcode=…` to create a custom
  food," which is the same shape minus the public-database
  contribution.)
- **Notable.** Same Flutter stack, same data source, same
  continuous-scan pattern — confirms continuous-scan as the
  industry-aligned default for this product category in 2026.
- **Sources.**
  https://apps.apple.com/us/app/open-food-facts-product-scan/id588797948
  ,
  https://blog.openfoodfacts.org/en/news/the-new-open-food-facts-app-to-better-decipher-labels-and-participate-in-the-common-good

### Summary table

| App | Affordance location | Viewfinder | Mode | Success | Unknown |
|---|---|---|---|---|---|
| MyFitnessPal | Diary + global `+` | Rect square | Single-shot | Edit screen | Manual entry (no carry-through) |
| Lose It! | Bottom action (camera-first) | Full-screen + scan band | Single-shot | Edit screen | Label OCR |
| Cronometer | Search → barcode icon | Rect overlay | Single-shot | Detail screen | Manual + label OCR |
| Yuka | App is the scanner | Full-screen | **Continuous** | Animated score sheet | Contribute to OFF |
| Open Food Facts | App is the scanner | Full-screen | **Continuous** | Score + NOVA | Contribute to OFF |

The split is informative. The dedicated calorie trackers (MFP, Lose It!,
Cronometer) treat the scanner as a sub-flow gated behind search and
fire single-shot. The "scan-first" apps (Yuka, OFF) treat the camera as
*the* surface and fire continuously. We are a calorie tracker by
mission, but our user is *also* the "burrito shop in line" user — and
the continuous-scan pattern wins for that user. We adopt it inside the
scanner route while keeping the affordance gated behind search (so the
day view isn't fighting the camera for attention).

---

## 3. UX best-practice principles

Eight numbered items the implementation must respect. Each is a one-
or two-sentence ruling backed by competitive observation or vendor
guidance; the architect can cite these by number in code review.

1. **Show a reticle, not just a raw camera feed.** A rectangular
   viewfinder centered on the screen tells the user where to aim and
   visually constrains the scan region (Scandit / Scanbot both call
   this out, and every competitor in §2 does it). Make it
   `width: min(screenWidth - 64, 320)`, `height: 160`, with
   corner-bracket framing in `AppColors.accent` (4 px stroke, 24 px
   corner radius). Dim the surrounding area to ~60 % opacity black
   so the contrast is unambiguous in real-world lighting.
   Source: https://scanbot.io/techblog/implementing-a-barcode-scanner-viewfinder/

2. **Continuous scan with auto-detect, not a tap-to-capture shutter.**
   The Yuka / OFF pattern. The user holds the phone, the app fires
   the result the instant it detects a valid barcode. No "tap to
   focus", no shutter button. After one successful detection, the
   camera pauses (per Scanbot's "8–10 s timeout to prevent errant
   scans") and the resolver runs. Anyone who's used Yuka knows why
   this matters: shutter buttons feel slow.
   Source: https://www.scandit.com/resources/case-studies/yuka/

3. **Haptic + visual feedback on detection.** `HapticFeedback.lightImpact()`
   the instant the barcode decodes; flash the reticle to
   `AppColors.accentSoft` for 120 ms with a corner-bracket pulse to
   `AppColors.accent`. No audio tick in v1 — most users in a burrito
   shop have their phone silenced, and an audio cue is overkill given
   we already vibrate. (Re-enable per-user audio in v2 if anyone
   asks.) The architecture's §6 already commits to `HapticFeedback.lightImpact()`
   on success scan; this principle just adds the visual.
   Source: https://codecorp.com/about/blog/barcode-scanner-feedback/

4. **Torch (flashlight) affordance, top-right, visible by default.**
   Low-light scanning is the most common failure mode after curved
   packaging (Cronometer reviews explicitly name it). A 44 × 44
   pill button in the top-right of the scanner route toggles the
   device torch. Use `mobile_scanner`'s `MobileScannerController.toggleTorch()`.
   Icon: `Icons.flashlight_on` / `flashlight_off`. The first-time
   tooltip explains "Tap to turn on the light."
   Source: https://scanapp.org/blog/2022/10/30/using-flash-or-torch-with-html5-qrcode.html

5. **Permission denial has a clear recovery path that doesn't dead-
   end.** First-run denial: inline message inside the scanner route
   reading "Camera access is off. [Open settings]". Tapping deep-
   links to the per-app permission screen (iOS uses
   `UIApplication.openSettingsURLString`; Android uses
   `package:settings_panel` / `app_settings`). The user can always
   close the scanner and continue in manual-search; we never block
   them out of the app over a denied camera. The architecture §6
   already commits to this — we operationalize it with a deep-link
   instead of a static instruction.
   Source: https://github.com/juliansteenbakker/mobile_scanner/issues/847

6. **"No detection" timeout with an escape hatch.** If we've been
   scanning for 10 seconds with no successful decode, the scanner
   shows a small bottom-sheet hint above the camera: "Trouble
   scanning? [Enter the barcode manually]". Tapping pushes a
   modal text field that accepts 8–14 digits and routes to
   `/foods/barcode/{code}` — the same desktop path. This is the
   accessibility seam (see #7) and the "shiny / curved package"
   seam in one. Don't show the hint sooner than 10 s — earlier
   makes the camera feel like it's failing when it's just
   focusing.

7. **Manual entry is the screen-reader path, not a hidden corner.**
   Camera-only scanning is unusable with VoiceOver / TalkBack — a
   sighted scanner that requires line-of-sight to a barcode is not
   a meaningful affordance with a screen reader on. The "Enter the
   barcode manually" path from #6 is *always* one tap away from the
   scanner route's top-bar (an `IconButton36` with
   `Icons.keyboard`), and it's labeled `"Enter barcode manually"`
   for screen readers. Architecturally we already have the desktop
   paste-a-barcode path; this is the same flow reused on mobile for
   the accessibility minimum.
   Source: T-20 in `flutter_ui_architecture.md` is the in-repo cite.

8. **Pause on detection; don't let the same barcode fire twice.**
   On a successful decode, *pause the controller* (`MobileScannerController.stop()`)
   before the resolver navigates. This prevents the
   "five-of-the-same-burrito" bug where the camera holds focus while
   the resolver round-trip is in flight and emits the same code
   repeatedly. The architecture's §6 sketch implies fire-and-forget;
   we explicitly require pause-before-navigate. (For continuous-scan
   apps like Yuka and OFF, the pause is what makes
   "scan-multiple-products-in-an-aisle" possible without duplicating
   — they only resume after the user dismisses the result. Same
   pattern for us: the scanner route never sees the same barcode
   twice in a row.)
   Source: https://docs.scanbot.io/barcode-scanner-sdk/windows/barcode-scanner/ui-components/

---

## 4. User stories

Seven stories. Cover the happy path on both form factors, the unknown-
barcode case, the denied-permission case, the bad-light-low-quality
case, and the accessibility case.

- **As a mobile user standing in line at the burrito shop,** I open
  Fulfilled → tap the search icon → tap the barcode-square button
  next to the search field → the camera opens, I aim at the can of
  oat milk in my hand, and within two seconds I'm on the food's
  detail page with the log-entry sheet open. I save and put the
  phone back in my pocket. **Total interactions: 3 taps + 1 aim.**

- **As a mobile user who's never granted camera permission to
  Fulfilled before,** I tap the barcode button, see the system iOS /
  Android permission dialog, and tap Allow. The camera initializes
  inside the scanner route — I don't get bounced back to search and
  then forward to scan again. (The Yuka pattern: ask once, ask in
  context.)

- **As a desktop user at work** with a packaged food on my desk
  whose barcode is right there in front of me, I type or paste
  `8000500310427` into the search bar; a "Look up barcode 8000500310427 →"
  row appears below the input; I press Enter and land on the food
  detail. This path already ships (T-021); no new design needed —
  call it out so we don't accidentally regress it when wiring the
  mobile path. **No camera UI on desktop web in v1.**

- **As a mobile user who scans a Nestlé import that Open Food Facts
  has never heard of (404),** I see no error scolding — the scanner
  pauses, the haptic fires, and the resolver routes me straight to
  `/foods/new?barcode=8000500310427` with the barcode field
  pre-filled and the form ready for me to type the name and
  nutrition off the back of the package. This *also* already ships
  on the resolver side; we wire the scanner to feed it.

- **As a mobile user who tapped Don't Allow on the camera permission
  six months ago and now wants to actually use the scanner,** I tap
  the barcode button, see the in-route inline state "Camera access
  is off. [Open settings]", tap the link, the iOS / Android settings
  panel opens straight to Fulfilled's permission screen, I flip the
  toggle, and on return to the app the scanner is live. I never
  have to figure out the path "Settings → Privacy → Camera →
  Fulfilled" on my own.

- **As a mobile user trying to scan a shiny, curved aluminum can in
  a fluorescent-lit kitchen,** the camera doesn't get a decode in
  ten seconds. A hint slides up from the bottom of the scanner
  route: "Trouble scanning? Enter the barcode manually." I tap it,
  type the 13 digits off the label, and the same resolver fires
  the same lookup. **The scanner failing gracefully is a feature.**

- **As a screen-reader user (VoiceOver on iOS, TalkBack on
  Android),** I tap the barcode button (which announces "Scan
  barcode, button"), the scanner route opens, and *the first
  focusable control after the close button is "Enter barcode
  manually"* — not the live camera feed (which is announced as
  "Camera viewfinder, image" and is not meaningfully
  interactable for me). I activate the manual entry, type the
  digits, and the resolver fires.

---

## 5. Format coverage

The `mobile_scanner` package's `BarcodeFormat` enum offers a wide
range; we enumerate exactly the formats we accept so the detector
isn't doing extra work and so we don't ship a "we scanned your
PDF417 driver's licence and tried to look it up as food" footgun.

**Enable in `MobileScannerController.formats`:**

| Format | Why |
|---|---|
| `BarcodeFormat.ean13` | The global default. Every European packaged food. Open Food Facts is fundamentally an EAN-13 index. |
| `BarcodeFormat.upcA` | US / Canada packaged food. UPC-A is a 12-digit subset of EAN-13 on the wire (lead with `0`); both `mobile_scanner` and OFF normalize, but we still enable both formats explicitly so the decoder reports the right symbology. |
| `BarcodeFormat.ean8` | Short EAN — small packaging that can't fit a full EAN-13 (gum, candy single-units, some private-label snacks). Cheap to enable; high signal when it fires. |
| `BarcodeFormat.upcE` | Short UPC, US small-package equivalent. Same rationale as EAN-8. |

**Explicitly disable** (prevents off-target detection from chewing
camera frames and surfacing nonsense):

- `BarcodeFormat.qrCode` — not a food symbology; if a user scans a
  restaurant menu QR we don't want to route it to `/foods/barcode/…`.
- `BarcodeFormat.code128`, `BarcodeFormat.code39`, `BarcodeFormat.code93` —
  these *do* appear on grocery shipping cases and some private-label
  weighable items (deli, produce stickers), but consumer packaged
  food on shelves uses EAN/UPC by GS1 convention. Enabling Code-128
  would mostly catch shipping labels and produce-scale stickers,
  neither of which we resolve against OFF. Punt to v2 if a user
  complains.
- `BarcodeFormat.itf` (Interleaved 2 of 5) — outer-case / shipping
  barcode. Not consumer-facing. Disable.
- `BarcodeFormat.aztec`, `BarcodeFormat.dataMatrix`, `BarcodeFormat.pdf417` —
  not food symbologies. PDF417 in particular is on US driver's
  licences; we are not in the business of accidentally reading a
  driver's licence.

**Implementation note for the architect.** `mobile_scanner`'s default
is "all formats", which both burns CPU and creates the off-target
detection problem above. Pass the four-element list explicitly to the
controller; do not rely on the default.

Source on the four-format coverage:
https://www.gs1us.org/upcs-barcodes-prefixes/barcode-types
and
https://www.scandit.com/resources/guides/types-of-barcodes-choosing-the-right-barcode/

---

## 6. Mobile flow (decision)

The single happy-path flow, decided.

### Where the scanner mounts

**Full-screen route, not a bottom sheet.** Path:
`/foods/barcode/scan` (an internal route, *not* deep-linkable per
T-14). Pushed via `Navigator.of(context).push(MaterialPageRoute(...))`
from `BarcodeScanButton.onScan` — the button stays where it is in
`SearchField`'s trailing slot and on the custom-food barcode field
(screen 05). The route has its own `Scaffold` with no `AppScaffold`
chrome (no bottom tabs, no FAB), full-screen camera, and a top
toolbar with three controls: close (left), manual-entry keyboard
icon (right of close), and torch toggle (far right).

**Why route not sheet.** A bottom sheet would compress the camera
into ~60 % of the screen, which dramatically hurts decode performance
on EAN-13s read at distance. Every competitor in §2 goes full-screen.
Match the convention.

**Why not a deep-linkable route.** Per T-14, routes are addressable.
A user landing on `/foods/barcode/scan` from outside the app would
get a full-screen camera with no context — that's a permission-
dialog footgun and a privacy surprise. The scanner is intra-app
navigation only.

### Permission first-run + recovery

**First-run.** On scanner-route mount, immediately call
`MobileScannerController.start()`. `mobile_scanner` will request
the camera permission via the OS, which surfaces the system dialog.
We do not pre-prompt with an in-app "we're about to ask for camera"
screen — Yuka doesn't, OFF doesn't, neither do MFP/Cronometer/Lose
It! It's noise.

**Configure Info.plist + AndroidManifest.** This is a one-time
implementation thing the architect must not forget:

- `ios/Runner/Info.plist`:
  `NSCameraUsageDescription = "Fulfilled needs camera access to scan
  food barcodes."` — concrete and human; Apple rejects generic
  descriptions.
- `android/app/src/main/AndroidManifest.xml`:
  `<uses-permission android:name="android.permission.CAMERA" />`
- The `mobile_scanner` plugin pulls in `<uses-feature
  android:name="android.hardware.camera" android:required="false" />`
  — leave required `false` so the Play Store doesn't gate install on
  cameraless devices.

**Recovery (denied).** When permission is denied, the route renders
an inline state inside its own scaffold (no separate "permission
denied" route). Content:

```
[Camera icon, ink3, 40 px]
Camera access is off

Turn on the camera to scan barcodes.
You can also enter a barcode manually.

[Open settings]      [Enter manually]
```

Tap **Open settings** → deep-link to the app's permission screen
via `AppSettings.openAppSettings()` from `package:app_settings` (or
roll a minimal channel; architect's call — `app_settings` is fine).
On return to the app (via `AppLifecycleState.resumed` on the
scanner route), re-check permission status and resume the camera
silently if granted.

Tap **Enter manually** → the same manual-entry sheet defined in §3
principle 6.

### Continuous-scan, pause-on-detect

Per §3 principles 2 and 8.

- `MobileScannerController(formats: [ean13, upcA, ean8, upcE],
  detectionSpeed: DetectionSpeed.noDuplicates, detectionTimeoutMs:
  250, returnImage: false)`.
- On `onDetect` fire:
  1. `controller.stop()` — pause before anything else.
  2. `HapticFeedback.lightImpact()`.
  3. Briefly flash the reticle (120 ms; see §3 principle 3).
  4. `context.pushReplacement('/foods/barcode/$detected')` — this
     hands off to the existing `_BarcodeResolveScreen` resolver,
     which already handles 200 (push to food detail) and 404 (push
     to `/foods/new?barcode=…`). The scanner route is replaced, so
     the user's back button from food-detail lands on search, not
     on a stale camera.

The `noDuplicates` flag plus the explicit `stop()` are belt-and-
braces — if the user navigates back to the scanner route (rare;
they'd have to go back twice through a successful flow), we want
the next decode of the same code to fire fresh.

### Torch

Top-right pill button, `Icons.flashlight_on` / `flashlight_off`,
44 × 44 hit area (T-06). Reads `controller.torchEnabled` (or
mirrors a local `ValueNotifier` if the controller doesn't expose
it as a stream — architect's discretion). Persist torch state
across scans within a single route push (one user, one shopping
trip in a dark pantry), but **reset to off on route dispose** —
we don't want a future scan to mysteriously open with the torch
on.

### Haptics

Defined in §3 principle 3. Only fire on a *successful detect*. Do
not fire on permission denial, do not fire on the "trouble
scanning" hint surface, do not fire on torch toggle. Haptics are a
success signal in this feature, not a UI confirmation.

### Bad-light / no-detect timeout

Per §3 principle 6. A `Timer` armed on route mount and reset on
detect; at 10 s of contiguous no-detect, slide a 56-px-tall hint
band up from the bottom (above the system safe area) with
"Trouble scanning? Enter the barcode manually" — tapping opens
the manual-entry sheet. The hint stays visible until manual
entry is opened or until a successful detect cancels it.

### Manual entry

A modal bottom sheet (mobile) launched from the scanner route's
top toolbar **and** from the no-detect hint. Single
`TextField` (`keyboardType: TextInputType.number`, max 14 chars,
inputFormatter `FilteringTextInputFormatter.digitsOnly`), a "Look
up" button. On submit, validate `^\d{8,14}$` per T-021;
`pushReplacement('/foods/barcode/$value')`. On invalid input
(too short, contains non-digits), inline error below the field;
do not modal-dialog (T-11).

### Where the affordance lives

The `BarcodeScanButton` widget is already wired in two places:

1. `SearchField`'s trailing slot on screen 02 (search).
2. The custom-food form's barcode field on screen 05.

**Both stay.** No new button anywhere. The FAB on Today does *not*
get a "scan barcode" mode — that's the Lose It! pattern and it
fights our existing "log food" FAB. Users get to the scanner
through search (or through editing a custom food's barcode), full
stop. If a v2 study shows mobile users want to scan from Today
without going through search, we add a scan-only icon to the day-
view top bar. Not v1.

---

## 7. Web flow (decision)

**Paste-only on web for v1. No browser-camera scanning.**

The desktop paste-a-barcode affordance (T-021, shipped) is the answer.
Reasoning:

- **BarcodeDetector API is Chromium-only and not on Safari / iOS
  Safari.** Per `caniuse.com` and Chromium's own feature status, the
  Web Barcode Detection API ships in Chrome and Edge desktop +
  Android Chrome, but **not** in Safari (any version) or Firefox.
  That makes it useless on mobile-web-on-iPhone, which is our
  trickiest case — a US iPhone user opening fulfilled.app on Safari
  is the same human who'd want to scan a burrito at lunch. They get
  no camera-detect; they get a broken affordance.
  Source: https://caniuse.com/mdn-api_barcodedetector
- **The cross-browser fallback (`@zxing/library`) is unmaintained
  and Safari-flaky.** The library's README and issue tracker
  confirm "we do not have the time to actively maintain zxing-js
  anymore" and lists Safari iOS WebRTC issues prior to iOS 14.3.
  Shipping an unmaintained 0.21.x JS library inside our Flutter Web
  bundle to get a degraded experience on the one browser that
  matters most is a bad bet.
  Source: https://github.com/zxing-js/library
- **The architecture already shipped the right answer.** §7 of the
  architecture doc says explicitly "No barcode UI on web" and the
  T-021 ticket shipped the paste-a-barcode affordance with regex
  validation, a `Look up barcode →` row, and resolver wiring. The
  user who has a barcode in front of them at a desk types or pastes
  it. The mobile-web-on-iPhone user opens the mobile app. (We do
  not have a story for "I'm using mobile Safari and refuse to
  download the app" beyond paste, and we accept that.)

**Mobile web (Safari on iPhone) gets the compact layout** per the
architecture's existing rule — which means the `BarcodeScanButton`
becomes visible because `FormFactor.isCompact` is true. **We need to
fix this**: the button currently only checks `isWeb && !isCompact` to
hide itself, which means it would render on mobile-web and the
underlying `mobile_scanner` package has *no working web
implementation we want to ship* (it falls back to ZXing for web,
which we just argued against).

**Architect action item.** Tighten `BarcodeScanButton.shouldShow` to
also hide on mobile-web. The rule becomes:

```dart
// Show only on native mobile (iOS / Android). Hide on all web,
// including compact mobile-web.
if (kIsWeb) return const SizedBox.shrink();
```

When a mobile-web user has a barcode they want to look up, the
search field's "paste a barcode" affordance (already shipped on
compact via the regex shortcut in T-021) is the answer. The hint
copy in `SearchField` currently swaps on `isExpanded`; with the
button hidden on mobile-web, we should also swap the hint on
*any* web (mobile or desktop) to read "Search foods or paste a
barcode…". This is a one-line change in `search_field.dart`
(replace `context.formFactor.isExpanded` with `kIsWeb`).

**If a future v2 spike convinces us camera-on-web is worth it,**
the path is: probe `'BarcodeDetector' in window` at runtime,
use it on Chromium-Android only, and explicitly fall through to
paste on Safari. Not now.

---

## 8. Backend implications

**Today.** `GET /foods/barcode/{barcode}` exists per
`specs/openapi.yaml` line 405–423. It returns `FoodDetail` on
success, 404 on miss, 401 on auth failure. Path param accepts
`{type: string}`, no validation regex on the wire.

**What we need.** Nothing wire-shape new for v1. The endpoint as
specified is exactly what the resolver consumes today.

**Two flags for the user, not unilateral designs.**

1. **OFF cache-miss fallback.** Today, `GET /foods/barcode/{barcode}`
   serves from our Rust-side mirror of OFF data. If a barcode isn't
   in our mirror, we 404 and the client routes to "create custom
   food." That's the right call for v1 — it puts the user in
   control. **However**, the OFF database is a moving target: new
   products land in OFF daily, and our mirror could be days
   behind. A "live fallback" behavior — on 404 in our mirror, the
   server tries OFF's public `https://world.openfoodfacts.org/api/v2/product/{barcode}`
   directly, optionally caches the result, and returns it as if
   it had been ours — would meaningfully improve the unknown-
   barcode hit rate without changing any client code.
   **Recommendation: open a backend ticket** (call it BE-002 to
   match the BE-001 naming from the weight-unit work). Owner:
   Rust. Risk: OFF's API rate limits (1 req/s per IP for the
   public v2 endpoint) and the cost of a per-request external
   call on a hot path. Mitigation: server-side de-duplication
   and a short-TTL negative cache (e.g. 24 h "we asked OFF, they
   404'd too"). **The user makes the call** on whether this is
   v1.1 or v2.

2. **Barcode normalization on the wire.** UPC-A is a 12-digit
   subset of EAN-13 (lead with `0`). Different sources (some OFF
   product pages, some USDA exports) store the same physical
   barcode in different normalized forms. The client may scan
   `036000291452` (UPC-A) and our Rust mirror may have it
   stored as `0036000291452` (EAN-13). Today the resolver fires
   the raw scanned value and 404s if our mirror normalized
   differently. **Recommendation: open a backend ticket** that
   server-side `GET /foods/barcode/{barcode}` normalizes the
   input to EAN-13 (left-pad to 13 digits) before lookup. Same
   ticket should backfill normalization on the existing mirror
   rows so search is consistent. Mark as BE-003. Low risk; small
   migration. **The user makes the call** on priority.

**Neither of these blocks the v1 client work.** The client ships
against the endpoint as it stands today; the BE-002 / BE-003
tickets are pure improvements that lift the unknown-barcode rate
once they land.

---

## 9. Acceptance criteria

Bullets a reviewer can cite when reviewing the implementation PR.

- Tapping `BarcodeScanButton` on a native mobile build (iOS /
  Android) opens a full-screen scanner route with a centered
  rectangular viewfinder, accent corner brackets, dimmed
  surround, top-bar controls (close / manual-entry / torch).
- The scanner uses `mobile_scanner` configured to detect
  exactly four formats: `ean13`, `upcA`, `ean8`, `upcE`.
  No other format detection is enabled.
- On successful decode the scanner: pauses the controller →
  fires `HapticFeedback.lightImpact()` → flashes the reticle →
  calls `context.pushReplacement('/foods/barcode/$code')`. The
  existing resolver handles success (push to food detail) and
  404 (push to `/foods/new?barcode=…`).
- Camera permission is requested via the OS dialog on first
  scanner-route mount. No pre-prompt screen. iOS `NSCameraUsageDescription`
  reads "Fulfilled needs camera access to scan food barcodes."
- Denied permission renders an inline state with "Open settings"
  (deep-links to the app's permission screen via
  `package:app_settings` or equivalent) and "Enter manually"
  (opens the manual-entry sheet).
- The torch toggle works on devices with a torch; on devices
  without one (front-camera-only, some tablets), the button is
  hidden, not greyed.
- After 10 s of no decode, a bottom hint slides up with
  "Trouble scanning? Enter the barcode manually." The hint
  dismisses on detect or on manual-entry open.
- Manual entry accepts 8–14 digits, validates with
  `^\d{8,14}$`, and routes through the same
  `/foods/barcode/$code` resolver. Invalid input renders an
  inline error per T-11.
- The scanner route has no `AppScaffold` chrome (no bottom
  tabs, no FAB). Closing the route returns to the search
  screen.
- `BarcodeScanButton` is hidden on *all* web builds — both
  desktop web (already hidden) and mobile web (newly hidden).
  Web users use the paste-a-barcode affordance in `SearchField`,
  which we extend to render on every web build (not only
  expanded).
- `SearchField` hint copy reads "Search foods or paste a
  barcode…" on `kIsWeb` (any width); reads "Search foods or
  scan barcode…" on native mobile.
- `Semantics` on the scanner route: route label "Scan a food
  barcode"; viewfinder is `Semantics.image` with label
  "Camera viewfinder"; manual-entry button is the first
  focusable element after the close button; torch button is
  labelled "Camera light" with on/off state announced.
- No new tenants required. The existing tenants T-06
  (touch targets), T-08 (loading/skeletons — used while the
  resolver round-trips), T-11 (inline errors), T-14 (routes vs
  sheets — scanner is a non-addressable internal route per the
  ruling), and T-20 (accessibility) all apply.

---

## 10. Punt list

Things explicitly deferred. One-line rationale each.

- **Nutrition label OCR (ML-Kit text recognition).** Lose It!'s
  "Snap It" / Cronometer's photograph-the-label feature. Real
  value for unknown-barcode foods, but it's a meaningfully larger
  feature (recognize tabular nutrition data, parse numbers,
  reconcile per-serving vs per-100g). Punt to v2. The custom-food
  form already lets a user type the values; we are not blocking a
  workflow.
- **Photo-of-meal recognition.** Lose It!'s newer pivot. Out of
  v1 scope by an order of magnitude; would require an ML
  pipeline and a labelled food image dataset we don't have.
  Mention only to call it out as not-scoped.
- **Browser camera scanning via `BarcodeDetector` /
  `@zxing/library`.** Decision in §7. Revisit in v2 if Safari
  ships the API or a maintained polyfill emerges.
- **Audio tick on successful scan.** Haptic-only in v1; revisit
  if users ask. Most lifestyles where the scanner is used
  (groceries, kitchens, restaurants) have the phone silenced.
- **Scan history / "recent scans" list.** Tempting (it's
  basically free given Recents already exists), but Recents
  already surfaces scanned-and-resolved foods because they
  flow through the same log path. A separate "barcode history"
  doesn't add product value distinct from Recents. If users ask
  for "the *list* of barcodes I've scanned regardless of
  whether I logged them," reconsider — that's a different
  feature.
- **Bulk / continuous-add scanning** ("scan five items in a row
  and add them all"). The Yuka / OFF pattern adapted for
  logging. v2 once we have a sense of whether users want to
  pre-log a shopping cart (probably not — they log when they
  eat, not when they buy).
- **Quality of-OFF-data scoring at scan time.** OFF returns a
  `quality_score`; per PM Risk 10, we hide the score in user-
  facing copy v1. Same rule on the scan result. Don't change
  this on the basis of "the scanner is a special context" —
  it isn't.
- **Server-side OFF live fallback (BE-002 in §8).** Flagged for
  the user; do not implement unilaterally.
- **Server-side barcode normalization (BE-003 in §8).** Flagged
  for the user; do not implement unilaterally. Until it lands,
  the client may see false 404s on UPC-A scans that our mirror
  stored as EAN-13. The "push to /foods/new?barcode=…" recovery
  path absorbs this gracefully — the user can create the food,
  and we will rectify the duplicate on the backend when
  normalization ships.
- **Camera-permission pre-prompt screen.** Considered, rejected.
  No competitor does it; it's noise.
- **Manual-entry on desktop web "in addition to" paste.** The
  paste affordance is the manual-entry surface; we do not need
  a second one. Already shipped per T-021.
- **Per-user audio/haptics toggle.** v2 alongside any other
  accessibility preferences (e.g. reduced-motion). Not v1.
- **Auto-open log-entry sheet after barcode-resolve success.**
  Tempting (matches MFP's "scan → edit screen" pattern), but
  the food detail screen 03 already shows the "Add to log"
  sticky CTA, and the user may want to read the panel before
  logging. Punt the "scan → immediately into LogEntrySheet"
  optimization; revisit once we have analytics on how often
  scan-resolves lead to immediate logs vs. dismisses. (If
  > 90 % lead to immediate log, this becomes a no-brainer.)

---

## Summary

| Section | Decision |
|---|---|
| Mobile flow | Full-screen route, continuous scan, pause-on-detect, 4-format whitelist, accent corner-bracket viewfinder, torch top-right, manual-entry fallback, 10 s no-detect hint. |
| Web flow | Paste-only. Hide `BarcodeScanButton` on *all* web (including mobile web). Hint copy swaps on `kIsWeb`. |
| Backend | No client-blocking change. Flag BE-002 (OFF live fallback on cache miss) and BE-003 (EAN-13 normalization on the wire) for the user's call. |
| Formats | `ean13`, `upcA`, `ean8`, `upcE`. Explicit, not the package default. |
| Permission | OS dialog on first mount, no pre-prompt. Denied → inline state with `Open settings` deep-link + `Enter manually`. |
| Accessibility | Manual entry is the first focusable element after close. Screen-reader semantics on the route, viewfinder, torch, and manual entry. |
| Tenants touched | None added. T-06, T-08, T-11, T-14, T-20 apply. |

## Documents this decision touches

- `specs/flutter_ui_architecture.md` §6 "Barcode scanning" — replace
  the sketch flow with a one-line "see `pm_barcode.md` for the v1
  contract." Optional: copy the four-format list and the route name
  (`/foods/barcode/scan`) into §6 so engineers can find them without
  jumping docs.
- `specs/flutter_ui_architecture.md` §7 "No barcode UI on web" —
  tighten to "no barcode UI on *any* web build, including mobile
  web." The current wording allows the button on mobile web via the
  `isWeb && !isCompact` rule and we just superseded that.
- `client/lib/features/search/widgets/barcode_scan_button.dart` —
  change the hide rule to `kIsWeb` (any web), remove the TODO, wire
  the scanner route push.
- `client/lib/features/search/widgets/search_field.dart` — change
  the hint-swap from `isExpanded` to `kIsWeb` so mobile web also
  reads "paste a barcode…".
- New file: `client/lib/features/barcode/barcode_scanner_screen.dart`
  (architect's discretion on directory; matches the `features/`
  layout). Owns the camera, the viewfinder, the torch, the haptics,
  the no-detect timer, the manual-entry sheet.
- `ios/Runner/Info.plist` — add `NSCameraUsageDescription`.
- `android/app/src/main/AndroidManifest.xml` — confirm
  `<uses-permission android:name="android.permission.CAMERA" />` is
  present (the `mobile_scanner` plugin usually adds it but verify).
- New backend tickets, *flagged for user decision* not unilateral:
  - BE-002: server-side OFF live fallback on
    `GET /foods/barcode/{barcode}` cache miss.
  - BE-003: server-side EAN-13 normalization of barcode input on
    `GET /foods/barcode/{barcode}` and on stored barcode columns.
