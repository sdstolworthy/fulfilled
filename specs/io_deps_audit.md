# UI → IO Direct-Dependency Audit (v2)

Scope: every `*.dart` under `client/lib/features/**` and
`client/lib/widgets/**`. Categories audited: network, filesystem,
persistent storage, time/randomness, platform channels, repository /
service construction. Persistence categories re-verified against
`persistence_audit.md`'s closed-out state.

## 1. TL;DR

**The persistence layer is clean (re-confirmed): zero remaining UI
files import `package:hive*`, `package:shared_preferences`,
`package:flutter_secure_storage`, `package:sqflite`, `package:path_provider`, or
construct their own persistent-storage handles.** The fix from commit
`b89524f` (working tree at the time of `persistence_audit.md`) has
landed and is intact.

**Widening the lens to network / time / IO surfaces a small but
non-zero number of new violations**, all confined to two clusters:

| Category | Violations | Severity / size of fix |
|---|---:|---|
| Persistent storage | 0 | — |
| Filesystem | 0 | — |
| Network (`package:dio`) | 1 | 1 file (`oidc_callback_screen.dart`) — duplicates an existing seam (`runOidcExchange`) |
| Platform / OS IO (`dart:html`, `OidcNavigator.instance`, `flutter_web_auth_2`, `mobile_scanner`) | 3 | Three UI files reach a `const`/`static` singleton or `new`-up a controller in `initState` instead of going through a Riverpod provider |
| Time-dependence (rendered output reads system clock with no seam) | 7 widgets, 1 helper | New `clockProvider` plus call-site rewires — there is no `clockProvider`/`nowProvider` in the project today |
| Repository / service `new`-ing in widgets | 0 | All repository access flows through `*RepositoryProvider`s in `providers/repository_providers.dart`. |
| `DateTime.now()` writes (data sent to a repo, not rendered) | 1 | `current_weight_sheet.dart:84` passes wallclock into `weightRepo.create` — arguably the pragmatic "default" the user can later edit, but the sheet has no date picker so it really is a clock dependence on submitted data |
| `Random()` | 0 | none anywhere under `features/` or `widgets/` |

**Net assessment.** The codebase is meaningfully closer to "every UI
dep is provider-mediated" than it was when the persistence audit ran.
The remaining gaps are **N small fixes** away — not a structural
problem. Roughly:

- **1 PR** — collapse `oidc_callback_screen.dart` onto the existing
  `runOidcExchange` seam, dropping its direct `package:dio` import.
- **1 PR** — introduce a `clockProvider` + a thin `Clock` interface
  in `lib/data/clock.dart`, rewire the 8 render-time `DateTime.now()`
  callers and the 1 write-time one. This is the single biggest
  open-question item: there is **no** clock seam today and 8+ widgets
  depend on the system clock to decide what they render.
- **1 PR** — promote `OidcNavigator` from a `const navigatorImpl`
  singleton to a Riverpod provider so widget tests can override it
  the same way they override `healthProbeProvider`.
- **1 PR (or carry as known limitation)** — `ScanScreen`'s
  `MobileScannerController` is `new`-ed in `initState`; today the test
  seam is a constructor `controllerOverride` param, not a provider.
  Already exercises the same shape `OidcNavigator` should adopt,
  except via constructor injection instead of Riverpod.

## 2. Violations

### 2.1 `features/login/oidc_callback_screen.dart` — direct `package:dio` import + `DioException` catch

- **File**: `/workplace/fulfilled/client/lib/features/login/oidc_callback_screen.dart`
- **Lines**: `1` (`import 'package:dio/dio.dart';`), `74`
  (`final dio = ref.read(apiClientProvider).dio;`), `75`
  (`final res = await dio.post<dynamic>('/auth/oidc/exchange', …);`),
  `94` (`on DioException catch (e)`).
