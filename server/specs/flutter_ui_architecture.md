# Fulfilled — Flutter UI architecture & tenants

**Status**: source of truth for the v1 Flutter client. Read this before implementing any screen. The mocks (`specs/ui_mocks/*.html`) are the visual contract; this doc is the architectural contract. If a mock and this doc disagree on a non-token detail (data flow, navigation, etc.), this doc wins until the next sync.

**Audience**: developer agents (and humans) building Flutter screens. Backend devs only need section 5 and section 10.

**Stack assumption**: Flutter ≥ 3.27, Dart ≥ 3.6, targeting iOS, Android, and web (Canvaskit primary, HTML renderer not supported). The Rust API under `specs/openapi.yaml` is the only data source.

---

## 1. Form-factor strategy

One Flutter codebase, three breakpoints. The designer mocked two of the three (390-wide mobile and 1280-wide web). The middle is a deliberate, conservative interpolation — the same components, just more breathing room.

| Token name   | Width (logical px) | Hardware                 | Nav chrome        | Day-view layout                           |
|--------------|--------------------|--------------------------|-------------------|-------------------------------------------|
| `compact`    | `< 600`            | Phones, narrow web       | Bottom tab bar    | Single column, stacked meals, FAB         |
| `medium`     | `600 – 1023`       | Tablets, split-view, iPad portrait, narrow desktop windows | Left navigation rail (icon + label) | Single content column, ring/macros card on top, meals in a 2-col grid below |
| `expanded`   | `≥ 1024`           | Desktop web, iPad landscape | Persistent sidebar (240 px) | Two-column content area: 2×2 meal grid + 360 px right rail |

Rules:

- **Use `MediaQuery.sizeOf(context).width` against `Breakpoints.compact / medium`**, not `LayoutBuilder` per-widget unless the widget genuinely needs constraints-relative behavior (charts, ring sizing). Top-level `AppScaffold` reads the breakpoint once and exposes it via an `InheritedWidget` (`FormFactor.of(context)`).
- **The bottom tab bar (`compact`) and the sidebar (`expanded`) bind to the same routes.** Active state is derived from current route, not a separate selection state.
- **The right rail (Quick add + weight sparkline) appears only on `expanded`.** On `medium` it folds into a stacked secondary card row below the meal grid. On `compact` it does not exist — Recents/Frequents only live inside the search screen.
- **The FAB is `compact`-only.** On `medium` and `expanded` the equivalent primary action is the `Log food` button in the top bar (already mocked on web).
- **Modals.** Log-entry sheet is a `showModalBottomSheet` on `compact`/`medium`, an `AlertDialog`-shaped centered modal (max-width 480 px) on `expanded`. Food search is full-screen route on `compact`, a route in the main content area on `medium`/`expanded` (and ⌘K opens a centered command-palette-style dialog on `expanded`).
- **Touch density does not change with breakpoint.** Touch targets stay ≥ 44 px on mobile, hover targets may shrink to ≥ 32 px on desktop (see tenants). Type scale and spacing are identical across breakpoints — only layout grids change.
- **Web safe area**: respect `MediaQuery.padding`. The mobile-web case (Safari on iPhone) gets the `compact` layout and the bottom tab bar; do not hide it because we're "on web".

---

## 2. Design tokens

### 2.1 Color

Palette is copied verbatim from `INDEX.html`. Every value below is a non-negotiable constant on `AppColors`. **Do not introduce new colors.** New semantic meanings get a new token alias, not a new hex.

```dart
// lib/theme/tokens/colors.dart (shape only, not the full file)
@immutable
class AppColors {
  // Surfaces
  final Color bg;          // #FAFAF8
  final Color surface;     // #FFFFFF
  final Color line;        // #E6E5E0 — card borders, dividers
  final Color line2;       // #EFEEE9 — inner separators, sub-rows

  // Ink (text)
  final Color ink;         // #1A1D1A — primary text
  final Color ink2;        // #5C625C — secondary text
  final Color ink3;        // #9AA09A — tertiary / placeholders / metadata

  // Brand
  final Color accent;      // #1F5F5B — primary actions + on-track
  final Color accentSoft;  // #E4EEEC — accent fills, focus rings, badges
  final Color accentLine;  // #B6D2CF — accent borders (derived; used on web)

  // Macros (data-only)
  final Color protein;     // #C77B3A
  final Color carbs;       // #6E8B3D
  final Color fat;         // #B6883F

  // Status
  final Color danger;      // #B5552E — over-budget, errors, sign-out
  final Color dangerSoft;  // #FBEBE2 — error field background
  final Color goalLine;    // #C77B3A — dashed goal lines in charts (= protein)
  final Color highlight;   // #FFF1B8 — search term <mark> highlight
}
```

Dark mode is **out of scope for v1** but tokens must be theme-extension-backed (`ThemeExtension<AppColors>`) so adding dark later is a swap, not a rewrite. Profile screen exposes the `Appearance: System` row — wire it to a no-op or hide the row in v1, do not ship a half-working dark theme.

### 2.2 Typography

Inter, weights 400/500/600/700 only. Bundle the font file — do not load from Google Fonts at runtime (the web mock implies a CDN load; we do not want a FOUT in the Flutter shell).

```dart
class AppText {
  final TextStyle eyebrow;    // 11 / 600 / +0.10 em letter-spacing / UPPERCASE applied at site
  final TextStyle meta;       // 13 / 400 / ink2
  final TextStyle body;       // 14 / 500 / ink
  final TextStyle bodyStrong; // 15 / 600 / ink
  final TextStyle title;      // 17 / 600 / ink — section headers, sheet titles
  final TextStyle pageTitle;  // 22 / 600 / -0.01 em / ink
  final TextStyle hero;       // 32 / 600 / -0.02 em — summary-card big numbers
  final TextStyle display;    // 42 / 600 / -0.02 em — onboarding/goal hero number
}
```

**Tabular figures** (`fontFeatures: [FontFeature.tabularFigures()]`) are applied to every numeric `Text` widget. Don't apply globally to body text via theme — it would break headlines. Provide a `NumberText` widget (see component inventory) that always wraps tabular figures.

### 2.3 Spacing & radii

Both are flat `double` constants. Do not use raw literals in widget code; reference these tokens.

```dart
class AppSpace {
  final double x05 = 2;
  final double x1  = 4;
  final double x2  = 8;
  final double x3  = 12;
  final double x4  = 16;   // canonical card padding, gap between cards
  final double x5  = 20;   // screen horizontal padding
  final double x6  = 24;
  final double x8  = 32;
}

class AppRadius {
  final double r1 = 8;     // small chips, segmented controls, search field on web
  final double r2 = 12;    // form fields, mid chips
  final double r3 = 14;    // cards (default)
  final double r4 = 16;    // hero summary card, weight summary card
  final double r5 = 18;    // active-goal hero card
  final double rPill = 999; // chips, pills, FAB
}
```

### 2.4 Borders & elevation

