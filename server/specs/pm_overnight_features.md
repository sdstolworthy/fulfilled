# PM Overnight Features: Production-feeling v1

PM staging for overnight developer agents. The Rust API is frozen until
morning — every item below is client-only work that an agent can pick up,
finish, and review without touching the wire. The architecture doc and
prior PM decisions (`flutter_ui_architecture.md`, `pm_decisions_flutter_ui.md`)
are the tiebreakers; this doc is the priority filter and the per-feature
acceptance contract.

## Theme / north star

The nine screens are *shipped* but *raw*. The user can click through every
route against fake data, but the seams show: shared widgets are
duplicated screen-to-screen, one of the architecture-named screens
(`/foods/mine`) was never built, two repository methods are stubbed with
TODOs, the calorie-estimate math sits in the wrong directory, and the
empty/error/loading story varies meaningfully between screens. Overnight
the goal is to **make the existing surface production-feeling** —
clear the consistency debt, build the one missing destination, and resolve
the open §10 product questions that are blocking developer ambiguity.
We add new product surface only where it unblocks "navigable end-to-end."
Polish work — animations, hover states, keyboard shortcuts, the font
file — lands in Tier B after the consistency floor is set.

---

## Tier A — must ship overnight

The non-negotiables. These six features clear the largest amount of
"why isn't this in the shared layer yet?" debt, build the one named
screen we haven't built, and unblock developer ambiguity on three open
§10 questions. Agents should land Tier A before pulling from Tier B.

### A1. Shared widget lift to `lib/widgets/`

**One-sentence summary**: Move the seven widgets that screen agents
inlined into their feature folders into `lib/widgets/` per the architecture
doc's component inventory, with no behavior change.

**Why now**: The architecture doc's §3 component inventory is the
shared vocabulary every screen brief refers to. Today, `CalorieRing` and
`MacroBar` live inside `features/today/`, `QuantityStepper` is duplicated
between `features/custom_food/` and `features/log_entry/`, `ServingList`
has a read-only variant in `features/food_detail/` and an editable
variant in `features/custom_food/`, `ActivityOption` exists in both
`features/onboarding/` and `features/profile/`. Every one of these will
need to be touched by one of the other Tier-A features (the empty-state
sweep, the synthetic-visibility tenant, the new My Foods screen).
Lifting them first means each downstream agent edits a single canonical
widget instead of three near-copies that drift. T-01 (token discipline)
also gets cleaner: any hex literals that crept in during inlining get
caught in one pass.

**Acceptance criteria**
- `lib/widgets/` contains canonical implementations of `CalorieRing`,
  `MacroBar`, `RingSummaryCard`, `MealSection`, `QuantityStepper`,
  `ServingList`, and `ActivityOption`. The file list matches the
  architecture appendix exactly.
- `ServingList` exposes a `selectable` prop (false = read-only, used by
  screen 03; true = editable, used by screen 05). Same widget, one
  parameter — not two siblings.
- `QuantityStepper` is a single widget consumed by screen 04 (log entry
  quantity), screen 05 (serving grams in custom food), and screen 06
  (weight log dialog). Each call site passes its own `step`, `min`,
  `quickMultipliers`, and `unit` label. The chips-mirror-stepper bidirectional
  binding (architecture screen 04 gotcha) lives inside the widget.
- No feature folder still defines a private copy of any of these
  widgets. Imports across `features/*` resolve to `package:fulfilled/widgets/*`.
- No raw hex literals remain in the lifted widgets — all colors read
  from `context.tokens.color`. (T-01 enforcement; catches anything that
  slipped through during the first build.)
- All existing tests pass; lifted widgets keep their existing golden
  tests if any were defined, moved alongside the widget.

**Dependencies**: None. Pure refactor; do first so other Tier-A and
Tier-B features edit the canonical files.

**Effort**: L. Touches every feature folder. The risk is constructor
signature drift — be deliberate about prop names and order so call sites
break loudly rather than silently render different defaults.

---

### A2. My Foods screen at `/foods/mine`

**One-sentence summary**: Build the user-custom-foods browse screen the
architecture named but never shipped, bound to a mock-data repository
method against the existing 25-food fixture.

**Why now**: This is the only architecture-named screen we never built.
A user who created a custom food in screen 05 has literally no in-app
way to find it again — they have to remember the name and type it into
search. The desktop sidebar already lists "My foods" per the
architecture's §4 nav structure; the link goes nowhere. Building this
closes the navigability hole *and* exercises `FoodRepository.listMine()`,
which the mock data layer has the data for (we have user-source foods
in the fixture; just no list provider). The audit-followup doc PM
already specced the backend version of this — we're building the client
half against the existing fake `FoodRepository`. No wire change.