- **What it does**: the screen the OIDC callback redirect lands on
  (`/login/callback?code=<handoff>`). It reads the handoff out of the
  route param, exchanges it for an opaque bearer via
  `POST /auth/oidc/exchange`, persists the token, and `context.go`s to
  `/today`.
- **Why it's a violation**: the access path uses `apiClientProvider`
  (good — seam), but then it grabs the underlying `dio` handle off the
  client and posts directly. The catch block on line 94 also pattern-
  matches against `DioException` — so even the error-classification
  knows it's talking to Dio. Tests can't substitute a fake exchange
  without standing up a fake Dio.
- **Recommended fix**: this logic *already exists* as
  `runOidcExchange(ref:, handoff:)` in `features/login/oidc_exchange.dart`,
  returning the sealed `OidcExchangeResult` (`Success` / `Error(msg)`).
  Both `LoginScreen._runExchange` (line 100 of `login_screen.dart`) and
  `OidcButton._onPressed` (line 65 of `oidc_button.dart`) already
  consume that surface. The fix is mechanical: replace lines 61–110 of
  `oidc_callback_screen.dart` with the same `switch (result)` shape the
  other two call sites use, then drop the `package:dio` import. The
  resulting file has no IO imports at all.

### 2.2 `features/login/widgets/oidc_navigator_web.dart` — `dart:html`

- **File**: `/workplace/fulfilled/client/lib/features/login/widgets/oidc_navigator_web.dart`
- **Lines**: `3` (`import 'dart:html' as html;`), `23`
  (`html.window.location.href = startUrl;`), `31`
  (`final loc = html.window.location;`), `65`
  (`html.window.history.replaceState(null, '', buf.toString());`).
- **What it does**: web implementation of `OidcNavigator` — performs
  a full-page redirect on `startFlow` and a `history.replaceState` on
  `stripQueryParam`.
- **Why it's a violation**: this is a `widgets/` file. It is the
  *seam impl*, but the seam is exposed as `OidcNavigator.instance`
  (line 69, `const OidcNavigator navigatorImpl = _WebNavigator();`)
  — a `const` getter, not a Riverpod provider. So widget tests can
  neither override the singleton via `ProviderScope.overrides` nor
  swap the conditional-import target. The IO impl is hard-wired.
- **Recommended fix**: hoist the seam itself out of the widgets
  folder and behind a `Provider<OidcNavigator>`. Two steps:
  1. Move `oidc_navigator.dart` (the abstract `OidcNavigator` +
     the `OidcFlow*` result types) to `lib/data/oidc_navigator.dart`.
     Expose
     `final oidcNavigatorProvider = Provider<OidcNavigator>((ref) =>
     navigatorImpl);` next to the existing conditional-import wiring.
  2. Rewrite the two callers (`oidc_button.dart:58`, `login_screen.dart:99,107`)
     to read `ref.read(oidcNavigatorProvider)` instead of
     `OidcNavigator.instance`.
  Once that's done, `oidc_navigator_web.dart` and `oidc_navigator_stub.dart`
  stay where they are or move alongside `data/` — either way the UI
  surface only knows the abstract type and the provider.

### 2.3 `features/login/widgets/oidc_navigator_stub.dart` — `package:flutter_web_auth_2`

- **File**: `/workplace/fulfilled/client/lib/features/login/widgets/oidc_navigator_stub.dart`
- **Line**: `3` (`import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';`)
- **What it does**: mobile/desktop impl of `OidcNavigator` — calls
  `FlutterWebAuth2.authenticate(...)` (line 56) to drive an
  `ASWebAuthenticationSession` (iOS) or Chrome Custom Tab (Android).
- **Why it's a violation**: same root cause as 2.2 — the file is a
  `widgets/` file, and the seam below it is the `const navigatorImpl`
  singleton, not a Riverpod provider. The conditional-import dance
  hides the impl choice at compile time from the consumer, but it does
  not give tests a place to substitute.