- **All cards**: 1 px `AppColors.line` border, flat (no shadow). Use `Container` with `BoxDecoration`, not `Card` — `Card` defaults to elevation that we don't want.
- **Shadows are reserved for two things only**: the FAB (mobile) and the weight chart area gradient. Do not add `BoxShadow` anywhere else.
- **Hover on web** uses background tint, not elevation. See section 7.

### 2.5 Where tokens live and how to consume them

```dart
// Single ThemeExtension named AppTokens, exposed as Theme.of(context).extension<AppTokens>()!
// Or shorter: context.tokens (extension getter on BuildContext).
final pad = context.tokens.space.x4;
final cardColor = context.tokens.color.surface;
```

Implementation note: a single `AppTokens` extension holding `AppColors`, `AppText`, `AppSpace`, `AppRadius` is simpler than four extensions. Make the extension `const` so `copyWith` is cheap.

---

## 3. Component inventory

The shared vocabulary. Every screen composes these. If a feature seems to want a new top-level widget, check this list first — most things are already here.

| Widget | One-line purpose | Used by | Key props |
|---|---|---|---|
| `AppScaffold` | Responsive shell: provides nav (bottom tabs / rail / sidebar), top bar, FAB slot, breakpoint-aware body. | Every authenticated screen | `title`, `child`, `actions`, `fab`, `rightRail` (expanded only) |
| `FormFactor` | InheritedWidget exposing the current breakpoint enum. | Read by any widget that branches | `FormFactor.of(context).isCompact` etc. |
| `CalorieRing` | The 88-px (mobile) / 108-px (web) progress ring with center label "812 left". | 01 day view, 01-W day view | `consumed`, `goal`, `size`, `overBudget` |
| `MacroBar` | A single horizontal macro bar with name, value, and target. Used in stacks. | 01 day view (ringcard), 01-W (right-rail card), 04 log entry (preview), 07 goals (active card) | `macro` (enum protein/carbs/fat), `value`, `target`, `compact` (mobile uses 4px bar, web uses 6px) |
| `MacroChip` | Inline "P **33 g**" used in the log-entry preview block and onboarding summary. | 04, 09 | `macro`, `value` |
| `RingSummaryCard` | The full ring + macros card. Wraps `CalorieRing` + 3× `MacroBar`. | 01 day view (mobile), 01-W (right rail card) | `daySummary` (DaySummary DTO), `compact` |
| `MealSection` | One meal: header (dot + name + total), list of `FoodRow`s, "Add food" footer. | 01, 01-W | `meal`, `entries`, `onAdd`, `onEntryTap`, `dense` (web variant) |
| `FoodRow` | A single logged entry: name, meta (serving + brand), kcal. | 01, 01-W (inside `MealSection`) | `entry` (`LogEntry` DTO), `onTap`, `onLongPress` (edit/delete) |
| `SearchResultRow` | A catalogue food in search results: thumb (OFF/YOU), highlighted name, meta, per-serving kcal. | 02 | `hit` (`FoodSearchHit`), `query` (for highlight), `onTap` |
| `QuickChipRow` | Horizontal scroll of Recent/Frequent chips with kcal subtitle. | 01 compact (between ring + meals — F2), 01-W (right rail), 02 (mobile) | `chips` (`List<FoodSearchHit>`), `title`, `onTap` |
| `FoodDetailHero` | Brand eyebrow + title + barcode pill. | 03 | `food` (`FoodDetail`) |
| `FoodSummaryCard` | Per-default-serving kcal + 3× mini macro readouts. | 03 | `food` (uses default serving) |
| `ServingList` | List of servings with the `Default` and `Synthetic` badges. Selectable in log-entry context. | 03 (read-only), 04 (selectable) | `servings`, `selectedId`, `onSelect`, `selectable` |
| `NutritionTable` | The per-100g panel: calories / P / C / F / sub-rows (sugars, saturated) / fiber / sodium. | 03, 05 (read-only preview) | `nutrition` (`NutritionPer100g`), `source` (badge text) |
| `QuantityStepper` | `−` `1.5` `+` control with quick-multiplier chips (0.5/1/1.5/2/3). | 04, 05 (servings editor), 06 (weight log dialog) | `value`, `step`, `min`, `quickMultipliers`, `onChanged` |
| `WeightStepper` | Weight-unit-aware stepper wrapping `QuantityStepper`: one field for `kg`/`lb`, two side-by-side fields (stones + pounds 0–13) for `st`. Internal model is always `Decimal kg`. | 09 (onboarding step 2), 06 (log-weight sheet), 08 (current-weight sheet), 07 (new-goal / edit-goal forms) | `valueKg`, `onChangedKg`, `unit`, `minKg`, `maxKg`, `semanticsLabel` |
| `MealChipPicker` | 4-up grid of meal icons (breakfast/lunch/dinner/snack), single-select. | 04 | `selected`, `onSelect` |
| `LogPreviewBlock` | Accent-soft tinted "Will log: 195 kcal · P 33 g · C 14 g · F 0 g" block with check icon. | 04, 09 (onboarding goal preview) | `nutrition` (`NutritionTotal`), `label` |
| `LogEntrySheet` | Bottom sheet (compact/medium) or dialog (expanded) wrapping serving picker + stepper + meal chips + date + note + preview + save. | Triggered from 02, 03, FAB | `food`, `defaultMeal`, `defaultServingId`, `onSaved` |
| `WeightSparkline` | Area-gradient line chart with optional 7-day moving avg and goal-dashed line. | 06 (large), 01-W (small inline) | `points`, `goalKg`, `showMovingAvg`, `dense` |
| `WeightSummaryCard` | Hero kg number, delta pill, start/goal/avg stats. | 06 | `summary` (derived view model) |
| `WeightHistoryList` | Date / weight / delta rows. | 06 | `entries` (`List<Weight>`) |
| `GoalActiveCard` | Dark-teal gradient hero card with kcal target, rate, macro split bar, and macro grid. | 07 | `goal` (`Goal`) |
| `GoalHistoryList` | Past goals with duration. | 07 | `goals` |
| `SettingsCard` / `SettingsRow` | Grouped settings rows with leading icon chip + label + trailing value/chev/toggle. | 08 | `rows` |
| `OnboardingStepShell` | Step indicator, scrollable body, sticky footer with primary CTA. | 09 (×3) | `step`, `total`, `child`, `primary`, `onSkip` |
| `SegmentedSelect` | Three-up segmented control (Male/Female/Other, range selectors). | 06 (1W/1M/3M/1Y/All), 07 history filters (future), 09 (sex). | `options`, `selectedIndex`, `onChange` |
| `ActivityOption` | Radio-style large list option with title + sub. | 09 | `selected`, `title`, `subtitle`, `onTap` |
| `GoalOption` | Icon + title + subtitle big tappable card. | 09 | `selected`, `iconBuilder`, `title`, `subtitle`, `onTap` |
| `LogFoodFab` | The bottom-right FAB. Compact only. | 01, 06 (variant: "Log weight") | `label`, `icon`, `onPressed` |
| `PrimaryButton` | 54-px high accent button used as sticky CTA. | 03, 04, 05, 09 | `label`, `loading`, `disabled`, `onPressed` |
| `IconButton36` | The 36×36 round icon button used in app bars and inline icon slots. | Header areas across all screens | `icon`, `onPressed`, `tooltip` |
| `Skeleton` / `SkeletonRow` | Skeleton placeholders that match `FoodRow` / `SearchResultRow` heights. | Loading states everywhere | `count`, `rowHeight` |
| `EmptyState` | Centered icon + line + optional action — used for empty meal (no entries on past date) and zero results. | 02, 06, 07 | `icon`, `title`, `body`, `action` |
| `NumberText` | Wraps `Text` with tabular figures and proper `TextStyle`. | Any rendered number | `value`, `style`, `unit` |
| `BarcodeScanButton` | Square barcode-shaped icon button next to the search bar. Mobile only. | 02 | `onScan` |
| `BarcodeScanner` | Full-screen mobile camera scanner route. | Triggered from 02, 05 | `onDetect` |
| `KeyboardShortcuts` | Web-only `Shortcuts`/`Actions` wrapper that binds `/`, `n`, arrow keys, ⌘K. | Wraps `AppScaffold` on `expanded` | `child`, `shortcuts` map |