**Acceptance criteria**
- Route `/foods/mine` is registered in `app_router.dart` and reachable
  from (a) the desktop sidebar "My foods" entry (already linked, currently
  404s), and (b) a "My foods" row in the Profile screen's Data section
  on compact (per architecture §4, "goals and my-foods are reachable
  from the Me screen on compact").
- The screen lists every food where `source = 'user'` in the mock
  fixture (currently a few — exact count whatever the fixture has),
  sorted newest-first by `created_at` so the most recently created
  custom is at the top.
- Each row renders via `SearchResultRow` (the same component used in
  screen 02 results) so the visual rhythm matches search. Thumb is the
  `YOU` user-thumb variant, not the OFF variant.
- Tapping a row navigates to `/foods/:foodId` (screen 03). Long-press
  on compact opens an overflow with "Edit" (routes to `/foods/:foodId/edit`
  — a stub route that 404s for now is acceptable; this is a real future
  ticket but not tonight's work) and "Delete" (mock-only confirmation,
  no actual mutation — see "Out of scope" below).
- Empty state when the user has zero customs: `EmptyState` widget with
  icon, "No custom foods yet", "Create your own foods to find them
  faster next time", and a primary CTA "Create custom food" that routes
  to `/foods/new`. *(The mock fixture currently has user foods so we
  test this by temporarily filtering them; a small test fixture toggle
  is acceptable.)*
- In-list filter: a `TextField` at the top filters the list as the user
  types, case-insensitive substring match on name. No debounce needed —
  the list is purely local. Empty after filtering: `EmptyState` "No
  customs match '{query}'."
- Pagination is **not** implemented client-side (the fixture has fewer
  than 100 customs and the backend pagination contract is part of A6
  PM's other ticket; ship infinite-loaded for tonight).

**Out of scope (tonight)**: Actual delete mutation, edit routing,
"added 3 days ago" badges, swipe-to-delete on mobile, bulk select.
These are real product follow-ups; ticket them but don't ship them
overnight.

**Dependencies**: A1 (uses canonical `SearchResultRow` and `EmptyState`).

**Effort**: M. One screen file, one provider, two empty states, one
route registration, one nav link wired. The repository method against
mock data is ~10 lines.

---

### A3. Missing repository methods (`addServing`, `update`)

**One-sentence summary**: Implement the two repository methods that
screen agents stubbed with TODOs — `FoodRepository.addServing(foodId,
ServingCreate)` and `GoalRepository.update(goal)` — against the mock
data layer.

**Why now**: Screen 05 (custom food) has a working serving editor that
silently drops new servings because `addServing` doesn't exist. Screen
07 (goals) edit dialog calls `create()` as a workaround, which means
editing a goal in the UI creates a new goal record instead of mutating
the existing one. Both are silent correctness bugs that look fine in a
walkthrough until QA tries to verify. The mock data layer already has
the shapes; the methods are missing. This is the smallest possible
amount of work for the largest reduction in "TODO/workaround" comments
in the codebase.

**Acceptance criteria**
- `FoodRepository.addServing(String foodId, ServingCreate input)`
  returns the new `Serving` with a generated id, appended to the food's
  `servings` list in the in-memory mock store. Calling it twice on the
  same food appends two servings.
- `GoalRepository.update(Goal goal)` mutates the existing goal in place
  (matching by `id`) and returns the updated goal. Goal history list
  shows the updated values on next read.
- Screen 05's "Add serving" button (currently a no-op TODO) wires
  through to `addServing` and the new serving appears in the `ServingList`
  immediately.
- Screen 07's "Edit current goal" dialog calls `update` (not `create`)
  on save. Verify: the goal history list does **not** grow by one row
  after an edit; the active goal card reflects the new values.
- Both methods invalidate the right providers per T-18 — `addServing`
  invalidates `foodDetailProvider(foodId)` only; `update` invalidates
  `activeGoalProvider` and `goalsProvider` only. Not `everythingProvider`.
- Optimistic-update behavior: not required tonight. Both methods can
  await the mock-store mutation and then refresh. (Real optimistic
  updates land with real network calls.)

**Dependencies**: None. Pure repository work.

**Effort**: S. Two methods, both against the existing mock store.
Maybe 30 lines of code + the wire-throughs at the two call sites.

---

### A4. `calories_estimate.dart` lift to `lib/domain/calories/`

**One-sentence summary**: Move the Mifflin-St Jeor calculation out of
`features/onboarding/` into `lib/domain/calories/estimate.dart` per the
architecture appendix, and consume it from both onboarding and the
goals editor.

**Why now**: The architecture's appendix directory layout names
`lib/domain/calories/estimate.dart` explicitly. Today it lives inside
`features/onboarding/` because the onboarding agent put it there to
ship step 3. The goals editor needs the same calculation — when a user
edits their goal's rate or direction, the daily kcal target updates
client-side using the *same* formula. Currently goals does this
inline with a copy of the math, which means a bug fix touches two
places. Also: the onboarding kcal-target rounding drift (Mifflin-St
Jeor client half-up vs server `f64::round()` half-to-even) lives in
this file, and fixing it once is much better than fixing it in two
near-copies. Plus this is a five-line move that unblocks several other
agents from re-implementing the formula themselves.

**Acceptance criteria**
- `lib/domain/calories/estimate.dart` exists and contains the BMR
  (Mifflin-St Jeor) + TDEE (activity multiplier) + daily-target
  (TDEE + rate × 1100 kcal/kg/week) calculations. All math uses
  `package:decimal`, not `double`.
- Rounding is **half-to-even** (banker's rounding), matching server's
  `f64::round()` behavior, so client and server produce identical
  integer kcal targets given the same inputs. *(This resolves the
  flagged onboarding kcal-target rounding drift.)*
- Onboarding step 3 consumes `estimateDailyTarget(profile, goalInput)`
  from this file. No copy of the math remains in `features/onboarding/`.
- Goals editor (screen 07's edit dialog) consumes the same function.
  No copy of the math remains in `features/goals/`.
- The file has its own widget-test-free unit-test file
  (`test/domain/calories/estimate_test.dart`) with at least four cases:
  one male sedentary maintain, one female active deficit, one edge
  case at extreme rate, one validating the half-to-even rounding
  produces an integer ending in an even digit at the .5 boundary.
- The function signature does not change between use sites; both
  onboarding and goals pass the same shape.

**Dependencies**: None, but coordinates well with A3 (the goals edit
flow is also touched in A3).

**Effort**: S. File move + two import updates + one shared function
extraction + a unit test file. Could be combined with A3 if the same
agent picks both up.

---

### A5. Empty / error / loading state coherence sweep

**One-sentence summary**: Audit every screen's empty, error, and
loading states against the architecture's T-08 (skeletons match final
layout) and T-13 (no spinner on populated lists) tenants, and bring
the outliers in line.

**Why now**: Each screen agent built its skeleton independently. Some
screens use `Skeleton`/`SkeletonRow` matching final layout (T-08
compliant); others fall back to a centered `CircularProgressIndicator`
or a generic shimmer block. Some screens show a clear empty state
("No custom foods yet"); others render an empty `Column` and look
broken. Some screens surface errors as a `SnackBar` per T-11; others
render an error string mid-list. Inconsistency here is the single
biggest "feels unfinished" tell the user will pick up on. A coherent
pass is overnight-sized if it's scoped to the three states only — no
new product surface, just enforcement of existing tenants.

**Acceptance criteria**
- Every screen that fetches data on mount has a skeleton state that
  uses `Skeleton`/`SkeletonRow` from `lib/widgets/skeleton.dart`, with
  row heights matching the final widget. Centered `CircularProgressIndicator`
  is removed from production paths. (Test: throttle the mock provider
  to 800 ms and visually inspect each screen.)
- Every list-shaped screen (search results, weight history, goal
  history, my foods, today's meals) has an empty state via the
  `EmptyState` widget. Each empty state has an icon, a one-line
  title, a one-line body, and a primary action where it makes sense
  (search → "Try a different name"; weight → "Log your first weight";
  goals history → "Set a goal" if no active; my foods → "Create
  custom food"; meals → "Add food" inside each empty meal section).
- Today's empty meals: per architecture §9 gotcha, render the meal
  section header with `0 kcal` and a dimmed dot color, **not** an
  `EmptyState` widget — the meal sections are always visible, and the
  "Add food" footer link is the empty-state affordance for a single
  empty meal. This is a deliberate exception; document it as a comment
  in `MealSection`.
- Errors during data fetch surface via a `SnackBar` (T-11). The screen
  itself renders an inline `EmptyState` with an explicit retry CTA in
  the body (`title: "Couldn't load goals"`, `body: "Pull to refresh or
  tap retry."`, action: a retry button that re-invalidates the
  provider). Pull-to-refresh on mobile and the 2-px web progress bar
  on `expanded` (T-13) both work for retry on populated lists.
- The pending-sync badge from T-22 is rendered correctly on
  optimistically-inserted log entries (this already works; just verify
  during the sweep).
- No screen renders the string "Error" or "Loading…" as raw text.

**Dependencies**: A1 (uses lifted `Skeleton`, `EmptyState`).

**Effort**: L. Touches all nine screens but each touch is small. Best
suited to an agent who does one careful pass through every screen
rather than two agents racing.

---

### A6. PM rulings on §10 items 2, 9, 10

**One-sentence summary**: Resolve the three smallest §10 ambiguities
(synthetic 100 g visibility, decimal precision defaults, quality-score
copy) so developer agents stop second-guessing the design.

**Why now**: Items 2, 9, and 10 in §10 are all "is this thing user-
facing, and if so in what form?" questions. None require design
review; all three can be ruled by PM tonight and unblock screens 03,
04, 05, 06, and 09 from arbitrary decisions. Specifically: T-10
already says synthetic 100 g is always visible — but the architecture
flagged it as still-open because the rule is in the tenants but not
PM-confirmed; once PM confirms, the tenant moves from "architect
ruling" to "PM-blessed." Decimal precision is ambiguous in three
places (kcal in the day view, grams in macro readouts, kg in weight
history) and each agent picked their own format. Quality score is
data-lineage jargon (`OFF data · quality 0.86`) that screen 03 ships
verbatim from the mock; PM should rule on whether that's user-facing
copy.

See section "PM rulings on open §10 items" below for the actual
decisions. This Tier-A entry exists so that an agent can apply the
rulings as concrete code edits — it's not "PM thinks about this
overnight," it's "the rulings below are made; an agent encodes them."

**Acceptance criteria**
- **Item 2 (synthetic visibility) ruling encoded**: `ServingList`
  unconditionally renders the synthetic 100 g serving with a
  `Synthetic` badge, even when an OFF default serving exists. T-10
  stays as-written. No per-screen override. *(This is already the
  behavior; the ruling makes it final and the agent's task is to
  delete any `// TODO: confirm synthetic visibility` comments that
  exist.)*
- **Item 9 (decimal precision) ruling encoded** in
  `lib/domain/decimal_format.dart`:
  - kcal: integer (rounded half-to-even). Includes ring center,
    meal totals, day total, log preview, custom-food calories field.
  - Macros (g): integer when value ≥ 10 g, one fraction digit when
    value < 10 g. Same rule for sugar, sat fat, fiber.
  - Sodium (mg): integer always. (Sodium in mg is always large
    enough that fractional mg is meaningless.)
  - Body weight (kg): one fraction digit always (e.g. 78.4 kg,
    82.0 kg). Weight history rows, sparkline labels, summary card,
    and weight log dialog all consume this format.
  - Quantity (serving multiplier in the stepper): allow up to two
    fraction digits while typing; on commit, round to one fraction
    digit. Quick-multiplier chips snap exactly (0.5, 1, 1.5, 2, 3).
  - Rate (kg/week in goal editor): two fraction digits (e.g. 0.50
    kg/week, 0.25 kg/week).
  - Quality score: see item 10.
- **Item 10 (quality score copy) ruling encoded**: do **not** render
  the numeric quality score in screen 03's nutrition meta. Replace the
  current `"OFF data · quality 0.86"` with just `"OFF data"` (or
  `"USDA data"` / `"Your food"` for the other two sources). The
  quality score remains on the wire and in the DTO for future use
  (e.g. sorting search results by quality, or a future detail
  expandable) — it's just not surfaced as a label tonight. Add a code
  comment noting the score is intentionally hidden pending a v2
  ranking ticket.
- Each ruling is also reflected in a single-line update in
  `flutter_ui_architecture.md` §10 (move items 2, 9, 10 to RESOLVED
  with the ruling inline, same format as items 1/5/6/8/11/12).

**Dependencies**: None. Can run in parallel with A1–A5. A1 cleans up
hex literals in lifted widgets; this one cleans up rendering decisions
in those same widgets.

**Effort**: S. Three rulings, three small code edits, three doc
updates.

---

## Tier B — strong nice-to-have

Bigger refinements that polish the product once the consistency floor
in Tier A is set. Pick these up in order if Tier A finishes early.

### B1. Inter font bundling

**One-sentence summary**: Add the Inter font files to
`assets/fonts/Inter/` and register them in `pubspec.yaml` so the app
renders in Inter across all platforms instead of falling back to the
system default.

**Why now**: The architecture §2.2 mandates Inter, weights 400/500/600/700,
bundled (not loaded from a CDN). The `.gitkeep` placeholder is there
but the actual `.ttf` files aren't, so the running app uses
Helvetica/Roboto/Segoe depending on platform. This is the single most
visible "this isn't a real product yet" tell — every typographic
detail in the design tokens (the tabular figures, the letter-spacing,
the hero weight) is wasted as long as we're rendering in a system
font. Cheapest big polish win available.

**Acceptance criteria**
- `assets/fonts/Inter/` contains the four weight `.ttf` files: Regular
  (400), Medium (500), SemiBold (600), Bold (700). Source from the
  official Inter release (rsms/inter on GitHub, OFL license).
- `pubspec.yaml` registers all four weights under the `Inter` family
  with explicit `weight` keys.
- The app's `ThemeData` sets `fontFamily: 'Inter'` (already done) and
  the running app on all three platforms (mobile, web, desktop)
  renders text in Inter — verified visually on at least one screen on
  each.
- Web build pre-loads the fonts (Flutter web's `FontLoader` is fine;
  CanvasKit handles this) so there is no FOUT — text never flashes in
  a fallback font, then re-renders.
- License attribution: Inter is OFL-licensed; include the OFL.txt
  alongside the font files. No further attribution UI is required for
  v1, but make a note in `LICENSES.md` (or equivalent) for v2 cleanup.

**Dependencies**: None.

**Effort**: S. Drop in files, edit pubspec, verify.

---

### B2. Light theme polish pass

**One-sentence summary**: Audit the light theme against the design
tokens for any remaining visual inconsistencies (border weights,
divider colors, surface contrast, hover tints), since dark mode is
v2-only and the light theme is therefore the *only* theme that ships.

**Why now**: Dark mode is explicitly out of v1 (PM Risk 5). That makes
the light theme load-bearing — it's not "one of two themes," it's
*the* theme. Several screen agents shipped with `Container` widgets
that have the right border color but slightly wrong border width, or
divider thickness off by 1 pixel, or surface backgrounds set to
`Colors.white` instead of `context.tokens.color.surface` (which is
`#FFFFFF` — same hex, but the token discipline matters for the dark-
mode swap later). This pass catches those silently.

**Acceptance criteria**
- Every `Container` decoration in `features/*` and `widgets/*` uses
  `context.tokens.color.line` for borders (1 px), not a hardcoded
  color or width.
- Every `Divider` and `VerticalDivider` uses `context.tokens.color.line2`
  for inner separators or `context.tokens.color.line` for card-edge
  separators, with explicit `thickness: 1`.
- Card surfaces use `context.tokens.color.surface`, not `Colors.white`
  or `#FFFFFF` literal.
- Hover backgrounds (web) interpolate to `context.tokens.color.line2`
  per architecture §7. Verify on at least one of: `FoodRow`,
  `SettingsRow`, `SearchResultRow`.
- The `userThumbBg` and `userThumbInk` tokens are added to `AppColors`
  to replace the `#F5EFE6` / `#8C6B2C` hex literals in
  `SearchResultRow._Thumb`. (Flagged in the screen agents' follow-ups;
  resolve here.)
- The Search Frequents chip dots use `ink3` per T-03 (macro colors are
  data-only); the agent's earlier T-03 conflict resolution is confirmed
  and the mock-side protein-color is the deviation. *(This resolves
  the "T-03 conflict in Search Frequents chip dots" item from the
  screen-agent follow-up list.)*

**Dependencies**: A1 (lifted widgets are the canonical place to enforce).

**Effort**: M. Touches several files but each touch is mechanical.
Single agent, one careful pass.

---

### B3. Web keyboard shortcuts

**One-sentence summary**: Wire the keyboard shortcuts the architecture
§7 specced — `/` to focus search, `⌘K` for the command palette, `n` for
new entry, `g t/f/w/o` for nav, `Esc` for modals.

**Why now**: The architecture commits to a keyboard-first desktop
experience as one of the v1 user stories ("desktop/web at work").
Without the shortcuts, the desktop user is mousing for everything,
which makes the right rail feel like decoration rather than a
workflow. The architecture already names `KeyboardShortcuts` as a
component and says it wraps `AppScaffold` on `expanded` — the
scaffolding exists, the bindings just aren't wired.

**Acceptance criteria**
- A `KeyboardShortcuts` widget (already in the component inventory)
  wraps the shell only on `FormFactor.isExpanded`. On compact and
  medium, it's a passthrough.
- `/` focuses the top-bar search input (or, if not on a screen with
  a search input, opens the search route at `/foods/search`). Works
  from any focused element except a `TextField` (so the user can type
  a slash inside a note field without nav-jacking).
- `⌘K` / `Ctrl-K` opens the search route as a centered command-palette
  dialog (per architecture §4 modal rules), regardless of current
  route. Closing the palette returns to the prior route.
- `n` opens the log-entry dialog with the most recent food preselected.
  If there are no recents, opens search instead.
- `g t` → `/today`, `g f` → `/foods`, `g w` → `/weight`, `g o` →
  `/goals`. The `g` prefix has a 1-second timeout — after the first
  key, the next key must come within a second. *(`g m` is intentionally
  unbound — "Me" is reachable but not a hot path.)*
- `Esc` closes any open `LogEntrySheet` dialog, search palette, goal
  edit dialog, or delete-confirm `AlertDialog`. Does not affect the
  shell.
- `↑` / `↓` move selection within `SearchResultRow` and `ServingList`
  when either is focused. `Enter` activates the focused row.
- All shortcuts are documented in a small "Keyboard" section under
  Profile → Preferences (web only). Three-column table: key, action,
  context.

**Dependencies**: None, but plays well with B6 (hover states) since
both are desktop polish.

**Effort**: M. The wiring is straightforward Flutter `Shortcuts`/
`Actions` boilerplate; the `g _` two-step binding is the one moving
piece.

---

### B4. Animations and transitions

**One-sentence summary**: Add the small motion details that make the
app feel responsive — calorie ring count-up on day change, FAB
press/hover micro-states, sheet/dialog slide-in, route transitions —
keeping each under 250 ms.

**Why now**: The static design feels finished; the motion is what
sells the product as polished rather than utilitarian. Each item is
a small isolated change with no architectural cost. Keep durations
short and tasteful — this is a calorie tracker, not a game.

**Acceptance criteria**
- `CalorieRing` interpolates its stroke arc when `consumed` changes,
  using a `TweenAnimationBuilder` over 400 ms with `Curves.easeOutCubic`.
  Center number does **not** count up — that's visual noise on
  tabular figures (T-02 keeps them stable). Only the arc animates.
- The over-budget color flip (T-05) cross-fades over 150 ms when the
  bar crosses `value > target`, not a hard swap.
- `LogFoodFab` has a press-down state (scale 0.95, 100 ms) and a hover
  state on web (background tint, 80 ms per §7). No elevation change
  on hover — T-04 keeps accent for primary actions, not decoration.
- `LogEntrySheet` slides in from the bottom on compact/medium
  (existing default sheet animation; verify it's not jankily fast or
  slow — Material default is fine), fades in on `expanded` dialog
  (200 ms fade + 8 px upward translate).
- Route transitions: use the default `MaterialPage` transitions on
  compact (slide-from-right) and a quick fade (180 ms) on `expanded`.
  Don't use slide on desktop — it looks like a website, not an app.
- `MacroBar` fill animates when `value` changes — same 400 ms cubic
  curve as the calorie ring.
- All animations respect `MediaQuery.disableAnimations` — when the
  user has reduced motion enabled, durations collapse to 0 ms.

**Dependencies**: A1.

**Effort**: M. Several small animation hooks across lifted widgets.

---

### B5. Web hover states audit

**One-sentence summary**: Verify every tappable surface on web has a
hover state per architecture §7, and add the missing ones.

**Why now**: The architecture commits to a hover rule (background
tint over 80 ms, no shadow change, accent never used for hover). Most
screens implemented hover on the obvious targets (`FoodRow`,
`SearchResultRow`, sidebar items), but several screens missed
`SettingsRow`, `ServingList` rows, `GoalHistoryList` rows, and the
date-bar chevrons. A desktop user moving the mouse over the app
should never wonder "is this clickable?"

**Acceptance criteria**
- Every interactive element in the component inventory has a hover
  state on web (`MouseRegion(cursor: SystemMouseCursors.click)` +
  background interpolation to `line2` over 80 ms). Specifically
  audited: `FoodRow`, `SearchResultRow`, `SettingsRow`,
  `ServingList`'s row, `GoalHistoryList`'s row, `WeightHistoryList`'s
  row, the `IconButton36` instances, the date-bar chevrons, the
  segmented control segments, `QuickChipRow`'s chips, `MealChipPicker`'s
  cells, `ActivityOption`, `GoalOption`.
- No element uses `AppColors.accent` for hover. No element raises in
  elevation on hover.
- Hover states are disabled on touch devices via the standard Flutter
  pointer-kind check (touch-primary devices skip the `MouseRegion`).
  Mobile-web (Safari iPhone) does not show hover artifacts.
- Cursor: `SystemMouseCursors.click` on tappable rows;
  `SystemMouseCursors.text` on `TextField`s; default elsewhere.

**Dependencies**: A1 (canonical widgets are the right place to
enforce). B2 (light theme polish) overlaps; one agent could do both.

**Effort**: M.

---

### B6. Sign-out wiring with auth-token notifier

**One-sentence summary**: Convert `lib/data/auth_token.dart` from a
plain Provider to a `Notifier` so the Profile sign-out button can
actually clear the token (and any cached user state), even though
v1 runs against `DEV_AUTH_BYPASS`.

**Why now**: Tapping "Sign out" in the Profile screen is currently a
no-op TODO. That's a visibly broken button in a settings screen,
which is exactly the kind of UI bug that erodes trust. We don't have
real auth yet (PM Risk 2 deferred it), but we *do* have a dev token,
and we *can* simulate sign-out by clearing the token, evicting all
cached providers, and routing back to onboarding. That's enough to
make the button feel real — and when real auth lands, the wiring is
already in place.

**Acceptance criteria**
- `authTokenProvider` becomes a `NotifierProvider<AuthTokenNotifier, String?>`
  exposing `signOut()` and `setToken(String)` methods.
- `signOut()` clears the token, evicts the Hive boxes (recent foods,
  frequents, food details, active goal, weights, profile), invalidates
  the relevant providers, and pushes the user back to `/onboarding/1`.
- The Profile screen's sign-out row calls `signOut()` after a
  destructive confirmation dialog (per T-11: modals are reserved for
  destructive confirmation) — title "Sign out?", body "You'll need to
  set up again to use Fulfilled.", primary action "Sign out" in
  `AppColors.danger`, cancel as secondary.
- After sign-out, the next provider read against the API client
  receives a 401 (or, in `DEV_AUTH_BYPASS` mode, the dev token is
  re-set when onboarding completes; either is acceptable for v1).
- Token persistence: store the dev token in a Hive box so the user
  doesn't have to re-onboard on every app launch. After sign-out, the
  box is cleared. After onboarding completes, the box is written.

**Dependencies**: A5 (signed-out state probably triggers some empty
states that should already be coherent from the sweep).

**Effort**: M. Notifier conversion + box wiring + confirmation
dialog + the routing-back-to-onboarding step.

---

### B7. Accessibility audit (Semantics + T-20)

**One-sentence summary**: A single-pass audit of every screen for
T-20 compliance — `Semantics` labels include rendered numbers, color
is never the sole signal, every `IconButton36` has a tooltip.

**Why now**: T-20 is a tenant; it should already be enforced. In
practice, screen agents shipped without consistent Semantics labels —
some rows have them, some don't, and the ones that do often omit
units ("130" instead of "130 kilocalories"). Screen-reader users
hitting the app cold would get a noticeably worse experience than
sighted users. We don't need to ship VoiceOver-perfect tonight, but
we do need the foundations so adding the remaining 5% later is
mechanical, not architectural.

**Acceptance criteria**
- Every `NumberText` instance includes a `unit` prop. Every Semantics
  label for a numeric leaf reads as "{value} {unit}" (e.g. "130
  kilocalories", "33 grams of protein").
- Every `IconButton36` has a non-null `tooltip`. Tooltips are visible
  on hover on web and on long-press on mobile.
- Every `FoodRow`, `SearchResultRow`, `ServingList` row, and
  `WeightHistoryList` row has a single composed Semantics label that
  reads as a natural-language summary (e.g. "Greek yogurt, 1 cup,
  130 kilocalories" for a food row).
- Over-budget macro bars include an "over by N g" suffix in their
  Semantics label per T-05's accessibility note.
- Color contrast on `ink2` (`#5C625C`) against `surface` (`#FFFFFF`)
  passes WCAG AA for normal text. (It does; this is verification.)
  Same for `ink3` placeholders — they pass AA for large/UI text only,
  which is fine for placeholders but **not** fine for substantive
  copy. Verify no body text is rendered in `ink3`.
- Tab order on web follows visual order. (Spot-check screen 04 log-entry
  dialog and screen 05 custom-food form.)

**Dependencies**: A1, A5.

**Effort**: M. Mostly Semantics annotations across existing widgets.

---

### B8. Activity / calories-burned provider (Today "Burned" row)

**One-sentence summary**: Stub a fake `caloriesBurnedProvider` that
returns a realistic per-day burned-kcal value so Today's "Burned" row
shows a number instead of `—`.

**Why now**: Today's day-view has a "Burned" row in the right rail
(expanded) and the ring summary (compact) that currently renders `—`
because there's no provider for it. The day total doesn't reconcile
visibly. This is fake-data work, not a backend change — we don't need
a real fitness integration; we need the provider to exist with a
plausible value (e.g. `tdee - bmr` for the user, drawn from their
profile + activity level) so the UI renders coherently.

**Acceptance criteria**
- `caloriesBurnedProvider(date)` returns a `Decimal` value computed as
  the user's TDEE minus BMR (the "activity calories" component of
  their daily expenditure), bucketed per-day with small per-day
  variance (±5%) for realism. Same value across the day.
- Today's "Burned" row renders this value with the kcal unit and
  tabular figures. The ring summary card's "Burned" stat updates.
- The "Net" / "Remaining" calculation on the day view uses
  `goal - consumed + burned` (or the equivalent formula the existing
  screens use), with `burned` now non-zero.
- No UI for editing or syncing activity tonight. The provider is a
  pure derivation from profile + active goal.
- Tests not required; this is fake-data plumbing.

**Dependencies**: A4 (estimate.dart lift) — the TDEE math lives
there.

**Effort**: S.

---

### B9. Quick-add empty state on Today expanded right rail

**One-sentence summary**: When the user has zero recents and zero
frequents, the Today expanded right rail's "Quick add" card shows an
empty state instead of an empty `QuickChipRow`.

**Why now**: A brand-new user finishing onboarding lands on Today
with no logged foods, no recents, no frequents. The right rail's
Quick add card is currently a blank space in that case. This is a
small empty-state miss that A5's sweep should catch — splitting it
out as its own ticket because it has a specific copy/CTA the agent
needs guidance on.

**Acceptance criteria**
- When `recentFoodsProvider` and `frequentFoodsProvider` are both
  empty, the Quick add card renders an `EmptyState`-shaped block with
  icon, title "No recents yet", body "Log your first food and it'll
  show up here.", and a primary CTA "Find a food" that routes to
  `/foods` (the search screen).
- When the user has recents but no frequents (or vice versa), the
  card still shows the QuickChipRow for whichever has data, with the
  other section's header simply omitted (don't show "Frequent" with a
  blank row underneath).
- Card height stays consistent with the other right-rail cards so the
  vertical rhythm doesn't shift.

**Dependencies**: A5.

**Effort**: S.

---

### B10. Desktop "paste a barcode" affordance

**One-sentence summary**: On `expanded`, when the user types or
pastes 8–14 digits into the search input, offer a "Look up barcode
{code}" affordance below the input that routes to
`/foods/barcode/{code}`.

**Why now**: Per the §10 item 3 ruling below, the desktop has no
camera-based barcode flow — but the OFF database is barcode-indexed
and a desktop user who has the barcode on their physical product can
type/paste it. The web mock's "Search foods or scan barcode…"
placeholder already implied parity; we're paying it off with the
typed/pasted variant. Mobile keeps the camera scanner; web keeps a
plain `TextField`.

**Acceptance criteria**
- On `FormFactor.isExpanded`, the search input's placeholder reads
  "Search foods or paste a barcode…" (matching the mock + §10 item 3
  ruling).
- When the input value is all digits and length is between 8 and 14
  inclusive, a secondary affordance appears below the input (a small
  row, not a chip): "Look up barcode {value} →". Tapping or pressing
  Enter on it routes to `/foods/barcode/{value}`.
- Regular search continues to work — typing letters reverts to
  text search behavior.
- `/foods/barcode/:barcode` resolves via the existing mock data
  (which can return a 404 → push to `/foods/new?barcode=...` per
  the architecture §6 flow). The 404 path is tested.

**Dependencies**: A2 doesn't strictly block but the routing patterns
are adjacent.

**Effort**: M.

---

## Tier C — explicitly out of scope tonight

These were considered and rejected. Each line explains the rejection.

- **Trends tab.** Already PM Risk 3'd out of v1; do not revisit
  overnight even if an agent has spare cycles. Designed-and-shipped
  Trends is a v2 deliverable.
- **Real auth (Google / Apple / email).** PM Risk 2 deferred this;
  the dev bearer token is the auth story for v1. B6 (sign-out wiring)
  is the polish layer, not the real implementation.
- **Real API wiring against the Rust server.** The wire is frozen
  overnight. Every Tier-A and Tier-B feature is client-only against
  the mock data layer.
- **Lb / ft+in unit support.** PM Risk 4 deferred this to v2 with the
  `weight_unit` / `height_unit` profile fields. Adding it without the
  backend field is a half-implementation that creates more confusion
  than it solves.
- **Dark mode.** PM Risk 5 deferred this to v2. Light theme polish
  (B2) is the in-scope substitute.
- **Real barcode camera UI on web.** PM ruling §10 item 3 below makes
  it a paste-the-digits affordance, not a camera flow. The mobile
  camera scanner is already shipped; web does not get one.
- **Riverpod codegen (`@riverpod` annotations).** The project uses
  hand-rolled providers; introducing build_runner overnight is a
  build-system change that risks blocking every other Tier-A agent.
- **Profile edit per-field flow.** Per the §10 item 7 ruling below,
  per-field modals on compact / inline edits on expanded is the
  v1 shape. A "single full editor screen" alternative is rejected
  but the implementation itself is a v1.1 ticket, not tonight's.
- **3-up onboarding marketing variant on web.** Per §10 item 4
  ruling below, keep one-step-at-a-time across breakpoints. The
  marketing-style multi-column variant is a separate web-only
  surface and out of v1.

---

## PM rulings on open §10 items

One-line decision per item. The frontend architect and program
manager should treat these as ground truth.

**Item 2 — Synthetic 100 g serving visibility.**
**Always visible**, even when an OFF default serving exists. T-10
stands as written. Reason: the 100 g basis is what the nutrition
panel uses (`Per 100 g` per Display Units Principle), and showing
the corresponding serving keeps the math reconcilable for the user.

**Item 3 — Barcode-equivalent on desktop.**
**Paste-the-digits**, not camera. Placeholder copy: "Search foods or
paste a barcode…". When input matches `^\d{8,14}$`, surface a
secondary "Look up barcode {value} →" row that routes to
`/foods/barcode/{value}`. Mobile keeps the camera; web gets the
typed shortcut. Implementation lives in B10.

**Item 4 — Onboarding on web.**
**One step at a time across all breakpoints.** On `expanded`,
constrain the form column to 520 px max-width centered. No 3-up
"tour" variant in v1. If a marketing site wants a multi-column
preview, that's a separate non-product surface.

**Item 7 — Profile editing flow.**
**Per-field modals on compact, inline edits on expanded.** On
compact, tapping a settings row opens a focused modal sheet for that
single field (sex picker, date picker, height stepper, activity
list reusing `ActivityOption`). On expanded, the row toggles into
an inline edit-in-place state. No "single full editor screen" —
that would require a screen design we don't have. The implementation
itself is a v1.1 ticket; ruling here so future agents don't re-debate.

**Item 9 — Decimal precision defaults.** See A6 acceptance criteria
for the full table. Headline: kcal as integer, macros integer at ≥10
g / one decimal at <10 g, sodium integer mg, weight one decimal kg,
quantity one decimal commit, rate two decimals. Banker's rounding
(half-to-even) to match the server.

**Item 10 — Quality score visibility.**
**Hide the numeric score** in user-facing copy. Replace
`"OFF data · quality 0.86"` with just the source label
(`"OFF data"`, `"USDA data"`, `"Your food"`). The score stays on the
wire and in the DTO for future use (sorting, ranking, debug surfaces).
Add a code comment noting the score is intentionally hidden pending
a v2 ranking ticket.

---

## Summary table

| Tier | ID | Feature                                           | Effort | Deps         |
|------|----|---------------------------------------------------|--------|--------------|
| A    | A1 | Shared widget lift to `lib/widgets/`              | L      | —            |
| A    | A2 | My Foods screen at `/foods/mine`                  | M      | A1           |
| A    | A3 | Missing repository methods (`addServing`, `update`)| S     | —            |
| A    | A4 | `calories_estimate.dart` lift                     | S      | —            |
| A    | A5 | Empty/error/loading state coherence sweep         | L      | A1           |
| A    | A6 | PM rulings on §10 items 2, 9, 10                  | S      | —            |
| B    | B1 | Inter font bundling                               | S      | —            |
| B    | B2 | Light theme polish pass                           | M      | A1           |
| B    | B3 | Web keyboard shortcuts                            | M      | —            |
| B    | B4 | Animations and transitions                        | M      | A1           |
| B    | B5 | Web hover states audit                            | M      | A1, B2       |
| B    | B6 | Sign-out wiring with auth-token notifier          | M      | A5           |
| B    | B7 | Accessibility audit (Semantics + T-20)            | M      | A1, A5       |
| B    | B8 | Activity / calories-burned provider               | S      | A4           |
| B    | B9 | Quick-add empty state on Today right rail         | S      | A5           |
| B    | B10| Desktop paste-a-barcode affordance                | M      | —            |

Total: **16 features**, ~10 marked S/M (single-agent, single-pass) and
~3 marked L (multi-screen). Generous overnight runway — agents
should pull A1, A3, A4, A6 first (no blockers), then A2/A5 once A1
lands, then anything in Tier B.

---

## Documents this decision touches

- `specs/flutter_ui_architecture.md` — §10 items 2, 9, 10 move to
  RESOLVED with the rulings above; appendix directory layout
  unchanged (`lib/domain/calories/` was already listed); §3 component
  inventory unchanged but the canonical implementations move to
  `lib/widgets/` per A1.
- `specs/pm_decisions_flutter_ui.md` — no changes; this doc extends
  rather than overrides.
- `client/lib/widgets/*.dart` — new files for the lifted widgets.
- `client/lib/domain/calories/estimate.dart` — new file (move from
  `features/onboarding/`).
- `client/lib/data/auth_token.dart` — Notifier conversion (B6).
- `client/assets/fonts/Inter/*.ttf` — new assets (B1).
- `client/pubspec.yaml` — font registration (B1).
- Various `features/*` files — empty-state, error, loading, hover,
  Semantics, and animation touches.

No backend changes. No OpenAPI changes. No new wire shapes.