- **Recommended fix**: same as 2.2 — promote `OidcNavigator` to a
  Riverpod provider in `lib/data/`. Once the seam moves, this file is
  re-classified from "violating widget" to "legitimate seam impl"
  alongside `_DioHealthProbe`.

### 2.4 `features/login/login_screen.dart` — `Uri.base.queryParameters` + `OidcNavigator.instance`

- **File**: `/workplace/fulfilled/client/lib/features/login/login_screen.dart`
- **Lines**: `85` (`final oidcCode = Uri.base.queryParameters['oidc_code'];`),
  `99` and `107` (`OidcNavigator.instance.stripQueryParam('oidc_code');`).
- **What it does**: on first build the screen sniffs the document URL
  to detect "we're returning from a successful OIDC callback" and runs
  the exchange inline (web-only path — mobile uses `OidcButton`'s
  webview round-trip).
- **Why it's a violation**: two IO surfaces with no provider seam.
  `Uri.base` is dart:core but resolves to the document URL on web; a
  widget test pumping `LoginScreen` cannot inject a value into it. And
  `OidcNavigator.instance` is the same singleton called out in 2.2/2.3.
- **Recommended fix**: 2.2's `oidcNavigatorProvider` covers half. For
  the `Uri.base` read, introduce a tiny seam:
  `final initialUriProvider = Provider<Uri>((ref) => Uri.base);`
  and have `initState` `ref.read(initialUriProvider).queryParameters[…]`.
  Same shape as the `clockProvider` recommendation in §3 below.

### 2.5 `features/scan/scan_screen.dart` — `new MobileScannerController(...)` in `initState`

- **File**: `/workplace/fulfilled/client/lib/features/scan/scan_screen.dart`
- **Lines**: `67–78` (`_controller = MobileScannerController(formats: …);`),
  `102` (`await _controller.start();`).
- **What it does**: barcode scanner screen — constructs a
  `MobileScannerController` and starts the camera in `initState`.
  Decodes via `_onDetect`.
- **Why it's a violation, partial credit**: the screen already
  *has* a test seam — `controllerOverride: MobileScannerController?` on
  the widget's constructor (line 34) and the `_ownsController` branch
  in `initState`. Tests inject a fake to drive `_onDetect` without the
  camera. So in practice this is testable. **But** the seam is a
  constructor param, not a provider, which means it can only be
  overridden when the screen is built by a test that passes the
  override — anything that mounts `ScanScreen()` via the real router
  gets the real camera. That includes higher-level smoke / golden
  tests of the routing graph.
- **Recommended fix**: option A (smallest delta) — leave as-is and
  document this as an intentional "constructor seam" exception
  alongside `MockOidcNavigator`-style swaps. Option B (consistent with
  the rest of the codebase) — provider-ize:
  ```dart
  final mobileScannerControllerProvider =
      Provider.autoDispose<MobileScannerController>((ref) {
    final controller = MobileScannerController(formats: [...]);
    ref.onDispose(controller.dispose);
    return controller;
  });
  ```
  and have `_ScanScreenState` read `ref.watch(mobileScannerControllerProvider)`
  in `build`. Option B aligns the camera with how every other piece of
  IO is reached.

### 2.6 `features/login/widgets/oidc_button.dart` — `OidcNavigator.instance` + `Image.network`

- **File**: `/workplace/fulfilled/client/lib/features/login/widgets/oidc_button.dart`
- **Lines**: `58` (`await OidcNavigator.instance.startFlow(url, context: context);`),
  `138–146` (`Image.network(widget.provider.iconUrl, …)`).
- **What it does**: renders one "Sign in with X" button per
  configured OIDC provider. On tap, kicks off the IdP flow via the
  navigator and runs the exchange.
- **Why it's a partial violation**: the navigator call is covered by
  2.2's fix. The `Image.network` is a framework widget so it doesn't
  trip any of the package-import categories — but it is in-line
  network IO whose decode is opaque to tests. Real PaintingBinding
  hits IdP's icon URL.