---

## 4. Navigation & routing

**Pick `go_router` (v14+).** Reasons: it solves deep linking on all three targets (path-based URLs on web map naturally to the iOS/Android deep-link world), it has first-class `ShellRoute` for the persistent nav chrome, and the team won't have to roll their own back-stack-on-web logic. Alternatives considered: `auto_route` (more powerful but heavier codegen burden for a small surface), `Navigator 2.0` raw (too much boilerplate for screens this simple).

### Route table

URLs are what the desktop browser shows; they are also the deep-link paths on mobile. Keep them lowercase, hyphenated, and meaningful.

| Route | Path | Screen |
|---|---|---|
| `home` / `today` | `/` or `/today` (alias) | 01 Day view |
| `today.date` | `/today/:date` (`YYYY-MM-DD`) | 01 Day view at a specific date |
| `foods` | `/foods` | 02 Search (entry point from nav) |
| `foods.search` | `/foods/search?q=...` | 02 Search with query |
| `foods.detail` | `/foods/:foodId` | 03 Food detail |
| `foods.new` | `/foods/new` | 05 Create custom food |
| `foods.barcode` | `/foods/barcode/:barcode` | resolves via API → 03 Food detail |
| `weight` | `/weight` | 06 Weight log |
| `goals` | `/goals` | 07 Goals |
| `goals.new` | `/goals/new` | New goal form (modal on compact, page on expanded) |
| `me` / `profile` | `/me` | 08 Profile |
| `onboarding` | `/onboarding/:step` (1–3) | 09 Onboarding |

**Modals are not routes** unless deep-linkable. The log-entry sheet is launched imperatively (`Navigator.of(context).push` with `MaterialPageRoute` for fullscreen on compact, `showDialog` for expanded). It does **not** have a URL — closing the sheet must not push history. The food-detail page _does_ get a URL because it's shareable.

### Shell structure

```
ShellRoute (AppScaffold with bottom-tabs / sidebar)
├── /today
├── /foods (and /foods/search)
├── /weight
└── /me

Outside the shell (no nav chrome):
├── /onboarding/...
├── /foods/:foodId
├── /foods/new
└── auth screens (deferred — v1 uses dev bearer token)
```

The sidebar on `expanded` shows: Today, Foods (search), Weight, Goals, My foods. The bottom tab bar on `compact` shows: Today, Foods, Weight, Me. The discrepancy is intentional — goals and my-foods are reachable from the Me screen on compact. Trends is **not** in v1 on either surface (PM Risk 3 in `pm_decisions_flutter_ui.md`); the slot returns alongside the trends screen design in a later release.

Maintain a single `appRouterProvider` (Riverpod) so the active route is observable; nav highlighting reads from this provider, not from a separate selection state.

---

## 5. State management

**Pick Riverpod 2.x (with code generation via `riverpod_generator`).** Reasons: type-safe providers, no `BuildContext` needed for reading, excellent caching primitives (`AsyncValue`, `keepAlive`, `family`), test-friendly. `flutter_bloc` would also work but the boilerplate-to-screen ratio is higher and we don't have a complex event/state machine domain.

### Layering (strict)

```
┌─────────────────────────────────────┐
│ Screens (widgets, Riverpod consumers)│   one provider per screen at most
├─────────────────────────────────────┤
│ View models (Notifiers / providers) │   transform DTOs → presentation models
├─────────────────────────────────────┤
│ Repositories                        │   one per domain (foods, log, weights, goals, profile)
│  - cache policy lives here          │
│  - merges API + local store         │
├─────────────────────────────────────┤
│ ApiClient (generated DTOs)          │   thin HTTP layer; no business logic
└─────────────────────────────────────┘
```

- **DTOs are generated from `specs/openapi.yaml`** via `openapi-generator` (Dart dio template) or hand-rolled with `freezed` if codegen is rough. Generated DTOs are **not** the type screens consume — repositories map them into presentation models that handle nullability and units sensibly.
- **Decimals**: `Decimal` JSON fields (`weight_kg`, `grams`, nutrition values) map to `package:decimal/decimal.dart`. Do not use Dart `double` for these — the spec explicitly warns about float round-trips. Format for display via a single `formatDecimal` helper.
- **Repositories are the only thing that talks to `ApiClient`.** Screens never see HTTP. View models never see HTTP.

### Cache & offline

| Domain | Memory cache | Disk cache | Why |
|---|---|---|---|
| Recent foods (`GET /foods/recent`) | yes, 5 min TTL | yes (Hive box) | Mobile barcode/search flow must work offline. Last-known good is acceptable. |
| Frequent foods (`GET /foods/frequent`) | yes, 5 min TTL | yes | Same. |
| Food detail (`GET /foods/{id}`) | yes, until route disposed | yes, by id | Detail data rarely changes; cache aggressively for the barcode flow. |
| Day summary (`GET /days/{date}/summary`) | yes, today is live | no | Don't ship stale calorie counts after the user moves around devices. Refresh on app foreground. |
| Log entries (`GET /log`) | yes, by date range | no | Day-view shows today only; pull fresh on focus. |
| Search results (`GET /foods/search`) | yes, in-memory LRU by `q` | no | Online-only; show "offline — try recents" empty state. |
| Goals (`GET /goals/active`) | yes | yes | Active goal drives the ring everywhere; cache so the ring renders instantly. |
| Weights (`GET /weights`) | yes | yes | Drives sparkline; cache for instant render. |
| Profile (`GET /me`) | yes | yes | Drives onboarding gates and units; cache it. |

- **Offline write queue**: mobile-only outbox for `POST /log` (the on-the-go logging path). Optimistic insert into the day summary, prepend a `FoodRow` with a "pending sync" badge, flush on connectivity return. Web surfaces the error inline (the sheet stays open with input intact). All other write paths — custom food creation, weight entries, goal mutations, profile edits — are online-only on every form factor: surface the error. See "Outbox (mobile-only)" below and `pm_decisions_flutter_ui.md` Risk 6.
- **Optimistic updates**: yes for `POST /log` (insert into the day summary immediately, roll back on error), `POST /weights` (prepend to sparkline), `POST /goals/{id}/default`. Not for new-food creation.

