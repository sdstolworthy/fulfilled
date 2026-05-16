# PM Requirements: Editable Log Entries + User-Selectable Weight Units

Two product requirements landed in the same conversation: (a) tapping a
food on the day dashboard should open an edit experience for that log
entry, and (b) the app should let the user pick the unit they see weights
in (lb in the US, st in the UK, kg everywhere else). Both are user-driven
asks — neither is invented scope. This doc names the user stories,
picks a direction, and surfaces the architectural seams. The frontend
architect writes the implementation plan after this; the doc is the
contract.

`specs/pm_decisions_flutter_ui.md` (the Display Units Principle, PM Risk
4 deferring lb to v2) and `specs/flutter_ui_architecture.md` (T-15,
T-17, T-21, screen 04 brief) are the tiebreakers above this doc.
`specs/openapi.yaml` is the wire-shape contract — I read it for both
features before writing this, and the relevant existence/absence calls
are noted in each section.

---

## 1. Context and prior decisions

**What the user asked for.** Two requests. First: tapping a food row on
the daily dashboard should open the entry for editing — adjust the
serving, change the quantity, fix the meal, correct a typo. Today the
tap is a no-op (the `onEntryTap` callback exists on `MealSection` but
nobody wires it). Second: let the user choose the unit weights render
in. The user named three regions and three units explicitly — US wants
pounds, UK wants stones, "the rest of the world" wants kilograms. They
were clear that this is **weight units only**, not food serving units —
gram macros stay gram macros.