- **Recommended fix for the navigator half**: see 2.2 — read
  `oidcNavigatorProvider`. For `Image.network`: borderline. Flutter's
  `imageCache` already disk-caches; tests typically use a
  `NetworkImage` mock or an `HttpOverrides` mock. Calling it a "near
  miss" rather than a violation is reasonable — but if the team wants
  belt-and-braces, gate it behind a `networkImageProvider` that
  returns either `Image.network` or `Image.memory` of a 1×1
  transparent png in tests. Not a high-value fix on its own.

## 3. Time-dependence findings

There is **no `clockProvider` / `nowProvider`** in the project. The
only "clock" file (`lib/repositories/_clock.dart`) is a seed-data
helper inside the mock-repository fixtures and explicitly *not* a
seam — its dartdoc says "If a future test actually needs to pin time,
the cleanest reintroduction is a `Zone` override".

Below are the widgets whose **rendered output** depends on the system
clock with no seam. Each one would need to monkey-patch the clock in
a widget test today.

### 3.1 `features/today/today_screen.dart:50` — `DateTime.now()` decides what day the whole screen shows

- The screen's job is "the Today day view." When `widget.date == null`
  (the `/today` route), `_resolveDate` reads `DateTime.now()` to derive
  the day to render. Every downstream piece — the date pill, the
  meal sections, the ring summary — keys off that value.
- **Fix shape**: `final today = ref.watch(clockProvider).today();` (a
  thin `Clock` interface with `DateTime now()` / `Date today()`), or
  resolve the route via a Riverpod `todayDateProvider` that the router
  layer also reads. Either way, the widget itself stops calling
  `DateTime.now`.

### 3.2 `features/today/today_internals.dart:16` — `todayHeadline` returns "Today" vs a weekday name based on now

- Pure helper consumed by the date bar in both day views. Whether it
  returns `"Today"` or `"Thursday"` is decided by the wallclock.
- **Fix shape**: take `DateTime now` as a required parameter; callers
  pull it from `clockProvider`. Same approach `formatLoggedSubline`
  already uses (it takes an optional `now`).

### 3.2.1 `features/today/today_internals.dart:300` — `_openPicker` clamps `firstDate`/`lastDate` to the wallclock

- The date-picker's bounds (`firstDate = today - 60 days`,
  `lastDate = today`) are wallclock-derived. The picker contents
  aren't "render" per se, but they are what the user sees on tap.
- **Fix shape**: read `clockProvider`. Borderline — could classify as
  near-miss since picker-internal contents aren't the widget's own
  build output, but it's the same provider once introduced.

### 3.3 `features/today/widgets/copy_day_sheet.dart:206, 212` — `_sourceFloor` / `_sourceCeil` getters

- Both stepper bounds and picker bounds compute `DateTime.now()` per
  invocation. The stepper enables/disables the right chevron at
  `today` — the rendered chevron's `disabled` state depends on the
  clock.
- **Fix shape**: read `clockProvider`. The two getters become pure
  functions of `today` (passed in or pulled from ref).

### 3.4 `features/log_entry/log_entry_sheet.dart:1132` — `_DateRow` label is "Today · MMM d" vs "EEE, MMM d"

- The date row's text content is decided by comparing `_date` to
  `DateTime.now()`. Pure render dep on the clock.
- **Fix shape**: pass `now` into `_DateRow` (or read `clockProvider`
  inside it). The widget is private to the sheet so the seam can be a
  constructor param — and `_LogEntrySheetBodyState` (which already
  reads providers) can wire it up.

### 3.5 `features/quick_add/quick_add_sheet.dart:688` — `_DateRow` mirror of 3.4

- Same `"Today · MMM d"` vs `"EEE, MMM d"` decision, same shape.
- **Fix shape**: as 3.4.

### 3.6 `features/weight/widgets/log_weight_sheet.dart:502` — `_DateRow` mirror of 3.4

- Same shape again — three "log entry sheet" feature folders ship the
  same `_DateRow` widget independently.