### Outbox (mobile-only)

Per PM Risk 6 ruling — the architect's original "no queue, surface the error" stance is **overridden** for the on-the-go logging scenario.

- **Scope**: `POST /log` only. Custom-food creation, weight entries, goal mutations, and profile edits are not queued — they require connectivity, and the user is informed inline.
- **Form factor gate**: `FormFactor.isCompact` only. Medium and expanded breakpoints (including desktop web) keep the surface-the-error behavior.
- **Storage**: a Hive box `outbox_log` keyed by client UUID, holding the `LogEntryCreate` payload + `queuedAt` timestamp + `attempt` count.
- **Flush**: a `connectivityProvider` (via `connectivity_plus`) drives a `LogOutboxNotifier`. On regaining connectivity, drain serially with exponential backoff (1 s, 4 s, 16 s; cap at 3 attempts before surfacing the entry to the user with a retry affordance).
- **Conflicts**: the server is authoritative. If a queued entry returns with a different `id` or a different nutrition snapshot than the client predicted, replace the optimistic row with the server response — do not merge.
- **UI**: see section 6 "Offline log outbox" for the rendering rules (badge, animation, tab-indicator dot).

### Auth

V1 runs against the dev bearer token (`DEV_AUTH_BYPASS`). Wire a single `authTokenProvider` that returns the token; the `ApiClient` reads from it via an interceptor. When real auth lands (issuer + external_id), only the provider changes.

---

## 6. Mobile-specific affordances

### Barcode scanning

- **Package**: `mobile_scanner` (^5.x). Active maintenance, modern API, supports ML-Kit on Android and AVFoundation on iOS, web is a no-op (which we want — see section 7).
- **Flow**: tap the barcode icon next to the search input (screen 02) or the barcode field in custom-food (screen 05) → push `/foods/barcode/scan` (an internal modal route, not a deep link) → on detection call `GET /foods/barcode/{code}` → on 200 push `/foods/:foodId` and open the log-entry sheet immediately; on 404 push `/foods/new?barcode=...` prefilled.
- **Permission UX**: the system permission dialog is sufficient on first invocation. On subsequent denials, show a quiet inline state in the scanner view ("Camera access is off. [Open settings]") — do not block the user from manual search.
- **Haptics**: `HapticFeedback.lightImpact()` on successful scan; `mediumImpact` on log save (screen 04); no haptics on navigation.

### Keyboard handling

- **Quantity stepper** (`QuantityStepper`): the value is a `TextField` *and* a `+/−` pair. Tap on the value opens a numeric keyboard (`TextInputType.numberWithOptions(decimal: true)`). Steppers commit on blur or on `+/−` tap.
- **Forms** (custom food, profile, onboarding): use `TextInputAction.next` between fields, `done` on the last. Provide `keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag` on any scrollable form.
- **Avoid the system back gesture stealing the bottom sheet drag.** `DraggableScrollableSheet` with explicit `snap: true` and snap-points `[0.5, 0.88]`.

### One-handed reachability

- FAB stays bottom-right at `padding.right + 20, padding.bottom + 24`.
- Primary CTAs (Add to log, Save, Continue) are always within thumb reach: bottom of the screen with safe-area padding, never floating in the middle.

### Offline log outbox

Data layer in section 5. UX rules:

- A pending-sync `FoodRow` is **interactive** but its right-side overflow is restricted to "Retry now" and "Discard". No edit until the server confirms the entry.
- The "Pending sync" badge sits in the meta row beneath the food name (10 px text, `AppColors.ink3` background, 4 px radius), never adjacent to the calorie number — T-09 keeps numbers free of sync UI noise.
- On flush success, fade the badge out over 200 ms with a `FadeTransition`; do not move or re-flow the row. Day-summary numbers may move by the row's contribution — they already animate via the providers' normal rebuild path.
- If the outbox has ≥ 1 pending entry, the Today bottom-tab icon gets a 6 px accent dot (not a count). Clears when the outbox drains.
- On terminal failure (3 attempts exhausted) the badge flips to a danger-tinted "Retry" affordance; tap re-opens the log-entry sheet pre-populated so the user can correct and resubmit.

### Background refresh

V1 does not run background tasks. On `AppLifecycleState.resumed`, invalidate the day-summary provider so the ring is fresh when the user comes back from another device.

---

## 7. Web/desktop-specific affordances

### Keyboard shortcuts (`expanded` only)

Bound globally via a single `Shortcuts`/`Actions` wrapper inside the shell. Do **not** bind these on mobile-web — on a phone they're noise.