**The prior PM call (kg-only) and why it changed.** In `pm_decisions_flutter_ui.md`
Risk 4, I ruled v1 **kg-only** and pushed lb/st to v2 behind a v2 ticket
("Add `weight_unit` (`kg|lb`) to `User`, expose in profile, gate display
in `units` utility on preference"). I also wrote, on screen 08's
Preferences section, "informational in v1 (kg/kcal/g); v2 surfaces unit
prefs." The user just asked for v2. We promote the ticket. Adding st is
new since the original ticket only named lb — `st` is a UK convention
that round-trips as `stones + lb` for display, and we ship it because
the user explicitly asked. **Note**: stones are not "the metric body
expects" anywhere outside the UK; we are not inventing a third axis
for fun.

**The Display Units Principle stays.** This is an *editable preference*,
not a re-architecture. Body weight on the wire stays `kg` (canonical
SI, per `WeightEntry.weight_kg` in the OpenAPI). Conversion still lives
in `lib/domain/units/weight.dart` (T-21). What changes is the formatter
now branches on the user's preference instead of being kg-only, and
*every* widget that renders weight in kg today goes through the same
formatter so the change lands in one place. **No widget multiplies by
2.2046 inline.** No screen reads the preference and renders its own
unit. The architect already named `weight.dart` as the single seam in
the architecture appendix — we honor that.

---

## 2. Feature A — Edit a log entry from the day view

### User stories

- **As a user who just realized I logged 2 cups of yogurt when I meant
  1.5,** I tap the row on Today and adjust the quantity in the same
  sheet I used to create it, so I don't have to delete the entry and
  log it again from scratch.
- **As a mobile user on the go,** I tap the row from the daily
  dashboard in line at the coffee shop, change the serving from
  "1 cup" to "1 mug" without re-searching for the food, and dismiss —
  the day total updates in place.
- **As a desktop user at work,** I move the mouse over a row on Today,
  see the row tint to `line2` per §7 hover, click it, and the same
  centered log-entry dialog I use for creates opens — pre-filled with
  the entry's current values.
- **As a user reconciling a day that's over-counted,** I tap the
  duplicated-by-mistake row, change the quantity to a smaller value
  (or delete it via the sheet's overflow), and the ring drops
  correspondingly. I never see a dead-end "Edit" sub-screen that
  only lets me change one field.
- **As a user editing a row whose POST is still mid-flush from the
  outbox,** I expect to see clearly that the row is pending and either
  (a) I can't edit it yet, or (b) my edit replaces the pending payload.
  See "Conflict + concurrency" below for which path we pick.
- **As a user changing my mind in the edit sheet,** I tap close /
  cancel / swipe down and the entry stays exactly as it was — no
  partial save.

### Decision: where the edit lives

**Reopen the existing `LogEntrySheet` in edit-mode** — same widget,
same code path, with a new `LogEntry? existing` constructor parameter
that pre-seeds the form state. This is the right call for four
reasons.

1. **Discoverability matches creation.** The user already knows how to
   change a serving, quantity, meal, date, and note in this sheet —
   that's literally the create flow on screen 04. A separate "edit
   page" or "edit dialog" would be a second mental model for the same
   data. The architecture's screen 04 brief is the single visual
   contract for "interact with a log entry's fields"; edit is a state
   of that screen, not a sibling.

2. **One widget = one set of field validations.** The serving picker,
   quantity stepper, meal chip picker, date row, and note field all
   already exist with their per-field validation and accessibility
   labels (T-20). Forking an edit page means re-implementing those, and
   forks drift. Same widget keeps the rules co-located.

3. **One source of truth for the preview block.** The "Will log: 195
   kcal · P 33 g …" `LogPreviewBlock` already reads `food + serving +
   quantity` and recomputes. Same component handles "Will save: ..."
   for edits without modification (we change the label string —
   "Save changes" — and the math is the same).

4. **The architect named the seam already.** Screen 04's brief says
   "the same `LogEntrySheet` widget, just in a different shell" when
   reused across compact / medium / expanded. Edit-mode is the same
   pattern with a different *purpose*; the shell decision (sheet on
   compact, dialog on expanded) is unchanged.

**Rejected alternatives.**

- *Quick-inline edit menu* (long-press for "1.5× · 2× · Custom...").
  Rejected: it solves the "I want to change just the quantity"
  micro-case at the cost of not supporting the "I want to change the
  serving" or "I want to fix the meal" case, and now we have two edit
  flows with different capability surfaces. The user asked to "adjust
  the serving size or change the values" — they want all of it, not
  half of it.
- *A separate full-screen edit route* (e.g. `/log/:id/edit`).
  Rejected: it duplicates screen 04 for negligible win, deep-linking
  to a half-filled edit form is a footgun, and the existing sheet
  already works as both a sheet and a dialog across breakpoints — we
  have form-factor coverage for free.
- *A non-modal inline edit on the row itself.* Rejected: doesn't fit
  the field set (serving picker doesn't expand inline; quantity
  stepper needs space; date and meal pickers are modal-shaped). Also
  fights T-12 (no floating action surfaces).

### How tap-to-edit lands in the widget tree

- `MealSection.onEntryTap` is already plumbed (it currently accepts
  the callback but no caller wires it). The compact `day_view_compact`
  and expanded `day_view_expanded` screens pass a handler that calls
  `showLogEntrySheet(context, food: ..., existing: entry)`.
- The food the sheet needs is **not on the `LogEntry` itself** — the
  log row carries a `foodId`, `foodName`, `servingName`, and a frozen
  nutrition snapshot. Edit-mode must fetch `foodDetailProvider(foodId)`
  before rendering the form (servings list, nutrition-per-100g for the
  preview math). On cache hit (and the architecture caches food detail
  aggressively per §5), this is a frame-level operation; on miss,
  show a skeleton inside the sheet.
- The serving picker pre-selects the entry's `servingId`. Quantity
  stepper pre-seeds `entry.quantity`. Meal chip picker pre-selects
  `entry.meal`. Date row pre-seeds `entry.consumedOn`. Note field
  pre-seeds `entry.note ?? ''`.
- The sheet header changes: brand eyebrow stays the same; title
  appends "(editing)" in `ink2` `meta` style. No new visual
  primitive; same `_Header`.
- The footer CTA reads **"Save changes"** instead of "Save to log".
  Same button widget. Disabled until the form differs from the
  pre-seeded values (avoid no-op PATCHes). The architect can decide
  whether to add a tertiary "Delete" affordance in the sheet header
  (the overflow on the day-view row already handles delete; adding a
  second access point inside the sheet is nice-to-have, not blocking).

### Backend implications — there *is* an endpoint

I read `specs/openapi.yaml`. **The endpoint exists**: `PATCH /log/{id}`,
operationId `update_log_entry`, with a `LogPatch` body and a `LogEntry`
response. The body is sparse — `serving_id`, `consumed_on`, `meal`,
`quantity`, `note` are all optional; `food_id` is explicitly immutable
and sending one returns 400. A `null` `note` clears the value; omitting
the key leaves it untouched. This is exactly the shape we need.

**Recommendation.** Wire it. No stopgap, no mock-only path, no TODO
ticket against the backend. `LogRepository` gets an `update(String
entryId, LogPatch patch) → Future<LogEntry>` method that mirrors the
existing `create` / `delete` mocks. The mock implementation mutates
the in-memory entry in place, recomputes the nutrition snapshot from
the (new) serving + quantity against the food's `nutritionPer100g`
(same math as `create`), and bumps `updatedAt`. Provider invalidation
matches `create` — invalidate `daySummaryProvider(consumedOn)`,
`logEntriesProvider(consumedOn)`, `recentFoodsProvider`,
`frequentFoodsProvider`. If `consumed_on` was edited and now lands on
a different day, invalidate both the old and the new date's providers.

**Caveats the architect needs to know.**

- The `food_id` immutability is enforced server-side and worth
  surfacing client-side too — the food row in the edit sheet is
  *read-only* (we render the food header for context but we do not
  let the user pick a different food). Changing food is "delete +
  create" by design; the sheet does not pretend otherwise.
- The frozen `nutrition_snapshot` on `LogEntry` is recomputed
  server-side on PATCH using the *current* `food.nutrition_per_100g`
  and the new `serving + quantity`. If the food panel was edited
  between the original log and this edit, the user sees a tiny shift
  in the macro numbers — expected, and matches how create works.
- We do *not* send `food_id` in the PATCH body. The repository
  signature should not even accept one.

### Conflict + concurrency

**Apply the prior architect ruling, adapted for edits.** From the
outbox decision (PM Risk 6 / architecture §5 "Outbox"): "the server is
authoritative. If a queued entry returns with a different `id` or a
different nutrition snapshot than the client predicted, replace the
optimistic row with the server response — do not merge."

Edits introduce a new case the original ruling didn't name: **editing
a row whose POST is still mid-flush from the outbox**. The optimistic
row's `id` is `optimistic_<timestamp>` and there is no server entry to
PATCH yet. Two options:

- *(A) Disable edits on pending rows.* Tap on a pending row does
  nothing (or shows a SnackBar — "Syncing — try again in a moment").
- *(B) Allow edits to mutate the queued payload.* Edits to a pending
  row update the outbox entry's `LogCreate` payload in place; the
  POST flushes later with the user's latest values.

**Pick (A).** It's the simpler, safer call and matches T-22 ("pending
sync state is visible, not silent"). The architecture's section 6
already restricts pending-row overflow to "Retry now" and "Discard"
("No edit until the server confirms the entry") — we explicitly
named this rule once; honor it. (B) sounds nice but creates a fork
in the outbox payload shape (was-create-now-also-an-edit) that we
will absolutely regret when the same code path runs for v2 with real
auth. Tap on a pending row shows a SnackBar: "Still syncing — edit
when sync finishes." The row's existing overflow ("Retry now" /
"Discard") covers the user-recovery case.

**For committed (server-acked) rows the conflict story is simple.**
The PATCH is fire-and-forget from the sheet's point of view:
optimistic apply locally → POST → on success, replace the optimistic
mutated row with the server response; on failure, revert and show a
SnackBar per T-11. We do not implement field-level last-writer-wins
between two clients editing the same row concurrently — that's a
multi-device problem v1 doesn't have (we have one user, one device
session, no concurrent edit story).

### Acceptance criteria

- Tapping any `_EntryRow` on Today (compact or expanded) opens
  `LogEntrySheet` pre-seeded with the entry's serving, quantity, meal,
  date, and note. The food header reads the entry's `foodName`.
- The save CTA reads **"Save changes"** and is disabled when the form
  is unchanged from the pre-seed.
- Pressing save calls `LogRepository.update(entryId, LogPatch)` on
  medium/expanded, and (per the existing architecture) the same
  direct path on compact for *edits*. The outbox does **not** queue
  edits — edits require connectivity. On failure, the sheet stays
  open with input intact and a SnackBar surfaces the error.
- The day summary, log entries, recents, and frequents providers all
  invalidate on success. If `consumed_on` changed, the *old* date's
  providers also invalidate.
- The food shown in the sheet header is fetched via
  `foodDetailProvider(entry.foodId)`. On cache miss, the form body
  renders a `Skeleton` matching the field heights until the food
  arrives. (T-08.)
- Tapping a pending-sync row (T-22 badge present) does **not** open
  the edit sheet. A SnackBar reads "Still syncing — edit when sync
  finishes." The row's overflow ("Retry now" / "Discard") remains the
  only interaction.
- `food_id` is never sent in the PATCH body. The sheet header is
  read-only — there is no UI affordance to change food. (To change
  food, the user deletes and re-creates.)
- Close / cancel / swipe-down on an edit sheet discards the edit;
  the original entry is untouched.
- A `Semantics` label on the row reads "Greek yogurt, 1 cup, 130
  kilocalories, edit" so screen-reader users know it's actionable.
  (T-20 enforcement.)
- The day view's hover state on web ties the row visually to the new
  affordance (no separate "Edit" icon button; the whole row is the
  target).

---

## 3. Feature B — User-selectable weight units (kg / lb / st)

### User stories

- **As a US user,** I want to enter and read my weight in pounds, so
  that I don't have to convert `78.4 kg` to "about 173 lb" in my head
  every morning.
- **As a UK user,** I want my weight in stones and pounds (the way my
  bathroom scale reads), so that I recognize my own number on screen.
- **As a user setting up the app for the first time in Germany,** I
  expect the default to be kilograms without me touching a setting —
  the locale on my device tells you that.
- **As a user who travels,** I want to flip between units in Profile →
  Preferences once, and have *every* screen that renders a weight
  respect that choice — the weight log, the sparkline axis, the active
  goal card, the onboarding pre-fill, the today right rail mini chart,
  everything.
- **As a user who set my weight in kg during onboarding and is now
  switching to lb,** I expect the data on screen to convert *display*
  — no entries are duplicated, no history is rewritten, the underlying
  numbers don't change. Same body, different reading.
- **As a user changing my goal's target weight,** I want the goal
  editor to accept input in my chosen unit and the active goal card
  to render the target in my chosen unit — no kg leaking through.

### Decision: where the preference lives

**Add `weight_unit` to the wire shape on `User` and `ProfilePatch`,
plus a client-side bootstrap.** Be opinionated: **wire is the source
of truth**, client cache is local-first for instant render.

Rationale:

- **Cross-device parity.** The user said "for the application" — they
  expect their preference to follow them, not be a per-device thing.
  A user who flips US→UK between their phone and a desktop browser
  should see stones on both. Client-only storage (Hive box,
  `SharedPreferences`) doesn't deliver that.
- **Onboarding can set it.** If the preference lives on `User`, step 2
  of onboarding can write the unit alongside height/weight in the
  same PATCH. Without it, onboarding can't persist the value the user
  implicitly chose by entering "173 lb."
- **One degree of freedom.** A `User.weight_unit: 'kg' | 'lb' | 'st'`
  enum is one new field, one new column on the backend, one new
  branch in the formatter. Trying to hide this in client storage
  forces the architect to write a "merge local-only setting with
  server profile" reconciler that we will never not regret.

**Backend implication — flag for the user, do not design unilaterally
(see §6 punt-list note as well).** This requires a Rust migration:
add `weight_unit` (PostgreSQL enum or text + check constraint) to the
`users` table, add it to the `User` and `ProfilePatch` schemas in
`openapi.yaml`, return it from `GET /me`, accept it on `PATCH /me`,
default to `kg` on existing rows. **Recommendation: ship this.** It's
a one-column migration, the wire change is additive (existing clients
that don't know about `weight_unit` keep working — `User.weight_unit`
is required on the wire but defaults server-side; `ProfilePatch.weight_unit`
is optional). The alternative (client-only) saves us a backend ticket
and gives us a worse product. The user makes the call when they read
this doc.

**Client storage** mirrors `meProvider` — the `User` is already cached
in Hive per architecture §5. The preference rides on `User` and gets
read from the same provider. The bootstrap-before-PATCH default (see
"locale default" below) is held in an ephemeral provider only until
the first onboarding PATCH lands; after that, the server is canonical.

### Decision: locale default

**Use the platform locale on first boot, with an explicit fallback
chain.** The architect needs a concrete seam — here it is.

```
Default unit selection (first boot, no server-side value):
  1. `WidgetsBinding.instance.platformDispatcher.locale.countryCode`
     - 'US' → 'lb'
     - 'LR' (Liberia), 'MM' (Myanmar) → 'lb' (these are the other two
       non-metric countries; pragmatic, costs nothing)
     - 'GB' → 'st'
     - everything else → 'kg'
  2. If countryCode is null (rare; some browsers strip it) → 'kg'
  3. If the platform locale itself is unavailable → 'kg'
```

The default surfaces *only* the first time we render a weight before
the user has touched a setting. On onboarding step 2 the field is
labeled "Weight (lb)" / "Weight (st)" / "Weight (kg)" per the picked
default — the user can flip the unit chooser in the same screen if
they disagree. The PATCH at the end of onboarding writes
`weight_unit: <chosen>` alongside the rest of the profile.

**Stone is the carve-out for the UK.** The system locale picks it for
`GB`, but the unit chooser still offers all three to everyone — a US
user with a kg scale can pick kg; a UK user who prefers lb can pick
lb. The locale is the *default*, not the gate.

### Decision: scope of the conversion

**Only weight (kg ↔ lb ↔ st).** Be explicit so this doesn't bleed:

- **In scope.** Body weight everywhere — current weight on Profile,
  onboarding step 2 weight field, weight log entries (input + history
  + sparkline + summary card delta), goal start/target weight, mini
  sparkline on Today expanded right rail, active goal card.
- **Out of scope.** Macros (P/C/F/fiber/sugar/sat fat) stay in grams.
  Sodium stays in mg per the Display Units Principle. Energy stays in
  kcal. Food serving grams stay in grams (the per-100 g panel, the
  serving labels, the gram totals on a `LogEntry`). Height stays in
  cm — the user did not ask for ft/in and PM Risk 4 still defers
  height unit selection to v2. **Goal rate (`kg/week`) is also
  out** — see "Display format per unit" below for the reasoning.

This is the part the architect needs to enforce in code review: a
weight-unit branch should appear in **one** new place
(`formatWeight(Decimal kg, WeightUnit unit)` in `domain/units/weight.dart`)
and **nowhere else**. No `if (unit == lb)` in a widget. No new
conversion helpers for serving grams. Touch macros formatters and the
PR is wrong.

### Display format per unit

For each unit, what the rendered string looks like. The architect
puts these in `formatWeight` as the single seam.

| Unit | Format | Examples | Decimal rule |
|------|--------|----------|--------------|
| `kg` | one decimal, locale separator | `79.4 kg`, `82.0 kg` | half-to-even (unchanged from v1 — `formatWeightKg` already does this) |
| `lb` | one decimal | `175.1 lb`, `220.0 lb` | half-to-even |
| `st` | composite stones-and-pounds | `12 st 7 lb`, `9 st 0 lb` | integer stones, integer pounds (no fractional lb in the composite) |

**Stone specifically — why composite, not decimal stones.**

`12.5 st` is a number a calculator produces; it's not how the UK reads
weight. Bathroom scales there read `12 st 7 lb`, conversation reads
"twelve seven", labels on weight goals read "12 st 7 lb". Picking
decimal stones (`12.5 st`) optimizes for "looks like our existing
one-decimal weight format" at the cost of failing the actual user
recognition test — we'd be making the metric match our internals
instead of the user's life. Composite costs us one extra ~30-line
formatter and a slightly more involved input affordance (see
"Inputs" below); worth it.

**Rounding the composite.** `kg` → stones+pounds: convert kg to total
pounds (× 2.2046226), round half-to-even to the nearest pound, then
divmod by 14. Edge case: `13 st 13.6 lb` after the half-to-even round
becomes `14 st 0 lb`, not `13 st 14 lb`. Test this. (The rounding rule
is the same as the kg formatter; the carry is the new piece.)

**Goal rate stays in kg/week.** The active goal card renders `0.50 kg/week`
today; PM Risk 4 ruling 9 explicitly ruled rate to two-decimal
`kg/week`. Converting *rate* introduces a third axis (UK would expect
`lb/week`? `st/month`? — no, these aren't real conventions, they're
made-up parallel structure) and breaks the math people read on
deficit-rate charts. **Out of scope.** Architect note: when rendering
the active goal card under `weight_unit: lb`, the *weight targets*
(start, target) convert; the rate label keeps its `kg/week` suffix.
We will revisit this only if a user complains, and even then probably
not.

### Inputs

When a user logs a weight in the log-weight sheet or the onboarding
step 2 weight field, **they enter in their preferred unit**. The
Display Units Principle is bidirectional — the conversion happens on
save, not just on display. The architect's seam:

- `parseWeightInput(String raw, WeightUnit unit) → Decimal /* kg */`
  is the inverse of `formatWeight`. It's in `domain/units/weight.dart`.
  No widget calls it from outside the helper.
- For `kg` and `lb`, the input is a single field — a `QuantityStepper`
  (T-07) with the right step (0.1 kg or 0.2 lb), the right min/max,
  and a unit suffix label.
- For `st`, the input is **two fields side-by-side**: stones (integer,
  stepper, step 1) and pounds (integer, stepper, step 1, max 13).
  Render as a single labeled control "Weight (st · lb)". On save, the
  helper combines them. We do not invent a `12.5 st` decimal input —
  see the rationale above.
- **Decimal in, formatted out** (T-17) discipline holds end-to-end:
  the input value is parsed to a `Decimal` in kg, sent to the server
  as `weight_kg`, and re-formatted on display. No intermediate
  `double`. Round-trip stability: a value entered as `175.1 lb`,
  saved as kg, re-displayed in lb may show `175.1 lb` *or* `175.0 lb`
  depending on the half-to-even round of `175.1 lb → 79.4337 kg →
  175.1 lb` (the kg storage is the canonical truth). Document this
  in the formatter — the user-visible effect is at most ±0.1 lb on
  re-display, which is below the resolution of a real scale.

### Where the toggle lives

Profile → Preferences. The architecture's screen 08 brief and the
current `profile_screen.dart` already have a "Units" row inside the
`SettingsCard` titled "Preferences". Today it's informational
(`value: 'kg, cm, kcal, g'`, `onTap: null`). **Make it editable.** The
row becomes tappable, the value column reads the current weight unit
("kg" / "lb" / "st"), and the chevron drops back in to indicate
"opens a chooser".

The chooser is a **per-field modal sheet on compact, inline edit on
expanded** — the same pattern PM ruled for profile editing in
`pm_overnight_features.md` §10 item 7. Compact gets a bottom sheet
with three `ActivityOption`-shaped rows (Kilograms `kg` / Pounds `lb`
/ Stones `st`, each with a one-line caption like "Common in the US"
or "Common in the UK"); tap to select, the sheet closes, the PATCH
fires. Expanded gets a segmented select inline inside the
`SettingsRow` — same three options, same tokens.

**Not a segmented control on compact.** Three units in a segmented
control reads dense, and `st` doesn't shorten gracefully if we want
to add `kJ` for energy in v2 to the same Preferences card. The bottom
sheet has space; use it.

The row's caption changes from `"kg, cm, kcal, g"` to `"<unit>, cm,
kcal, g"`. The "cm, kcal, g" part remains informational (PM Risk 4
still keeps height, energy, and macros locked to v1 defaults — we
don't ship multi-unit there). Architect note: the SettingsRow's
`semanticsLabel` must update to read the *user's chosen unit* and
also say "Tap to change weight unit."

### Acceptance criteria

- A new `User.weight_unit: WeightUnit` field exists end-to-end:
  OpenAPI schema (required on `User`, optional on `ProfilePatch`),
  Rust migration with a `kg` default, Dart `User` model, Hive cache.
- `WeightUnit` is an enum with three values: `kg`, `lb`, `st`. The
  wire is the lowercase string.
- `domain/units/weight.dart` exposes
  `formatWeight(Decimal kg, WeightUnit unit) → String` and
  `parseWeightInput(String raw, WeightUnit unit) → Decimal /* kg */`.
  `formatWeightKg` continues to exist as a thin wrapper for backward
  compat or is deleted with all call sites migrated — architect's
  choice; I lean *migrate all call sites* for cleanliness.
- Locale default applies only when `User.weight_unit` is null/absent
  on first boot before onboarding's PATCH. Once the server holds a
  value, the server is canonical.
- Onboarding step 2's weight input label, stepper unit, and
  default-value rendering all respect the picked unit. A small unit
  chooser sits next to the weight input so the user can change the
  default if the locale picked wrong.
- The Profile → Preferences → Units row is **interactive**. Tapping
  it opens the unit chooser (sheet on compact, inline segmented on
  expanded). Selecting a unit PATCHes `weight_unit`, invalidates
  `meProvider`, and the change reflects everywhere on the next
  frame.
- Every weight render goes through `formatWeight`:
  - Onboarding step 2 weight field's label, validation hint, and
    pre-fill rendering.
  - Profile body section's current weight row + the
    `current_weight_sheet` editor's input + display.
  - Weight screen: summary card hero number, summary card delta pill,
    sparkline Y-axis labels, history list rows, log-weight sheet
    input + result toast ("Logged X for Wednesday").
  - Edit-goal sheet, new-goal dialog: start weight + target weight
    inputs + previews.
  - Today expanded right rail mini sparkline (header number + delta).
  - Active goal card on screen 07.
- The stone composite input renders two steppers (`st` + `lb`) when
  `unit == st`. Save combines them via `parseWeightInput`.
- No widget multiplies by 2.2046226 or `/14` inline. The architect
  greps the diff for those literals before merging.
- The "Coming soon" SnackBar that some agents shipped for unit
  changes (see §4 inventory) is deleted from this code path.
- `Semantics` labels include the displayed value with its unit
  ("Current weight 12 stone 7 pounds"). For stones, the screen reader
  reads "12 stone 7 pounds" (full words), not "12 st 7 lb."

---

## 4. Cross-feature: where this lands in the prior follow-up inventory

The architect's overnight follow-up list (`pm_overnight_features.md`)
called out a handful of stragglers: `Food.createdAt` exposure, two
stray spinners, a `Colors.white` sweep (B2), `new_goal_dialog` formula
split (A4 alignment), and "Coming soon" SnackBars. Most don't interact
with these two features, but two do, and they're worth naming so the
architect doesn't double-touch.

**Direct interactions.**

- **"Coming soon" SnackBars.** If any settings row (Units, Appearance
  if it exists by accident, etc.) emits a "Coming soon" SnackBar in
  the current codebase, the Units one goes away with Feature B.
  Architect: audit `settings_row.dart` and the profile screen for
  any "Coming soon" strings tied to Units; delete the corresponding
  guard.
- **`new_goal_dialog` and `edit_goal_sheet`.** Both contain a
  `start_weight_kg` + `target_weight_kg` input pair. They both need
  the weight-unit-aware input control. The A4 calorie-estimate lift
  doesn't directly conflict, but the *same* widgets get touched in
  both PRs — sequence Feature B after A4 lands if A4 is still in
  flight, to avoid merge conflicts on the goal forms.

**Indirect — name them so they don't get re-touched.**

- `Colors.white` sweep (B2) is unrelated; weights are text, not
  surfaces. Skip.
- `Food.createdAt` exposure is the My Foods sort key (A2-adjacent);
  unrelated to weight or log edit.
- The two stray spinners (A5 sweep) are unrelated; both edits and
  unit toggles happen in modal contexts that already comply with
  T-08 / T-13.

**Full inventory of files that touch weight rendering and must be
unit-aware** (the architect's checklist for Feature B):

```
lib/domain/units/weight.dart                              (the seam — only file with branching)
lib/domain/user.dart                                       (add weight_unit field)
lib/domain/drafts.dart                                     (onboarding draft holds the unit)
lib/repositories/profile_repository.dart                  (PATCH unit, decode unit)
lib/features/onboarding/onboarding_screen.dart            (step 2 weight input + unit chooser)
lib/features/profile/profile_screen.dart                  (Preferences → Units row interactive)
lib/features/profile/widgets/settings_card.dart           (no change; row content does)
lib/features/profile/widgets/current_weight_sheet.dart    (input + display in unit)
lib/features/weight/weight_screen.dart                    (axis labels in unit)
lib/features/weight/widgets/weight_summary_card.dart      (hero + delta + stats)
lib/features/weight/widgets/weight_sparkline.dart         (Y-axis labels)
lib/features/weight/widgets/weight_history_list.dart      (per-row weight render)
lib/features/weight/widgets/log_weight_sheet.dart         (input + toast)
lib/features/goals/widgets/goal_active_card.dart          (start/target weight render)
lib/features/goals/widgets/new_goal_dialog.dart           (start/target weight inputs)
lib/features/goals/widgets/edit_goal_sheet.dart           (start/target weight inputs)
lib/features/today/widgets/mini_weight_sparkline.dart     (header weight + delta)
```

16 files. Most are 5–20 line edits (swap `formatWeightKg(value)` for
`formatWeight(value, ref.watch(weightUnitProvider))`). The inputs
(log-weight sheet, onboarding step 2, current-weight sheet, the two
goal editors) are larger because of the stone-composite case. The
seam keeps the math out of every file in this list except the helper.

**Files that touch log-entry rendering and must wire tap-to-edit**
(the architect's checklist for Feature A):

```
lib/features/today/today_internals.dart                  (entry → handler binding)
lib/features/today/day_view_compact.dart                  (pass onEntryTap)
lib/features/today/day_view_expanded.dart                 (pass onEntryTap)
lib/widgets/meal_section.dart                             (no change — callback already plumbed)
lib/features/log_entry/log_entry_sheet.dart               (existing → edit-mode + PATCH path)
lib/repositories/log_repository.dart                      (new `update(id, LogPatch)` method)
lib/providers/log_providers.dart                          (invalidation on update)
```

7 files. The bulk of the work is `log_entry_sheet.dart` (edit-mode
plumbing + the PATCH call + the "pending row guard") and
`log_repository.dart` (the `update` method against the mock store).

---

## 5. Sequencing recommendation

**Ship them sequentially: Feature A first, then Feature B.** Not
because they conflict — they barely overlap — but because Feature B
is a sweep across 16 files and Feature A is structural inside the log
entry sheet, and landing the sheet's edit-mode change first reduces
merge pressure during the unit sweep.

Concretely:

1. **Feature A** lands as one PR (or one stack: the repository
   `update` + the `LogEntrySheet` edit-mode + the day-view wiring).
   No new tokens, no new widgets, no backend change (the endpoint
   exists). Reviewable in a single sitting.
2. **Feature B backend** lands next *if the user signs off* on the
   wire change. One Rust migration, one OpenAPI edit, one default-value
   ruling.
3. **Feature B client** lands after the backend (or in parallel
   behind a feature flag — see punt list). The 16-file sweep is
   mechanical once `formatWeight` exists. The Profile → Units row
   becoming interactive is the last thing wired so users don't see
   "broken setting" between the formatter landing and the chooser
   landing.

**Why not parallel.** Both features touch `LogEntrySheet` indirectly
(the sheet's optimistic snapshot recomputation in edit-mode uses
nutrition values that don't include weight — so no direct conflict),
but both features touch the onboarding flow (Feature A doesn't, but
Feature B does on step 2). The risk of co-shipping is that a unit-PR
hot patch to the onboarding step 2 weight stepper conflicts with an
unrelated edit-mode-related refactor in the same week. Sequential
ships keep the diffs narrow.

**Why not Feature B first.** Feature A is the *user's stronger
signal* — they led with "I want to click on a food and edit it,"
which is the clearer product gap (the tap is a no-op today). Shipping
the edit first lets the user feel an immediate improvement; the unit
preference is a deeper change that the user will feel once instead of
every day. Ship the felt-every-day improvement first.

---

## 6. Punt list

Things explicitly deferred beyond this feature pair, one-line
rationale each.

- **Height units (cm ↔ ft/in).** Punted. PM Risk 4 ruled v1
  cm-only, and the user explicitly named "weights" — not height.
  Defer to a v2 ticket. (Same justification as the original Risk 4
  ruling; we're not opening a second axis without a user ask.)
- **Energy units (kcal ↔ kJ).** Punted. EU/AU labels carry kJ
  alongside kcal rather than instead of it, and no user has asked
  for it. The v2 ticket already exists.
- **Goal rate in lb/week or st/month.** Punted. Rate is `kg/week`
  in `Goal`, that's how the math reads, and there is no clean parallel
  in lb/st conventions. Rate keeps its `kg/week` suffix even under
  `weight_unit: lb`. We will reopen this if a user complains; we
  expect no one will.
- **Editing the food a log entry references.** Punted. The OpenAPI
  explicitly forbids `food_id` mutation on PATCH; "edit" means
  "delete + create" by design. The sheet header is read-only.
- **Field-level last-writer-wins conflict between two clients editing
  the same log entry.** Punted. v1 has no concurrent-edit story (one
  user, one device session, dev bearer token). When real auth and
  multi-device land, we revisit.
- **Edits queued through the outbox.** Punted by deliberate ruling
  (see Feature A "Conflict + concurrency"). Edits require connectivity;
  pending rows are not editable until they ack.
- **A separate edit-route (`/log/:id/edit`).** Considered, rejected.
  Sheet/dialog is the right shape; routes are for shareable state
  (T-14).
- **A long-press "Quick edit quantity" menu.** Considered, rejected.
  Half-feature; the sheet covers it.
- **Server-side enforcement of `weight_unit` on `WeightEntry` payload
  (i.e. accepting `weight_lb` on the wire).** Punted. The wire stays
  canonical kg per the Display Units Principle. The user types lb,
  the client parses to kg, the server stores kg. Same for st.
- **Multi-locale decimal-separator handling in the lb / st input
  parsers.** Punted for the architect's discretion. `intl`
  `NumberFormat` already locale-aware-renders kg; the architect
  decides whether the lb / st inputs accept "175,1" in
  comma-decimal locales or normalize on parse. Either is fine — pick
  one and document it. (Note: stones are British, and the British
  locale uses `.`, so the practical surface is `lb` in non-en-US
  locales.)
- **Feature-flagging Feature B's client work behind the backend
  migration.** Considered. Architect's discretion: if the backend
  migration ships before the client sweep, expose `weight_unit` from
  `User` but keep the formatter kg-only behind a Hive-stored
  client-side override. If the client sweep ships before the backend
  migration, gate the chooser behind an environment flag and bypass
  the PATCH (write to local-only storage). I lean toward
  back-then-front sequential; flag is the safety valve.