- **Fix shape**: as 3.4. Tangential follow-up: factor a shared
  `_DateRow` widget into `lib/widgets/` and seam it once.

### 3.7 `features/weight/widgets/weight_summary_card.dart:229` — `_latestSubtitle` is "today" / "yesterday" / "N days ago"

- Classic "5 minutes ago" pattern — render depends on the clock
  diffed against `e.recordedOn`. This is the textbook
  "easiest one to miss" case the audit brief calls out.
- **Fix shape**: read `clockProvider` in `_WeightSummaryBuilder.build`
  and pass `now` into `_latestSubtitle`. Single-line change once the
  provider exists.

### 3.8 `features/weight/widgets/weight_history_list.dart:276` — `_today` getter

- Used inside `_DayLabel._dayLabelFor` to decide "today"/"yesterday"
  prefix on each history row.
- **Fix shape**: as 3.7.

### 3.9 `features/goals/widgets/goal_history_list.dart:301` — `_durationDays(start, end)` defaults `end` to `DateTime.now()`

- When a goal has no end date (still active in history list), the
  duration shown ("X days") is computed against `DateTime.now()`.
  Rendered text depends on the wallclock.
- **Fix shape**: pass `now` from caller; caller reads `clockProvider`.

### 3.10 `features/search/widgets/search_result_row.dart:402` — `formatLoggedSubline` falls through to `DateTime.now()`

- The helper accepts a `DateTime? now` param **and** has a comment
  saying "production callers omit it and we read `DateTime.now()`".
  The only call site (line 113) does omit it. So the seam half-exists:
  the helper is testable, but the widget call site isn't.
- **Fix shape**: at the call site, `formatLoggedSubline(..., now:
  ref.watch(clockProvider).now())`. The helper signature already
  supports it.

### Out-of-scope / pragmatic clock reads (allowed by the brief)

These call `DateTime.now()` but the brief explicitly carves them out
("initial value of a controller that the user then edits is fine"):

- `features/log_entry/log_entry_sheet.dart:247, 270` — initial `_meal`
  and `_date` for create mode. User edits both via the form.
- `features/quick_add/quick_add_sheet.dart:223, 224` — same shape.
- `features/today/day_view_compact.dart:429` — `defaultMeal` passed
  into `showLogEntrySheet` on a quick-chip tap; the sheet then lets
  the user override.
- `features/goals/widgets/new_goal_dialog.dart:284, 285` and
  `features/onboarding/onboarding_screen.dart:171, 173` — `startsOn`
  derived from now when *creating* a goal; that's the canonical "the
  goal starts today" semantic and is a write, not a render.
- `features/profile/widgets/birth_date_picker.dart:24-26`,
  `features/onboarding/widgets/step_2_about_you.dart:215-221`,
  `features/log_entry/log_entry_sheet.dart:317`,
  `features/quick_add/quick_add_sheet.dart:267`,
  `features/weight/widgets/log_weight_sheet.dart:80-83` — date-picker
  initial / bounds. Borderline — picker contents aren't the widget's
  own build, but they are what the user sees on tap. Recommend
  flipping these to `clockProvider` *once* the provider exists, but
  don't gate the audit on them.
- `widgets/snackbar_throttle.dart:46` — already has a `DateTime? now`
  test seam; production callers omit it. Helper, not a widget render.

## 4. Repository / service construction findings

None. Every repository access in `features/**` and `widgets/**` flows
through one of the five providers in
`lib/providers/repository_providers.dart` (`foodRepositoryProvider`,
`goalRepositoryProvider`, `weightRepositoryProvider`,
`logRepositoryProvider`, `profileRepositoryProvider`). Three UI files
import a `repositories/*.dart` module directly — they do so only to
reference error types (`GoalNotFoundError`, `FoodNotFoundError`) or
type names exposed alongside the repository:

| File | Why the import is fine |
|---|---|
| `features/goals/goals_screen.dart:6` | `GoalNotFoundError` for the `next.error is GoalNotFoundError` switch in the `activeGoalProvider` listener (line 67). No construction. |
| `features/food_detail/food_detail_screen.dart:17` | `FoodNotFoundError` for the inline "Food not found" state. No construction. |
| `features/profile/profile_screen.dart:19` | Same — error type only. No construction. |

The unstaged-tree fix from `persistence_audit.md` for
`login_controller.dart` and `server_url_row.dart` is in place: both
files go through `baseUrlProvider` / `lastUsernameProvider` notifiers,
not the raw `authConfigBoxProvider`.

## 5. Legitimate provider seams

The provider files / interface types that legitimately mediate IO.
This is the positive-example list teams should copy from when
introducing new IO-touching state.

| File | Provider(s) exposed | Wraps |
|---|---|---|
| `/workplace/fulfilled/client/lib/data/api_client.dart` | `apiClientProvider` | `Dio` |
| `/workplace/fulfilled/client/lib/data/auth_config.dart` | `authConfigBoxProvider` (raw box — overridden in `main.dart`); `baseUrlProvider` + `BaseUrlNotifier`; `lastUsernameProvider` + `LastUsernameNotifier` | Hive `Box<String>` |
| `/workplace/fulfilled/client/lib/data/secure_token_store.dart` | `secureTokenStoreProvider`, `SecureTokenStore` | `FlutterSecureStorage` |
| `/workplace/fulfilled/client/lib/data/auth_token.dart` | `authTokenProvider`, `AuthTokenNotifier` | `secureTokenStoreProvider`, `outboxBoxProvider` |
| `/workplace/fulfilled/client/lib/data/auth_providers.dart` | `authProvidersProvider` | network `GET /auth/providers` via `apiClient` |
| `/workplace/fulfilled/client/lib/data/outbox/log_outbox_notifier.dart` | `outboxBoxProvider`, `logOutboxProvider`, `logPostFnProvider` | Hive `Box<String>` |
| `/workplace/fulfilled/client/lib/data/connectivity.dart` | `connectivityProvider` | `package:connectivity_plus` |
| `/workplace/fulfilled/client/lib/providers/api_base_url_provider.dart` | `apiBaseUrlProvider`, `uriBaseProvider`, `kIsWebProvider`, `kDebugModeProvider`, `debouncedLoginUrlProvider` | `baseUrlProvider`, `Uri.base` (note: `uriBaseProvider` *is* the proposed shape for the §2.4 `Uri.base` fix — already exists, just isn't read from `login_screen.dart` yet) |
| `/workplace/fulfilled/client/lib/providers/repository_providers.dart` | `foodRepositoryProvider`, `goalRepositoryProvider`, `weightRepositoryProvider`, `logRepositoryProvider`, `profileRepositoryProvider`, `formFactorOverrideProvider` | all five repos + `apiClientProvider` |
| `/workplace/fulfilled/client/lib/features/login/health_probe.dart` | `healthProbeProvider`, `HealthProbe` (abstract) | `Dio` (a freshly-constructed instance per call; rationale in dartdoc) |
| `/workplace/fulfilled/client/lib/features/login/oidc_exchange.dart` | `runOidcExchange(...)`, `OidcExchangeResult` (sealed) | `apiClientProvider` + `authTokenProvider`. **The exact reference shape the §2.1 fix copies.** |

**Note on `uriBaseProvider`**: it already exists in
`api_base_url_provider.dart` and abstracts `Uri.base`. Wiring
`login_screen.dart`'s line-85 read through that provider closes
half of finding 2.4 with no new seam.

**Note on `health_probe.dart`'s location**: it lives under
`features/login/` rather than `data/` because nothing outside the
login flow needs it. The pattern (abstract interface + `_DioFoo`
implementation + `fooProvider`) is reusable, and `oidc_exchange.dart`
already follows it. Moving these to `data/` would be a cleanliness
nit, not a correctness fix — and the `oidc_navigator` cluster (2.2 /
2.3) should adopt the same pattern.

## 6. Near misses

- `features/login/health_probe.dart:18` imports `dart:io` only for the
  `SocketException` type (line 148 catch). Not a violation — same as
  the persistence audit's call.
- `features/login/health_probe.dart:20`, `features/login/oidc_exchange.dart:3`
  import `package:dio/dio.dart` to reference `DioException` /
  `BaseOptions`. Both files are themselves the seams (one exposes
  `healthProbeProvider`, the other a sealed-result function); they
  ARE allowed to talk to Dio. Not violations — these are the seams §5
  enumerates.
- `widgets/snackbar_throttle.dart:46` reads `DateTime.now()` with a
  `DateTime? now` test-injection param. Already overridable.
- `widgets/keyboard_shortcuts.dart:263, 271` constructs a
  `Timer(const Duration(seconds: 1), reset)`. `Timer` is fake-clockable
  via `tester.pump`; nothing here reads `DateTime.now()`. Not a
  violation.
- `features/scan/widgets/no_detect_hint.dart:69, 90` constructs a
  `Timer(widget.delay, …)`. Same as above — `widget.delay` is a
  constructor param, and the timer fires through `tester.pump`.
  Not a violation.
- `features/scan/scan_screen.dart:140` calls
  `HapticFeedback.lightImpact()`. This is a static method that talks
  to a `MethodChannel` under the hood, but the call shape is `Class.method()`
  — not a `MethodChannel(…)` constructor in the UI file. Borderline;
  in tests `HapticFeedback` is a known-mockable Flutter surface
  (`tester.binding.defaultBinaryMessenger.setMockMethodCallHandler`).
  Calling it a near-miss.
- `features/login/widgets/oidc_button.dart:138` — `Image.network`. See
  2.6.
- Many `features/**` files reference `DateTime` for **rendering** an
  existing value (e.g. a goal's `startsOn` from the server). Those
  are not clock reads — they format a server-supplied value.

## 7. Open questions

- **Should `OidcNavigator` move out of `widgets/`?** §2.2/2.3 assume
  yes — the seam should live in `data/` next to `connectivity.dart` /
  `secure_token_store.dart` / `api_client.dart`. If the team would
  rather keep the per-feature folder structure, the alternative is to
  introduce a sibling `lib/features/login/data/` folder so the seam
  still lives near the feature without being under `widgets/`.
  Cosmetic — both work.
- **Is `current_weight_sheet.dart:84`'s `weightRepo.create(_kg, DateTime.now())`
  a violation?** The widget doesn't render anything off this value,
  but the *data written* depends on the wallclock with no seam. The
  audit brief's pragmatic carve-out covers form *defaults the user
  edits* — this sheet has no date picker, so it's not a default; it
  is the timestamp. Recommend flipping to `clockProvider` when the
  provider lands, but classifying it as a soft violation rather than
  a blocker.
- **`Image.network` (2.6)** — does the team want a
  `networkImageProvider` seam, or accept Flutter's built-in
  `HttpOverrides` mocking story for tests? §6 calls it a near miss
  but the line between "framework widget that does IO" and "package
  import that does IO" is genuinely fuzzy here.
- **`MobileScannerController` constructor injection (2.5)** —
  acceptable, or should it move to a provider? The current constructor
  seam works in unit/widget tests but skips routing-graph tests that
  mount the screen via `GoRouter`. Decision is "constructor injection
  is good enough for v1" vs "provider for consistency with the rest of
  the codebase." Recommend the latter, but it's a judgment call.
- **`features/login/login_screen.dart:117` `Future.delayed`** — three-
  second watchdog after `context.go`. Wallclock-equivalent but
  Flutter-fakeable via `tester.pump`. Calling it neither a violation
  nor a clock-render dependency, but flag for awareness — if the
  watchdog ever needs to participate in a deterministic test, it
  should read `clockProvider` too.