| Key | Action |
|---|---|
| `/` | Focus the top-bar search input |
| `⌘K` / `Ctrl-K` | Open the command-palette dialog (a centered overlay variant of the search route) |
| `n` | Open the log-entry sheet for "Add food → most recent" (skip search if there's a recent) |
| `g t` | Go to Today |
| `g f` | Go to Foods |
| `g w` | Go to Weight |
| `g o` | Go to Goals |
| `Esc` | Close any open modal/sheet/dialog |
| `↑` / `↓` in serving lists and search results | Move selection |
| `Enter` | Activate focused row |

### Hover

Mobile mocks do not show hover states. Define the rule once: any tappable surface gets `MouseRegion(cursor: SystemMouseCursors.click)` plus an `InkResponse` or `AnimatedContainer` whose background interpolates between transparent and `AppColors.line2` over 80 ms on hover. The accent stays untouched — we do not use accent for hover. Cards do not "lift" on hover (no shadow change).

### Focus rings

Use `FocusableActionDetector` + a 2 px `AppColors.accent` outline at 2 px offset for any interactive element that can receive keyboard focus. Mobile: focus rings are disabled by default; only show them when the user is navigating with an external keyboard (rare).

### Right rail

The Quick add card on the right rail is *the* desktop affordance the designer chose for "log without leaving today". On `expanded`, tapping a chip opens the log-entry dialog with that food preselected and the *current* meal preselected (current meal = nearest by local time-of-day; default to Snack when ambiguous).

### No barcode UI on web

`BarcodeScanButton` returns `SizedBox.shrink()` when `FormFactor.isWeb` and `!isCompact` (i.e., on desktop web). In the custom-food form, the barcode field becomes a plain `TextField` with a "Use the mobile app to scan" helper. Do not show a placeholder camera dialog.

### Window resizing

The shell rebuilds the nav chrome at breakpoints. Test resizing the desktop browser from 1400 → 400 → 1400 and confirm no state is lost (the `ShellRoute` keeps its child alive; provider state persists).

---

## 8. The TENANTS

The non-negotiables. Number them so review comments can cite them by ID (e.g., "Violates T-04"). A reviewer should be able to point at a violation.

1. **T-01 Token discipline.** Never write a raw hex, raw padding number, or raw radius in widget code. Always read from `context.tokens` (or a sub-token). The exceptions are inside the four token files themselves.

2. **T-02 Tabular figures everywhere.** Any rendered number — kcal, grams, percentages, dates with digits, weights — goes through `NumberText` or uses `fontFeatures: [FontFeature.tabularFigures()]`. Numbers must not "jitter" as values change.

3. **T-03 Macro colors are data-only.** Protein/Carbs/Fat colors are reserved for bars, dots, and mini-macro values that label a macro. Never use them for buttons, links, focus, branding, dividers, or non-macro icons.

4. **T-04 Accent teal is for primary actions and "on-track".** The CalorieRing fill, primary buttons, FAB, active nav, accent badges, and the "Will log" preview block use accent. **Never decorative.** Never as a brand wash. If a screen wants more accent, refactor — it's wrong.

5. **T-05 Over-budget macros use `AppColors.dangerOver`.** Whenever a macro bar's `value > target`, the bar fill switches to `dangerOver` (the rest of the bar stays `line2`). The value text stays `ink`; only the bar fill changes. Same rule for the kcal "left" label on the ring — if `consumed > goal`, show "−123 over" in `dangerOver`. **Token disambiguation:** Over-budget arc/bar fill uses `colors.dangerOver` (brighter orange-red). Sign-out + per-field error borders use `colors.danger` (muted red). The two tokens are distinct and not interchangeable.

6. **T-06 Touch target floor.** Every actionable element has ≥ 44 × 44 hit slop on mobile (`InkResponse` `radius`/`containedInkWell`). Visual size may be smaller (e.g., 32-px stepper buttons sit in 48-px containers). On `expanded` (mouse), ≥ 32 × 32 visual targets are acceptable.

7. **T-07 Numeric inputs always have a stepper.** Any field that accepts a decimal — quantity, weight in kg, custom-food nutrition values — provides a `QuantityStepper` (or a stepper-shaped affordance) next to or wrapping the raw input. Never a bare `TextField` for a number.

8. **T-08 Loading states are skeletons that match final layout.** When fetching, render `Skeleton` rows whose `rowHeight` equals the final widget's height (`FoodRow`, `SearchResultRow`, `MealSection`). Never a centered `CircularProgressIndicator` over a list. The day-view's CalorieRing may show a 700 ms shimmer over its stroke, not a spinner.

9. **T-09 One source of truth for numbers.** The CalorieRing, the ring summary card, the right-rail summary card, and the log-entry preview must all derive from the same provider (`daySummaryProvider`) for the same date. Don't read `LogEntry` lists in one place and `DaySummary` in another to compute the same total — they will drift.

10. **T-10 Synthetic 100 g servings are always visible.** Per design decision in INDEX.html, the synthetic 100 g serving is rendered in `ServingList` with a `Synthetic` badge. Do not hide it even when an OFF default exists. If a future PM decision flips this, change the rule in one place: `ServingList(synthetic: SyntheticVisibility.show)` — never per-screen.

11. **T-11 Errors are inline, not modal.** Per-field errors live under the field (red `help` text + red border, see screen 05). Save failures show a `SnackBar` that doesn't dismiss the sheet. Modals (`AlertDialog`) are reserved for destructive confirmation (delete log entry, sign out, delete goal).

12. **T-12 The FAB is the only floating action.** No floating help buttons, no floating dismissers, no floating "back". Sticky bottom CTAs (`PrimaryButton`) sit inside a `BottomAppBar`-shaped footer with a top divider — they are not floating.

13. **T-13 No spinners on a populated list.** A list with data + a pending refresh shows a `RefreshIndicator` on mobile and a quiet 2-px top progress bar on web. Never replace existing content with a spinner.

14. **T-14 Routes are addressable, sheets are not.** If a state needs to be deep-linked or browser-back-able, it's a route (food detail, custom food, goals). If it's modal interaction that doesn't survive reload, it's a sheet/dialog (log entry, delete confirm).

15. **T-15 Form factor branches happen at the screen root, not deep in the tree.** A leaf widget renders the same on all breakpoints. If a screen needs different leaves, the screen file owns both and picks at the root. Don't sprinkle `if (isCompact)` through `MealSection`.

16. **T-16 Server time-of-day is server's problem.** All dates on the wire are `YYYY-MM-DD` in the user's local sense (per API). Convert with `DateTime.now()` and `DateFormat`, never with UTC math. The "Today" string is `DateFormat('EEEE, MMM d')` of the user's local now.

17. **T-17 Decimal in, formatted out.** Anywhere we touch a wire value — `weight_kg`, `grams`, `calories_kcal` — use `package:decimal`. Format at the leaf via `formatDecimal(value, fractionDigits: ...)`. Never `double.parse` a wire string.

18. **T-18 Provider invalidation is explicit and minimal.** After a mutation, the repository invalidates only the providers whose data could have changed. Do not call `ref.invalidate(everythingProvider)` — it will cause the ring to flicker on every save.

19. **T-19 No new HTML/SVG dependencies on web.** Charts use `flutter_charts` or a custom `CustomPainter`. We do not ship `package:web` SVG, and we don't embed the mock's inline SVGs verbatim.

20. **T-20 Accessibility minimums.** Every `IconButton36` has a tooltip and a `Semantics` label. Every chip and row has a usable semantic label that includes the rendered number ("Greek yogurt, 130 kilocalories"). Color is never the sole signal — over-budget macros also get a small "over" suffix in their label.

21. **T-21 Display units are customer-expected, not canonical.** All quantities render in the units a customer expects — sodium in `mg`, body weight in the user's chosen unit (`kg` / `lb` / `st`, persisted on `User.weight_unit` with a locale-aware default), macros in `g`, energy in `kcal`. The wire stays canonical SI (body weight on `WeightEntry` is still `weight_kg`). Conversion lives in `lib/domain/units/` and is the **only** place a unit transform happens; `formatWeight(Decimal kg, WeightUnit unit)` and `parseWeightToKg(String raw, WeightUnit unit)` are the bidirectional seam. Widgets never multiply or divide by 1000 or 2.2046226 inline, never call `.toFixed` on a raw `Decimal` macro value. See `pm_decisions_flutter_ui.md` Display Units Principle for the full rulings (including how `NutritionPer100g.sodium_g` is exposed as `sodiumMg` in the presentation model, and the kg/lb/st addendum dated 2026-05-16).

22. **T-22 Pending-sync state is visible, not silent.** An optimistically-inserted log entry awaiting flush from the outbox renders with a `Pending sync` badge until the server acks (T-22 is enforced only on `FormFactor.isCompact` — the outbox doesn't exist elsewhere). Never silently retry without surfacing. Never drop a queued entry without telling the user. See section 6 "Offline log outbox".

23. **T-23 Shared widgets are package-imported.** Every widget that appears in the §3 component inventory lives at `lib/widgets/<name>.dart` and is imported by call sites via `package:fulfilled/widgets/<name>.dart`. Feature folders may not import widgets from sibling feature folders. A feature-private widget that the inventory does not list stays inside that feature's `widgets/` directory and is private to the feature. Enforced by `tool/lint_no_cross_feature_widget_import.sh` (see T-005).

24. **T-24 Post-mutation navigation follows one of three patterns.** After a save / mutation succeeds, the screen must land the user via exactly one of: (1) *pop-to-source* — `Navigator.pop()` returning to the screen that launched the editor (profile editors, log-weight sheet, goal editors); (2) *route-to-effect* — `context.go(target)` to a route that renders the mutation's effect, when that route is not the source (`LogEntrySheet` save → `/today/:consumedOn`, onboarding finish → `/today`); (3) *pop-with-payload* — `Navigator.pop(value)` returning the result so the source view can re-render against it (`CustomFoodScreen(existing:)` → updated `Food`). Each save handler's dartdoc names the case. New sheets are reviewed against this decision; the case is explicit, not inferred. Dialog-on-expanded sheets that use `context.go` must `pop()` the dialog first so the route change doesn't orphan a dialog frame.

---

## 9. Per-screen build briefs

Each brief tells a developer agent (a) what to compose, (b) what to fetch, (c) what's different on web, and (d) the gotcha.

### Screen 01 — Day view (compact)

- **Compose**: `AppScaffold` + `header` (avatar + search icon) + `datebar` (date with chevrons) + `RingSummaryCard` + scrollable `Column` of four `MealSection`s + `LogFoodFab` + bottom `TabBar`.
- **Data**: `daySummaryProvider(date)` (returns `DaySummary`), `logEntriesProvider(date)` (grouped client-side by meal — server `by_meal` gives subtotals but not the entries themselves, so we still need `/log`).
- **Web transform**: see 01-W below — entirely different screen file.
- **Gotcha**: empty meal dinner card still shows the header with `0 kcal` and a dimmed dot color (`#D9D6CD`, not the accent). Don't suppress the section. Don't reuse the same dot color constant from `MealSection` — it's a deliberate per-empty state.
- **Post-save**: n/a — no save handler.

### Screen 01-W — Day view (expanded)

- **Compose**: `AppScaffold` (sidebar variant) + top bar (page title + date chevrons + search input + `PrimaryButton` Log food) + 2-column `content`: left is `MealSection` 2×2 grid (`GridView.count(crossAxisCount: 2)` or `Wrap`), right is a column of three cards (`RingSummaryCard`, Quick add `QuickChipRow`, mini `WeightSparkline`).
- **Data**: same providers as compact + `recentFoodsProvider` and `frequentFoodsProvider` for the right rail, `weightSeriesProvider(range: '30d')` for the sparkline.
- **Web transform**: this *is* the web. At `medium` width (≥ 600, < 1024), collapse to the compact stack with the right-rail cards inserted as a horizontal row below the meal grid.
- **Gotcha**: the right-rail Quick add card opens the log-entry **dialog** (not bottom sheet) — make sure the chip → log flow goes through the same `LogEntrySheet` widget, just in a different shell. The card heights must align: ring card sets the rhythm, others fit. Use `IntrinsicHeight` sparingly — prefer fixed min-heights.
- **Post-save**: n/a — no save handler.

### Screen 02 — Search

- **Compose**: top bar (back + `SearchField` + `BarcodeScanButton`) + body: section header "Recent" + `QuickChipRow` + "Frequent" + `QuickChipRow` + results section header (with count) + `SearchResultRow` list.
- **Data**: `recentFoodsProvider`, `frequentFoodsProvider`, `foodSearchProvider(query: q, debounceMs: 250)`. Debounce in the provider, not in the widget.
- **Web transform**: lives inside the shell. Top bar shrinks, results list expands to fill the main pane. On `expanded` with ⌘K, render in a centered dialog (max-width 640, max-height 70vh).
- **Gotcha**: the search-term highlight uses `RichText` with `AppColors.highlight` background on the matching substring (case-insensitive). Don't naive-substring — multi-word queries split on whitespace and each word gets highlighted independently. Highlight `<mark>` color from the mock is `#FFF1B8`.
- **Post-save**: n/a — no save handler.

### Screen 03 — Food detail

- **Compose**: top bar (back + save + overflow) + scroll body: `FoodDetailHero` + `FoodSummaryCard` + section "Servings" + `ServingList` (read-only) + section "Nutrition" + `NutritionTable` + sticky bottom `PrimaryButton` "Add to log".
- **Data**: `foodDetailProvider(foodId)` returns `FoodDetail` (includes `servings` and `nutrition`).
- **Web transform**: drop the sticky bottom CTA, put the "Add to log" button in the top bar on the right. Two-column body on `expanded` — left is hero + servings, right is nutrition.
- **Gotcha**: the `quality_score` from the API (`0–1.0` decimal per the schema, `0.86` shown in mock as "quality 0.86") is displayed in the nutrition top-right meta. Render it only when source is `off`; for `user` and `usda` foods, replace with the source label.
- **Post-save**: n/a — no save handler.

### Screen 04 — Log entry (sheet)

- **Compose**: `LogEntrySheet` = sheet container + header (brand eyebrow + food title + close) + scrollable form: Serving select → `QuantityStepper` with quick chips → `MealChipPicker` → date row → optional note `TextField` → `LogPreviewBlock` + sticky footer `PrimaryButton` "Save to log".
- **Data**: receives `FoodDetail` (already fetched), `defaultMeal` (computed from time-of-day), `defaultServingId` (from `food.servings.firstWhere(is_default)`). The "Will log" preview is computed client-side: `nutrition_per_100g × (serving.grams / 100) × quantity`. On save, POST `/log` with `food_id`, `serving_id`, `consumed_on`, `meal`, `quantity`, optional `note`.
- **Web transform**: dialog, max-width 480, no grabber, no bottom safe-area padding. Otherwise identical.
- **Gotcha**: quick-multiplier chips (0.5×, 1×, 1.5×, 2×, 3×) must mirror the stepper value in both directions — tap a chip → stepper value updates; type a value → chip selection clears or matches. Use a single Riverpod `quantityProvider` for the sheet, not separate widget state. Also: the preview block uses `LogPreviewBlock`, **not** macro colors — its label is accent-soft tinted and macro values inside are `ink` (the macro names like "P" are `accent`).
- **Post-save**: Case 2 — `context.go('/today/:consumedOn')` for both create and edit (edit's target uses the entry's date, which may differ from the source). Implementation lands in QL-105.

### Screen 05 — Custom food

- **Compose**: top bar (cancel + title + save) + step indicator (Details / Nutrition / Servings) + scroll body: Basics section (name, brand, barcode) + Nutrition per 100g section (calories single field, P/C/F row, Fiber/Sugar/Sodium row) + Servings section with `ServingList` editor + sticky footer `PrimaryButton` "Fix N errors to save" / "Save".
- **Data**: form state lives in a `customFoodDraftProvider` (Riverpod `Notifier`). On save: POST `/foods` with the basics + nutrition; iterate POSTs to `/foods/{id}/servings` for each user-defined serving (the 100 g system serving is auto-seeded — do not create it client-side).
- **Web transform**: the three-step indicator becomes a horizontal tabs row; the form lays out as 2 columns (basics + nutrition on the left, servings on the right).
- **Gotcha**: required-field validation is `name` and `nutrition.energy_kcal` per the OpenAPI; the mock shows Carbs as "Required" in error state, which is **stricter than the API**. Treat the client validation as additive: client requires P, C, F, kcal. Don't try to round-trip a partial nutrition through the server.
- **Post-save**: Case 1 (create) — `context.pop(food)`; the search caller doesn't need the food back but the new-food detail-route may consume the id. Case 3 (edit) — `context.pop(updatedFood)` so `/foods/:id` re-renders against the new data.

### Screen 06 — Weight log

- **Compose**: top bar (title "Weight" + calendar icon + overflow) + `WeightSummaryCard` (now, delta pill, start/goal/avg stats) + `WeightSparkline` chart card (range segmented + chart + axis labels) + `WeightHistoryList` + `LogFoodFab` variant ("Log weight").
- **Data**: `weightSeriesProvider(range)` (1W/1M/3M/1Y/All), `weightHistoryProvider(limit: 10)`, `activeGoalProvider` for the dashed goal line and stats.
- **Web transform**: hosts inside the shell. The summary card and chart can sit side-by-side at `expanded`. FAB → top-bar `PrimaryButton`.
- **Gotcha**: the chart shows two lines — actual weight (solid accent) and 7-day moving avg (dashed `ink3`). The moving-avg is computed client-side, not requested from the server. Use `package:decimal` for the math; never `double`. Empty state for ranges with zero entries: a single dashed goal line + "Log your first weight" CTA, not a placeholder chart.
- **Post-save**: Case 1 — `Navigator.pop()`; `/weight` is already underneath and re-renders against the invalidated weight providers.

### Screen 07 — Goals

- **Compose**: top bar (title + overflow) + `GoalActiveCard` (dark gradient hero with kcal, rate pill, split bar + legend, macro grid, Edit current / + New goal buttons) + section "History" + `GoalHistoryList`.
- **Data**: `activeGoalProvider`, `goalsProvider` (all goals; filter history client-side as `ended_on != null OR id != active.id`).
- **Web transform**: hero card stays full-width but pulls in to a max-width 720; history below it. Edit/New are dialogs on web, full-screen routes on mobile.
- **Gotcha**: the `GoalActiveCard` uses *lighter* macro shades than the standard macro tokens (the mock paints them at `#E8AE7C / #B7CC8A / #DDB985` against the dark teal). Define them as `AppColors.proteinOnDark / carbsOnDark / fatOnDark` in tokens — do not derive at the call site with opacity. Same rule for `#A9CBC8` (the muted-teal text-on-dark). They are extra tokens, not new colors.
- **Post-save**: Case 1 — `Navigator.pop()` (or `Navigator.maybePop()` from the dialog host); `/goals` is already underneath and the invalidated goal providers drive its re-render.

### Screen 08 — Profile & settings

- **Compose**: top bar (title "Me") + identity row (avatar + name + email + Edit) + sections Body / Preferences / Data, each a `SettingsCard` + sign-out `OutlinedButton`-shaped row in danger color + footnote with version.
- **Data**: `meProvider` (`User`), `customFoodCountProvider`. Editing fields jumps to inline edit routes (`/me/sex`, `/me/height`, `/me/activity`) or in-line modals; pick modals on `compact` for fewer routes.
- **Web transform**: same shell. Identity row scales up; the cards stack at the same rhythm.
- **Gotcha**: per PM Risk 5, the Appearance row is **removed entirely** from v1 — do not render the toggle, even disabled. Dark-mode tokens ship with v2 alongside a designer hand-off.
- **Post-save**: Case 1 — every profile editor (`HeightStepperSheet`, `CurrentWeightSheet`, `SexPicker`, `BirthDatePicker`, `ActivityLevelPicker`, `WeightUnitChooser`) pops back to `/me`, which re-reads `meProvider` and re-renders the just-edited row.

### Screen 09 — Onboarding (3-up)

- **Compose**: each step uses `OnboardingStepShell`. Step 1: welcome hero with logo + headline + features list + Get started. (Per PM Risk 2, the "I already have an account" link is **removed** from v1; it returns alongside real auth in v2.) Step 2: form (sex `SegmentedSelect`, birth date picker, height + weight 2-col, activity level `ActivityOption` list). Step 3: goal direction `GoalOption` list + rate slider + `LogPreviewBlock`-shaped target preview.
- **Data**: an `onboardingDraftProvider` (`Notifier`) accumulates the partial profile and partial goal. Step 3 derives the daily-calorie target client-side using a standard Mifflin-St Jeor or Harris-Benedict formula (whichever the backend uses — confirm in section 10). On finish: PATCH `/me`, then POST `/goals`.
- **Web transform**: at `expanded`, render all three steps as a 3-column "tour" on a single page (PM may push back — see open questions). Default in v1: still one step at a time, but at `expanded` constrain the form column to 520 px max-width centered.
- **Gotcha**: the daily-target calculation must match the server's calculation when the goal is later patched — the server stores `daily_calorie_target` as an int (per OpenAPI). Round on the client the same way the server rounds. Fence the calculation in one place: `lib/domain/calories/estimate.dart`.
- **Post-save**: Case 2 — `context.go(Routes.todayPath)`; the just-saved profile + goal's natural home is the day view, not a return to step 3.

---

## 10. Open questions / flagged risks

Things the designer did not specify or where I'm making an architectural call the PM/designer should confirm.

> **PM rulings applied 2026-05-15** — see `specs/pm_decisions_flutter_ui.md`. Items **1, 5, 6, 8, 11, 12** below are resolved; the resolution is noted inline. Items **2, 9, 10** were resolved by the PM rulings in `pm_overnight_features.md` ("PM rulings on open §10 items"). Items **3, 4, 7** remain open with v1.1 dispositions.
>
> **Addendum applied 2026-05-16** — Features A and B from `specs/pm_log_edit_and_units.md` / `specs/architect_log_edit_and_units.md` shipped. Item **8**'s "kg-only in v1" rider is superseded: body weight is now user-selectable (`kg` / `lb` / `st`) per `User.weight_unit`, with a locale-aware default at first onboarding submit. The OFF→mg sodium conversion remains the original §4 ruling and is untouched. T-21 wording updated above; the §3 component inventory now lists `WeightStepper`; PM Risk 4's "lb deferred to v2" rider is marked **resolved** in `specs/pm_decisions_flutter_ui.md`. No new tenants — §5 of the architect plan confirmed that the existing T-21 / T-22 cover the surface (edit-mode reuses `LogEntrySheet` via `existing:`, and the outbox does **not** queue edits — pending rows are gated by their `isPendingSync` flag, matching T-22). Backend ticket **BE-001** (Rust migration adding `weight_unit`) is pending; the client tolerates a missing field by defaulting to `kg` until it lands.
>
> **Addendum applied 2026-05-16 (QoL pack)** — see `specs/architect_qol.md` / `specs/dev_tickets_qol.md`. T-24 added; no other tenants. The per-screen briefs gain `Post-save:` annotations; no shape changes. The Refactor 3 (`@invalidates` doc-tag) pass is documentation-only and lives in the repository dartdocs — there is no spec surface change beyond what this addendum names. QL-105 lands the only behavioural consumer of T-24 (the `LogEntrySheet` save → `context.go('/today/:consumedOn')` swap, Case 2).

1. **Over-budget macro behavior.** **RESOLVED (PM Risk 1):** strict `value > target`, no tolerance. T-05 already encodes this.

2. **Synthetic 100 g serving visibility.** **RESOLVED (PM ruling on §10 item 2):** the synthetic 100 g serving is **always visible**, even when an OFF default serving exists. T-10 stands as written and moves from "architect ruling" to "PM-blessed." Reason: the 100 g basis is what the nutrition panel uses (Display Units Principle), so showing the corresponding serving keeps the math reconcilable for the user.

3. **Barcode-equivalent on desktop.** Web has no barcode UI. The web mock's top-bar search input says "Search foods or scan barcode…" — that placeholder implies parity. Decision: drop "scan barcode" from the web placeholder (use "Search foods or paste a barcode…" instead, which is a valid `/foods/barcode/:code` shortcut if input is all digits 8–14 long). PM/copy review needed.

4. **Onboarding on web.** I'm defaulting to one step at a time even on desktop because the form is short and consistency wins. If PM wants the 3-up tour as a marketing-style page, treat it as a separate web-only screen.

5. **Trends tab is a stub.** **RESOLVED (PM Risk 3):** hide entirely from both nav surfaces. Route removed; sidebar prose updated; compact bottom tabs now Today / Foods / Weight / Me.

6. **Dark mode in the profile screen.** **RESOLVED (PM Risk 5):** remove the Appearance row entirely from v1. Returns with v2 dark-mode token sweep.

7. **Profile editing flow.** No editor screens were mocked. I'm proposing per-field route or modal (sex picker, date picker, height stepper, activity selector reusing onboarding's `ActivityOption`). Designer might prefer a single full editor screen — flag for review.

8. **Sodium units.** **RESOLVED (PM Risk 4):** sodium displays as `mg` everywhere. Conversion lives in `lib/domain/units/sodium.dart` (T-21), not in repositories. No OpenAPI shape change — only a clarifying sentence on `NutritionPer100g.sodium_g`. The Display Units Principle in `pm_decisions_flutter_ui.md` generalises the rule across sodium, weight, energy, and macros.

9. **Decimal precision for display.** **RESOLVED (PM ruling on §10 item 9):** encoded in `lib/domain/decimal_format.dart`. kcal: integer, banker's rounding (half-to-even). Macros (g): integer when ≥ 10 g, one fraction digit when < 10 g (same rule for sugar, sat fat, fiber). Sodium (mg): integer always. Body weight (kg): one fraction digit always. Quantity (stepper multiplier): up to two fraction digits while typing, rounded to one on commit; quick-multiplier chips snap exactly. Rate (kg/week): two fraction digits. Rounding is half-to-even to match the server.

10. **Quality score visibility.** **RESOLVED (PM ruling on §10 item 10):** **hide the numeric score** in user-facing copy. Replace `"OFF data · quality 0.86"` with just the source label (`"OFF data"`, `"USDA data"`, `"Your food"`). The score stays on the wire and in the DTO for future use (sorting, ranking, debug surfaces). Add a code comment noting the score is intentionally hidden pending a v2 ranking ticket.

11. **Offline log creation.** **RESOLVED (PM Risk 6 — architect overridden):** ship a mobile-only outbox scoped to `POST /log` with optimistic insert + pending-sync badge. Section 5 ("Outbox") and section 6 ("Offline log outbox") updated; T-22 added. Web keeps the surface-the-error behavior.

12. **The "I already have an account" path on onboarding step 1.** **RESOLVED (PM Risk 2):** the link is **removed** from v1. Returns alongside real auth in v2. Screen 09 brief updated.

---

## Appendix: directory layout

Suggested top-level. Developer agents should follow this — don't invent siblings.

```
client/
  pubspec.yaml
  lib/
    main.dart
    app.dart                       // App root, ProviderScope, MaterialApp.router
    theme/
      tokens/
        colors.dart                // AppColors
        text.dart                  // AppText
        space.dart                 // AppSpace
        radius.dart                // AppRadius
      tokens.dart                  // AppTokens ThemeExtension
      theme_data.dart              // light theme assembly
      context_extensions.dart      // context.tokens, context.spacing, etc.
    routing/
      app_router.dart              // go_router config
      routes.dart                  // route names + path constants
    form_factor/
      breakpoints.dart
      form_factor.dart             // InheritedWidget + enum
    data/
      api_client.dart              // generated dio client
      auth_token.dart              // authTokenProvider
      connectivity.dart            // connectivityProvider (connectivity_plus)
      dtos/                        // generated DTOs from openapi.yaml
      outbox/                      // mobile-only POST /log queue (T-22)
        log_outbox_notifier.dart
        outbox_entry.dart
    domain/
      decimal_format.dart
      calories/estimate.dart       // BMR + TDEE math
      food_serving.dart            // value types
      units/                       // PM-mandated display conversions (T-21)
        units.dart                 // re-exports
        sodium.dart                // gramsToMilligrams, formatSodiumMg
        weight.dart                // formatWeight + parseWeightToKg over kg / lb / st (per User.weight_unit)
        energy.dart                // kcal formatter (kJ deferred to v2)
        macros.dart                // gram formatters with decimal rules
    repositories/
      food_repository.dart
      log_repository.dart
      weight_repository.dart
      goal_repository.dart
      profile_repository.dart
    providers/                     // riverpod providers (or co-located w/ screens)
    widgets/
      app_scaffold.dart
      number_text.dart
      primary_button.dart
      icon_button_36.dart
      skeleton.dart
      empty_state.dart
      calorie_ring.dart
      macro_bar.dart
      macro_chip.dart
      ring_summary_card.dart
      meal_section.dart
      food_row.dart
      search_result_row.dart
      quick_chip_row.dart
      food_detail_hero.dart
      food_summary_card.dart
      serving_list.dart
      nutrition_table.dart
      quantity_stepper.dart
      meal_chip_picker.dart
      log_preview_block.dart
      log_entry_sheet.dart
      weight_sparkline.dart
      weight_summary_card.dart
      weight_history_list.dart
      goal_active_card.dart
      goal_history_list.dart
      settings_card.dart
      onboarding_step_shell.dart
      segmented_select.dart
      activity_option.dart
      goal_option.dart
      log_food_fab.dart
      barcode_scan_button.dart
      keyboard_shortcuts.dart
    features/
      today/                       // screen 01 + 01-W (split files okay)
      search/                      // screen 02
      food_detail/                 // screen 03
      log_entry/                   // screen 04 (the sheet, plus its providers)
      custom_food/                 // screen 05
      weight/                      // screen 06
      goals/                       // screen 07
      profile/                     // screen 08
      onboarding/                  // screen 09 (×3 steps)
  test/
    widget/                        // golden tests per widget, both breakpoints
    integration/                   // log-a-food flow, scan-a-barcode flow
```

One screen = one feature folder. Shared widgets live in `widgets/`. If something is used by exactly one screen, it stays inside that feature folder.
