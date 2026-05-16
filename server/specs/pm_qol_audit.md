# PM QoL Audit: Fulfilled Flutter Client

The user — having just shipped log-entry editing and weight-unit
preferences — pulled the rip cord on a wider polish pass. They named
two friction items by hand and explicitly delegated the rest of the
audit to PM judgement. This doc is the contract for that audit. Like
`pm_log_edit_and_units.md` it picks a direction per item, names the
seam the architect should touch, and refuses to design backend changes
unilaterally. The frontend architect's plan lands after this; this doc
is the tiebreaker against the mocks and the per-screen briefs in
`specs/flutter_ui_architecture.md` §9.

---

## 1. Context

The Flutter client is shipped end-to-end against the mock data layer —
nine architecture-named screens plus the late-added `/foods/mine`,
the barcode resolver, the custom-food editor, and the goals screen.
The seams are clean (T-23 holds, `lib/widgets/` is canonical,
`lib/domain/units/weight.dart` is the only unit-conversion site,
`lib/domain/calories/estimate.dart` is the only BMR/TDEE site). The
client *works*. What's left is the gap between "works" and "feels
ready." The user has a list of small papercuts — naming the two
sharpest ones — and asked PM to find the rest in one coordinated
pass. This is that pass. The bar is **coherence after the pack
lands**, not feature volume. Some items are nudges; some are
structural and worth promoting to architect attention.

Reading order:

- `specs/flutter_ui_architecture.md` — T-01..T-23, screen briefs.
- `specs/pm_decisions_flutter_ui.md` — Display Units Principle,
  PM Risks 1–6.
- `specs/pm_log_edit_and_units.md` — the most recent feature pack;
  this audit mirrors its prose and seam-naming.
- `specs/pm_overnight_features.md` — Tier A/B/C overnight pack;
  the punt list at the end of that doc still applies here.

---

## 2. The two user-named items (P0)

### 2.1 QL-001 — Height units (user-selectable, mirrors weight)

**User story.** As a US or UK user setting up Fulfilled, I expect to
enter and read my height the way my driver's license reads it —
`5 ft 9 in`, not `175 cm`. As a metric user, I want `cm` because
that's what every doctor's office I've stepped into uses. The
preference follows me across devices, exactly like my weight unit.

**Decision.** **Ship a `User.heightUnit` wire field with the same
shape and seam discipline as `User.weightUnit`.** Three values:
`cm` (default), `ft_in` (composite — feet integer + inches integer
0–11). **Do not ship a metric `m` option** (nobody enters their
height in meters), do not ship `inches-only` (nobody describes
themselves as "69 inches"), and **do not invent `mm`** — it's not a
human-facing height unit anywhere. The unit chooser offers two
options; the segmented control reads cleanly with two and we have
v1 precedent (weight) for it.

**Locale default chain — opinionated.** Same shape as
`weightUnit`'s `defaultWeightUnitForLocale()`:

```
1. countryCode == 'US' || 'LR' || 'MM'        → ft_in
2. countryCode == 'GB'                         → ft_in
3. anything else, or countryCode is null       → cm
```

The GB inclusion is the carve-out. The UK uses metric for most things
medical but conversational/personal height is overwhelmingly imperial
("five-nine") — the same pattern that pushed `st` for weight in the
UK. We pre-pick `ft_in` for GB and let the user flip to `cm` from
Profile → Preferences if they disagree. The user has explicitly
delegated this call; we make it. If a UK user complains, two-line
chooser flip.

**Display format.**

| Unit    | Format         | Examples              | Decimal rule                   |
|---------|----------------|-----------------------|--------------------------------|
| `cm`    | integer + `cm` | `175 cm`, `182 cm`    | round half-to-even to integer  |
| `ft_in` | composite      | `5 ft 9 in`, `6 ft 0 in` | integer feet, integer inches (0–11), no fractional inches |

**Why composite, not decimal feet.** `5.75 ft` is not how anyone says
their height. `5 ft 9 in` is what driver's licenses, sports rosters,
and conversation use. The same user-recognition test that drove
stones-as-composite drives this. Composite costs one ~25-line
formatter and a two-stepper input affordance for `ft_in`.

**Inputs.** Mirror weight:

- **`cm`** — single `_NumberStepper` with `cm` suffix, integer steps,
  bounds 80–250.
- **`ft_in`** — two side-by-side steppers: feet (integer, 3–8) and
  inches (integer, 0–11). On commit, parse to canonical cm:
  `cm = (feet * 12 + inches) * 2.54` rounded half-to-even to integer.

**Seam — architect's checklist.** Add `lib/domain/units/length.dart`
exposing:

- `formatHeight(Decimal cm, HeightUnit unit) → String`
- `parseHeightToCm(int feet, int inches) → Decimal` (canonical cm)
- `parseHeightToCm(int cm) → Decimal` (identity wrapper for symmetry)
- `defaultHeightUnitForLocale() → HeightUnit`

A new `HeightStepper` widget — the natural sibling of `WeightStepper`
— that internally renders either the cm stepper or the ft+in dual
stepper. Drop the inline `_NumberStepper` + `_formatHeightCm` in
`step_2_about_you.dart` (the `_formatHeightCm` helper is already
flagged for v2 lift — this is v2 closing the comment).

**Backend implication — flag for the user, do not design
unilaterally.** Same shape as the weight migration:

- Rust migration: `users.height_unit` as enum/text + check constraint
  (`'cm' | 'ft_in'`), default `'cm'`.
- OpenAPI: `User.heightUnit` required (server-default), `UserPatch
  .heightUnit` optional.
- Client tolerates absence by defaulting to `cm` (the existing
  no-op behaviour), so the wire change is **additive and non-breaking**
  — the client can ship in lock-step or behind a feature flag.

**Recommendation.** Ship the backend column. It's a one-column
migration, additive, mirrors the just-shipped weight-unit migration.
The alternative — client-only Hive storage — fails the same
"cross-device parity" test that pushed weight to the wire.

**Acceptance criteria**

- `User.heightUnit` field exists end-to-end: OpenAPI, Rust migration,
  Dart `User` model, Hive cache.
- `HeightUnit` enum has two values: `cm`, `ftIn`. Wire is snake-case
  lowercase string (`cm`, `ft_in`).
- `lib/domain/units/length.dart` exposes the four functions named
  above. Nowhere else multiplies by 2.54 or divides by 12.
- Locale default applies only when `User.heightUnit` is absent on
  first boot before onboarding's PATCH.
- Onboarding step 2's height input uses `HeightStepper` and respects
  the picked unit. A small unit chooser (segmented, two options) sits
  next to the unit chooser for weight — single "units" row, two
  segmented controls below it, one labeled "Height" and one "Weight".
- Profile → Preferences → Units row's value reads `<weight>, <height>,
  kcal, g` (e.g. `lb, ft·in, kcal, g`). Tapping it opens a chooser
  that now offers both units in a stacked layout (sheet on compact,
  popup menu on expanded). Editing one preference doesn't dismiss
  the other.
- The `_formatHeightCm` flag in `step_2_about_you.dart` is removed
  along with the inline `_NumberStepper`, replaced by `HeightStepper`.
- The height row in Profile → Body renders via `formatHeight` —
  `"5 ft 9 in"` when `unit == ft_in`, `"175 cm"` when `unit == cm`.
- The `current_weight_sheet` is unaffected; this audit does not
  re-touch weight.
- `Semantics` label reads the full long form ("Height 5 feet 9
  inches" / "Height 175 centimeters") so screen readers don't get
  abbreviations.

**Punted under this item.**

- A `m` (meters) display option. Not a real height unit anywhere.
- Decimal inches (`5 ft 9.5 in`). Not how anyone tells you their
  height; matches the "no decimal stones" call.
- A `mixed-locale` per-quantity override. The chooser flips both.

---

### 2.2 QL-002 — Saving a log entry returns to Today (for that date)

**User story.** As a user who tapped Search → tapped a food row →
tapped "Add to log" → adjusted serving → tapped Save, I expect to
land on today's day-view with my entry already in the ring. Today
I land back on the food-detail page I came from, which makes no
sense — the entry's already saved; that page is for picking food
to log, not for staring at after I logged.

**Decision: define "home."** When a `LogEntrySheet` save succeeds,
the app routes to **the day-view for the entry's `consumedOn` date**.
Concretely:

- If the entry's `consumedOn` is the user's local today → `context.go
  (Routes.todayPath)` (the bare `/today`, which is the canonical
  "today right now" path per `today_internals.dart`'s `navigateDay`
  precedent).
- Otherwise → `context.go('/today/$y-$m-$d')` with the entry's date.

**Why `go`, not `push`.** `push` stacks frames; we'd end up with
Today on top of Food Detail on top of Search on top of Today, and
the system-back button would walk a user backwards through their
own log flow. `go` *replaces* the stack to the day-view, which is
correct: after saving, there's no "back to Food Detail" affordance
the user wants.

**Why route, not pop-many.** `Navigator.popUntil(isFirst)` would land
in the right rough area on compact but break the dialog case on
expanded (where the sheet is a `Dialog`, not a route in the stack).
`context.go(...)` works uniformly on every form factor.

**Edit-mode vs create-mode.** In **edit mode**, route the same way
— go to the entry's (possibly-changed) date. The user editing a
backdated entry expects to land on that date's day view, not on
today's. The save flow already invalidates both old-date and
new-date providers; the navigation just follows.

**Scope of the rule — bundle related sheets.** Saving from these
sheets / flows should land the user on the right home. This is the
*audit*; see also QL-003 for the cross-cutting rule.

- `LogEntrySheet` save (create and edit) → `/today` or `/today/:date`
  for the entry's consumed date.
- `LogWeightSheet` save → no change. The user is already on `/weight`;
  the sheet pops, the SnackBar confirms, the chart updates. The user
  expects to stay on the weight screen so they can scroll the
  history they just added to.
- `CustomFoodScreen` save (create) → currently pops to wherever they
  came from. That's actually usually fine (search → create custom
  → back to search), but with one exception: if they navigated
  `/today → search → "create from scratch" → save`, popping lands
  them at search not Today. **Punt** the deep refactor; QL-003 names
  it. For the create-custom path, the existing `context.pop(food)`
  is acceptable.
- `CustomFoodScreen` save (edit) → existing pop behaviour is correct
  (user came from `/foods/:id/edit`; popping returns to the food
  detail they were editing).
- New / Edit Goal → user is on `/goals` already; pop. No change.
- Profile editor sheets (height, current weight, sex, etc.) → pop;
  user expects to stay on `/me`. No change.

So the practical impact is *just* `LogEntrySheet`. The single-symptom
fix is narrow.

**Backend implication.** None.

**Acceptance criteria**

- `LogEntrySheet._onCreatePressed` and `._onEditPressed` route via
  `context.go(...)` to the entry's `consumedOn` date instead of
  popping the sheet's route. The pop happens implicitly because the
  sheet is the topmost route on compact and `Navigator.maybePop` is
  benign on dialog-as-route.
- On the dialog (expanded) path, the sheet is a `showDialog` not a
  route — explicitly `Navigator.of(context).pop(result)` first, then
  `context.go(...)`. Order matters: dialog must close before the
  route change so the dialog frame doesn't orphan against the new
  page.
- The outbox/optimistic-insert path (compact, create-mode) also
  routes after the optimistic pop. The SnackBar "Logged — syncing"
  still fires; the user lands on Today with the optimistic row
  already visible.
- The outbox-failure path stays put (sheet stays open with input
  intact) — same as today. No silent navigation on failure.
- The edit-mode no-op-PATCH branch (`patch.isEmpty`) routes too —
  the user pressed save and expects to land at Today even if nothing
  changed.
- Tests cover the four paths: compact-create, compact-edit,
  expanded-create, expanded-edit. Test fixture: open the sheet from
  Food Detail, save, assert the current location is `/today` (or
  `/today/2026-05-15` for a backdated entry).
- The route helper that constructs the path is **shared** with
  `navigateDay` in `today_internals.dart`. Don't duplicate the
  date-to-path math.

**Open question for architect (not blocking).** Whether the food
detail page (`/foods/:foodId`) — having been replaced in the stack —
needs a "back" affordance restored from the Today day-view. The user
might want "actually, I want to log a second serving" and pre-fill
the same food. PM: **don't add that affordance**. The day-view's
food row is already tappable (edit-mode opens the sheet pre-seeded),
and the standard flow is "search again for second food." Adding a
"recent food" affordance is QL-007 territory.

---

## 3. Audit findings (QL-003 through QL-018)

Numbered for review citation. Priority and effort are PM-assigned;
the architect can re-grade in their implementation plan. Items are
ordered roughly P0 → P1 → P2 but the IDs are not priority-ordered —
read the **Priority** line on each.

### QL-003 — Audit ALL post-save / post-mutation navigation

**Where.** Cross-cutting. Specifically:
`features/log_entry/log_entry_sheet.dart`,
`features/custom_food/custom_food_screen.dart`,
`features/weight/widgets/log_weight_sheet.dart`,
`features/goals/widgets/edit_goal_sheet.dart`,
`features/goals/widgets/new_goal_dialog.dart`,
`features/profile/widgets/{height,current_weight,sex,birth_date,
activity_level}*.dart`.

**Today's behavior.** Each sheet decides for itself what to do after
save. The log sheet pops (wrong — QL-002), the weight sheet pops
(right), the custom-food screen pops (mostly right), profile editors
pop (right), goal editors pop (right). Six sheets, six independently
implemented post-save handlers, no shared rule. The user can't tell
why some pops "feel right" and one doesn't because the rule isn't
named.

**Proposed behavior.** Make the rule explicit. Three cases:

1. **Logging an entry** (the *act* — `LogEntrySheet`) → route to the
   entry's day-view (QL-002).
2. **Editing a profile field, weight, goal, or custom food** → pop
   the sheet/dialog; the user expects to stay on the screen they
   launched the editor from. Confirmation via SnackBar.
3. **Creating a new long-lived thing** (custom food, goal) → pop.
   The user can re-navigate from where they are. The exception is
   "create custom food from search-empty-state" — punt that
   contextual return-to-source as a v1.1 ticket.

Encode it in one place — a `SaveFlowRouter` helper or just a code
comment + grep — so future sheets aren't re-litigated. Architect's
discretion; PM only requires that the rule is named and applied
consistently. The `LogEntrySheet` case is the only one that
*changes* behavior today; the rest are confirmations.

**Why.** A consistent rule means future sheets don't re-debate this.
The log-entry case isn't a one-off bug; it's a symptom of the rule
not existing.

**Priority.** P0 (bundled with QL-002).
**Effort.** S — once the rule is named, the only code change is
QL-002 itself. The audit on the other six sheets is documentation.

---

### QL-004 — Unify the unit-preference seam to support height + future

**Where.**
`lib/domain/units/weight.dart`,
`lib/domain/units/length.dart` (new),
`lib/providers/profile_providers.dart` (the `weightUnitProvider`),
`lib/features/profile/widgets/weight_unit_chooser.dart`.

**Today's behavior.** Weight is shipped with a per-unit provider
(`weightUnitProvider`), a per-unit chooser (`weight_unit_chooser
.dart`), and a per-unit `formatWeight`. When QL-001 lands we'll
duplicate all three for height. The third time (kJ for energy, or a
hypothetical "force date format") this pattern repeats, the seam is
the bug.

**Proposed behavior.** Introduce a `userPreferencesProvider` (or
similar) that exposes all display-unit preferences as one observable
record (`weightUnit`, `heightUnit`, future `energyUnit`, etc.) and a
single `UnitChooserSheet` that takes the preference set as input and
renders N segmented controls. The existing per-unit `formatX(value,
unit)` functions stay — that's the right granularity for leaves.

**Why.** Three identical units of code is a refactor smell; the
architect named the unit seam once (`lib/domain/units/`) but the
preference seam is per-unit and will continue to grow. Generalize
*before* QL-001 doubles it.

**Priority.** P1 (refactor; preferable to land *before* QL-001
client work but the architect can choose).
**Effort.** M.

---

### QL-005 — Replace remaining `CircularProgressIndicator`s with skeleton/inline

**Where.**
`routing/app_router.dart:309` (`_BarcodeResolveScreen`),
`widgets/primary_button.dart:92` (button-level loader),
`features/weight/widgets/log_weight_sheet.dart:482` (save button),
`features/profile/widgets/editor_footer.dart:73` (profile editor
footer).

**Today's behavior.** Four leftover spinners violate T-08 and the
"button-level skeleton" pattern established in `log_entry_sheet.dart`
(see `_SaveButtonSkeleton`). The barcode resolver is the most
visible — a full-screen centered spinner that flashes for ~80 ms on
cache hits is worse than no animation at all.

**Proposed behavior.**

- Barcode resolver: replace centered `CircularProgressIndicator` with
  a `Skeleton` block sized to the eventual food-detail hero, so the
  layout doesn't jump when the resolver redirects.
- `PrimaryButton`'s loading state: swap to the same skeleton-bar
  pattern as `_SaveButtonSkeleton` in `log_entry_sheet.dart`. Single
  pattern, one widget — extract to `widgets/button_loading_bar.dart`
  if it's used in more than two places.
- `log_weight_sheet.dart`'s save button: same swap.
- `editor_footer.dart`'s save button: same swap.

**Why.** T-08 is a tenant. The `pumpAndSettle`-friction note in
`log_entry_sheet.dart`'s `_SaveButtonSkeleton` docstring already
named the underlying reason (indefinite animations break test
suites). Closing the gap now means tests don't sprout one-off
timeouts.

**Priority.** P1.
**Effort.** S.

---

### QL-006 — Delete or wire the "Save" bookmark icon on Food Detail

**Where.** `features/food_detail/food_detail_screen.dart:256-262`.

**Today's behavior.** The food-detail app bar renders a bookmark
icon with `tooltip: 'Save'` and an empty `onPressed`. The comment
says "Save-to-favorites lives on a parallel agent's surface; this
screen owns the entry point only. No-op until that lands." That
parallel agent's surface never landed.

**Proposed behavior.** Delete the icon for v1. A button that does
nothing erodes trust faster than a missing feature. When favorites
ship, restore it.

**Why.** Same shape as PM Risk 2 (auth link) and PM Risk 5 (dark
mode) — non-functional UI ships nothing.

**Priority.** P1.
**Effort.** S.

---

### QL-007 — Resolve "Coming soon" SnackBars: wire or remove

**Where.**
`features/profile/profile_screen.dart:235` (Export data),
`features/profile/profile_screen.dart:351` (identity Edit).

**Today's behavior.** Two "Coming soon" SnackBars on settings rows
that look tappable. Same shape as the bookmark above — the user
finds a tappable affordance, taps, gets nothing.

**Proposed behavior.**

- **Identity Edit.** The display-name and email editor doesn't exist
  in the mocks. Two options: (a) ship a minimal sheet with two text
  fields + a Save — the architect named the per-field-modal pattern
  for the profile screen; this is just two more fields. (b) **Hide
  the Edit button** until auth ships (consistent with PM Risk 2).
  PM call: **(b)**. The Edit row implies an identity story we don't
  have; we cut the row entirely. When auth lands the row returns
  alongside the welcome-link.
- **Export data.** Hide the row in v1. Export is real product
  surface (CSV format? PDF? what's "data"?) and a v1.1 ticket. The
  Data card just renders "My foods" until Export is designed.

**Why.** Two settings rows that don't work are two more "is this app
finished?" tells.

**Priority.** P1.
**Effort.** S.

---

### QL-008 — Autofocus inputs on first-paint where it's the only reasonable action

**Where.** Multiple sheets and screens.

**Today's behavior.** The search screen autofocuses its field
correctly. The `LogEntrySheet` does **not** autofocus the quantity
stepper (the user has to tap the field). The custom-food screen does
**not** autofocus the name field. The log-weight sheet does not
autofocus the weight stepper. The `MyFoodsScreen` filter doesn't
autofocus. The current-weight sheet, height stepper sheet, etc. all
fail the same test.

**Proposed behavior.** Autofocus the **first** input when:

- The sheet/screen exists *because of* the input (log entry quantity,
  log weight value, height stepper, current weight stepper,
  custom-food name on create).
- The sheet is **NOT** edit-mode (in edit mode, the user is reviewing
  pre-filled values — autofocus would steal focus to a field they
  don't necessarily want to change first).
- The autofocus respects the keyboard-dismiss-on-drag pattern
  already in place (`ScrollViewKeyboardDismissBehavior.onDrag`).

The `MyFoodsScreen` filter is the exception: it does **not**
autofocus, because the page's primary action is "scroll the list,"
not "filter immediately." The filter is the secondary affordance.

**Why.** Each autofocus is one tap saved. Across a heavy-logging
day that's 20+ taps a user doesn't have to make.

**Priority.** P1.
**Effort.** S — `autofocus: true` on a TextField is one line per
site, but the audit needs to cover ~8 sheets so it's a careful pass.

---

### QL-009 — Today day-view: opening a backdated date keeps no breadcrumb

**Where.** `features/today/today_internals.dart` (`navigateDay`),
`features/today/day_view_compact.dart` / `day_view_expanded.dart`.

**Today's behavior.** From `/today`, chevron-left navigates to
`/today/2026-05-15` via `context.go(...)`. Once there, chevron-right
from the past day returns to `/today` (good). But if the user has
chevron-walked five days back and wants to return, they tap five
times. There's no "Jump to today" affordance.

**Proposed behavior.** When `date != local-now`, render a small
"Today" pill in the date bar that tapping calls `navigateDay` back
to today. Visually a chip in the date row, between the title and
the chevrons. The pill is hidden on the canonical `/today` view.
The compact and expanded date bars share the rule via
`today_internals.dart`.

**Why.** The most-viewed screen is Today. The chevron is the only
way back today; one pill saves N taps.

**Priority.** P1.
**Effort.** S.

---

### QL-010 — Pending-sync edit guard: SnackBar is the only feedback

**Where.** `features/today/today_internals.dart` (`editLogEntry`).

**Today's behavior.** Tapping a pending-sync row on Today fires the
"Still syncing — edit when sync finishes" SnackBar (good, T-22
honored) and bails. But the row itself doesn't visually communicate
*why* the tap was rejected — the user might tap twice, thinking
they missed.

**Proposed behavior.** Add a brief hover-equivalent feedback on the
row itself — a 200ms tint cycle to `dangerSoft` on rejected tap, so
the user sees "your tap registered, just wasn't allowed." Same
pattern any disabled-but-tappable affordance should follow. Pair
with the existing SnackBar; this is supplementary feedback, not
replacement.

**Architect note.** Consider making the row's `Semantics` label
include `"Still syncing — edit unavailable"` so screen-reader users
get the same disambiguation without the visual cue.

**Why.** Color-only feedback isn't sole-signal (T-20) but a 200ms
flash *plus* a label *plus* a SnackBar is the right belt-and-braces.

**Priority.** P2.
**Effort.** S.

---

### QL-011 — Date-picker affordance density: log-entry sheet hides it inside Serving

**Where.** `features/log_entry/log_entry_sheet.dart`.

**Today's behavior.** The log-entry sheet has a SERVING / QUANTITY /
MEAL / NOTE sequence. The **date** isn't a labeled field — it's
implicit (the entry's `consumedOn` defaults to today and gets re-set
on save). The user has no way to backdate from within the sheet.
Edit-mode does seed the date from the entry, but there's no
visible-tap-to-change date row in the sheet body. The user can only
backdate by chevron-walking to a different day on Today *before*
opening the sheet.

**Proposed behavior.** Add a `DATE` section between MEAL and NOTE,
matching the pattern in `log_weight_sheet.dart`'s `_DateRow`. Tap
opens `showDatePicker` with `firstDate: today - 1 year, lastDate:
today`. Selected date updates `_date` and re-renders the preview's
implicit context (none — the math is per-quantity, not per-date).
Default-collapsed to today; the row label reads `"Today · May 16"`
or the backdated date.

**Why.** "I forgot to log breakfast yesterday" is a normal
calorie-tracker scenario. The current workaround (chevron back,
re-search) is friction.

**Priority.** P1.
**Effort.** S.

---

### QL-012 — Touch-target audit: small icons in stepper sheets and date pills

**Where.** Cross-cutting; specifically the close `x` buttons in
`log_weight_sheet.dart`, `log_entry_sheet.dart`, and editors.

**Today's behavior.** The close `x` button in `log_entry_sheet.dart`'s
`_Header` is 30 px (line 676-684). The log-weight sheet's close
button is 36 px. T-06 requires ≥ 44 px hit-slop on compact, with a
visible-target floor lower than that. The 30 px target's `InkResponse
.radius: 24` partially compensates but the visible affordance is
still small enough that fat-finger misses cluster.

**Proposed behavior.** Standardize on 44 px hit slop with 30 px
visible icon for all close `x`s. The lifted `IconButton36` already
does this for app-bar icons — extend the rule to sheet headers via
a shared `SheetCloseButton` widget in `lib/widgets/`. Audit all
sheets in one pass; replace ad-hoc `InkResponse(child: Container(...
,
shape: BoxShape.circle))` with the canonical widget.

**Why.** T-06 is non-negotiable on mobile; the seam is the canonical
widget, not per-sheet vigilance.

**Priority.** P1.
**Effort.** S.

---

### QL-013 — Empty-state CTAs on Goals + Weight history are good; missing on Today's empty meals

**Where.**
`widgets/meal_section.dart`,
`features/today/widgets/quick_add_chips.dart`.

**Today's behavior.** The architect deliberately decided that an
empty meal section renders the header with `0 kcal` and a dimmed dot
(architecture §9 Screen 01 gotcha — "don't render `EmptyState`
inside an empty meal"). That's correct for "empty Dinner at 9 AM"
because Dinner will get entries later. But for a **fully empty day**
— all four meals zero — the user just sees four dim section headers
and a FAB. The Quick add card on expanded is the right answer there;
compact doesn't have one.

**Proposed behavior.** On compact, when *every* meal section is
empty AND the date is today, render a one-line accent-soft pill
between the ring summary and the meal sections: `"Tap + to log your
first food"` with the FAB as the implicit affordance. The pill
disappears the moment the first entry lands. On non-today empty
days, no pill — the user is in a known-empty backdate.

**Why.** The brand-new user lands on Today with zero data and no
prompt; the FAB is discoverable but a one-line nudge is the
difference between 30 seconds of confusion and zero. The expanded
right rail already does this via `B9` Quick add empty state; this is
its compact-day-view sibling.

**Priority.** P2.
**Effort.** S.

---

### QL-014 — Onboarding: no back-out, no restart, no skip

**Where.** `features/onboarding/onboarding_screen.dart`.

**Today's behavior.** A user who completes step 1 and decides
"actually, I want to back out and check something" has no system-back
affordance on web (the only back is the `_go(1)` button on step 2/3).
On mobile, system back works but exits the app rather than gracefully
re-opening "are you sure?" The flow is one-way-forward.

**Proposed behavior.**

- **Step 1** — the "Get started" CTA. No back state to back out to.
  No change.
- **Step 2 / 3** — already have a `onBack` button; verify it's wired
  on every breakpoint and prominent enough.
- **Mid-flow re-entry.** If the user closes and re-opens the app
  mid-onboarding, the draft persists (already true via
  `onboardingDraftProvider`). The route is `/onboarding/2` on
  re-entry. Good.
- **Restart.** Add a small "Start over" affordance on step 3 — a
  text button under the primary CTA — that resets the draft and
  routes to step 1. The user who realizes their birth date is wrong
  on step 3 currently chevron-backs twice; "Start over" is a single
  tap.
- **Skip.** **Do not add a skip affordance.** Onboarding is the path
  to a meaningful TDEE estimate; skipping produces a worse first-run
  experience. The user who genuinely doesn't want to fill in their
  height has the (separately punted) "real auth + skip-to-login"
  path.

**Why.** The flow has the bones of a recoverable onboarding but the
restart affordance is missing. Skip stays gated behind real auth.

**Priority.** P2.
**Effort.** S.

---

### QL-015 — Profile editor sheets: dismissing without saving silently keeps the typed value

**Where.**
`features/profile/widgets/height_stepper_sheet.dart`,
`features/profile/widgets/current_weight_sheet.dart`,
`features/profile/widgets/sex_picker.dart`,
`features/profile/widgets/birth_date_picker.dart`,
`features/profile/widgets/activity_level_picker.dart`.

**Today's behavior.** The profile editors all pop on Save (good).
On dismiss (swipe-down, tap-outside, Esc on expanded), they all
discard. Mostly good — but the height stepper specifically retains
local edit state inside the `TextEditingController` even though it
doesn't write to the repository. The user who taps "Cancel" and
re-opens sees the form re-initialized to the server value, which is
correct.

So actually the behavior is fine. The audit finding is **defensive**:
add a regression test that opening, editing, and dismissing without
save leaves the repository unchanged. Currently nothing pins this
behavior; an architect refactor that "improves" the dismiss handler
to write on close would silently break it.

**Proposed behavior.** Test coverage only — no behavior change.

**Why.** The implicit-discard rule is correct but un-tested.

**Priority.** P2.
**Effort.** S — test only.

---

### QL-016 — Goal active card: target weight + start weight format leaks via per-screen pipe

**Where.**
`features/goals/widgets/goal_active_card.dart`,
`features/goals/widgets/new_goal_dialog.dart`,
`features/goals/widgets/edit_goal_sheet.dart`.

**Today's behavior.** Per the existing weight-unit work, every
weight render flows through `formatWeight` (T-21). The architect
checklist names `goal_active_card.dart`, `new_goal_dialog.dart`,
and `edit_goal_sheet.dart` in the 16-file weight sweep. Verify the
sweep landed there cleanly and that the goal-creator's start/target
weight inputs use the `WeightStepper` widget (not bare
`QuantityStepper(unitSuffix: 'kg')`).

**Proposed behavior.** Audit-only — grep for `kg` literals, audit
the goal forms specifically.

**Why.** The architect plan was sound; this is a verification ticket
to confirm. Tied to QL-001 (the height ticket re-touches the same
forms, so audit now before the sweep doubles).

**Priority.** P2.
**Effort.** S.

---

### QL-017 — Search highlight is correct; empty-query state has a quiet stale-result flash

**Where.** `features/search/search_screen.dart` (`_ResultsSection`).

**Today's behavior.** When the user types a query, results render.
When they clear the query (backspace to empty), the screen transitions
back to the Recent / Frequent chips. On a fast device the transition
is clean; on a throttled mock or a real-network slow case, the
results from the last query stay visible for the duration of one
`foodSearchProvider` debounce window (250 ms) before clearing. The
user sees "Greek yogurt" results behind the chips for a quarter-
second.

**Proposed behavior.** When `_query` becomes empty, eagerly clear
the results UI without waiting for the provider to settle. The
`isQueryActive` ternary already does this in the build method;
verify it covers the rebuild path on `_onQueryChanged('')`.

**Why.** Minor jitter. The fix is one ternary or one early return.

**Priority.** P2.
**Effort.** S.

---

### QL-018 — Custom-food save: "couldn't add all servings" error eats the failure detail

**Where.** `features/custom_food/custom_food_screen.dart:299-307`.

**Today's behavior.** When `repo.addServing` fails for *any* serving
in the loop, the user sees the SnackBar `"Saved the food but
couldn't add all servings"`. The food itself is saved; the failed
servings are just dropped. The user can't tell *which* serving
failed (was it the first one I added? the third?) and there's no
retry affordance.

**Proposed behavior.** Track which servings failed (already mostly
done via `anyServingFailed`) and route the user to
`/foods/$foodId/edit` with the failed servings still in the local
draft. The user sees "your food saved, but X servings need a retry"
SnackBar with a "Fix" affordance that opens the edit screen with the
missing servings pre-filled. Architect's discretion on the exact
mechanism — a draft `pendingServings` field, or a query parameter
`?retry=...`, or a Hive box.

**Why.** Today's behavior is data loss without the user's awareness.
The food saved, sure, but the user typed three servings and only
two landed and they don't know.

**Priority.** P2.
**Effort.** M — touches the draft, the screen state, the edit-mode
seam.

---

## 4. Cross-cutting patterns (architect read this first)

The items below are not single-screen bugs; they're seams the
architect should examine in one pass before the QL items get
delegated to dev agents.

### Pattern A — A unified post-mutation navigation rule

QL-002 names *one* symptom; the rule it implies is "after a
mutation, the user lands where they expect to consume the
mutation's effect." The implied rule today is "the sheet pops, the
user picks up from where they were." Those agree for editor sheets
(height, current weight, etc.) and disagree for the log-entry
sheet (the user wants the day-view, not the food-detail page they
came from). A future "log multiple foods at once" or "import from
photo" flow has the same problem.

**Recommendation.** Codify a `SaveFlowResult` enum or a comment in
`flutter_ui_architecture.md` §9 per-screen briefs. Three cases:
*pop-to-source* (editors), *route-to-affordance-of-effect*
(log-entry → day-view), *pop-with-payload* (search → food-detail
→ select). Each per-screen brief names which one applies. Future
sheets get reviewed against the rule. This is a 10-line spec edit
that pays off the next time a sheet is added.

### Pattern B — The unit-preference seam needs generalization

QL-001 *will* duplicate every weight-preference pattern for height.
QL-004 names the seam. Honoring it now means the third axis (kJ
when it lands, or any future per-unit pref) is a one-line addition
instead of a three-axis-times-five-files copy. The architect named
`lib/domain/units/` as the single conversion seam; this just adds
"…and `lib/providers/user_preferences.dart` is the single preference
seam." Pair the two.

### Pattern C — Post-mutation provider invalidation

Today every sheet picks its own invalidation list:

- `log_entry_sheet.dart`: `daySummaryProvider`, `logEntriesProvider`,
  `recentFoodsProvider`, `frequentFoodsProvider`; old-date variants
  on date change.
- `custom_food_screen.dart`: `meProvider`, `customFoodCountProvider`,
  `foodDetailProvider`, plus `myFoodsProvider` on edit.
- `log_weight_sheet.dart`: `weightSeriesProvider` (5 ranges),
  `weightHistoryProvider`, `meProvider`.
- `height_stepper_sheet.dart`: `meProvider`.
- `goals/*`: `activeGoalProvider`, `goalsProvider`.

T-18 says "minimal and explicit, not shotgun." That's honored.
But there's no shared rule — each sheet figured it out
independently. When a new dependent provider lands (say, a "daily
target progress" that derives from `meProvider` AND
`activeGoalProvider`), the invalidation lists have to be updated
in N places.

**Recommendation.** Architect's call — *don't* introduce a giant
"after-save bus." But add a comment block to each repository's
mutator (`LogRepository.create`/`.update`, `WeightRepository.create`,
etc.) that names the providers that depend on its data. Call sites
read the comment and invalidate accordingly. The repository owns
the dependency declaration; the call site owns the actual
invalidation. This is documentation, not code, and it's the
cheapest insurance against drift.

### Pattern D — Sheet anatomy: every sheet writes its own header, footer, close button

`LogEntrySheet`, `LogWeightSheet`, the profile editors, the goal
editors — each writes its own header row (title + close `x` +
optional eyebrow), its own footer (save button + cancel + state
spinner), its own close-button anatomy. QL-012 names the close
button specifically; there's a broader refactor where a
`SheetScaffold` widget owns the chrome and each sheet supplies
just the body + the save handler. Architect's discretion; this
is the kind of refactor that pays off after the fifth sheet, not
before.

---

## 5. Punt list

Items explicitly deferred. One-liner each.

- **Real auth (Google / Apple / email magic link).** PM Risk 2; the
  identity Edit cut in QL-007 is the placeholder until auth lands.
- **Dark mode.** PM Risk 5.
- **Real barcode camera on web.** PM ruling §10 item 3; paste-the-
  digits is the v1 affordance.
- **Energy units (kcal ↔ kJ).** Deferred to v2; the user has not
  asked.
- **Trends tab.** PM Risk 3.
- **Edit a log entry's `food_id`.** The OpenAPI forbids it; the
  sheet remains read-only on the food header.
- **Decimal feet / fractional inches** in the height composite.
  Same shape as decimal-stones rejection.
- **Profile single-page editor screen.** Per-field modals on
  compact / inline edits on expanded was the §10 item 7 ruling.
- **An "after-save event bus."** Pattern C punts the bus; the
  comment-on-repository-mutator rule replaces it.
- **A "favorite this food" feature.** QL-006 cuts the bookmark
  affordance for v1; favorites are a v1.1 ticket.
- **A "log multiple foods at once" flow.** Considered, deferred.
  The current "search → tap → log → land on Today" flow is fast
  enough; bulk-log is an optimization for after we have data on
  what users actually do.
- **A "skip onboarding" affordance.** QL-014 names the rejection;
  no skip until real auth makes "I already have an account" land.
- **Background sync on iOS / Android.** v1 only flushes the outbox
  on `AppLifecycleState.resumed`; PM Risk 6 already excluded
  background tasks.
- **CSV / PDF data export.** QL-007 cuts the row entirely.
- **Mid-flow undo for log-entry save** (e.g. a 4-second SnackBar
  undo). Considered; the existing "tap to edit" + "long-press to
  delete" affordances cover the recovery story without adding a
  global undo concept.
- **Multi-user / family accounts.** Out of v1 scope.
- **A "log this same food again" affordance from Today.** The
  food-row tap-to-edit already opens the sheet pre-seeded; the
  user can change quantity to log a re-eat. A "duplicate row"
  affordance is a v1.1 if it shows up in usage data.
- **Adding `weight_unit` for goal *rate* (kg/week vs lb/week).**
  Already punted in `pm_log_edit_and_units.md` §6. Same call here.

---

## 6. Acceptance for the entire pack

"The QoL pack is shipped" means:

- QL-001 (height units) lands end-to-end: backend migration → wire
  → seam → onboarding chooser → profile chooser → all height
  renderers.
- QL-002 (log-save returns home) lands and is regression-tested for
  the four sheet-save paths.
- The other QL items either land or are explicitly converted to
  v1.1 dev tickets with an architect note.
- Pattern A (post-mutation nav rule) is named in
  `flutter_ui_architecture.md` §9. The screen briefs each state
  which case applies.
- Pattern B (unit-preference seam) is generalized in
  `lib/providers/user_preferences.dart` (or the architect's chosen
  shape) and QL-001 consumes it from day one.
- Pattern C (invalidation declaration) lands as comment-block
  documentation on each repository mutator.
- Pattern D (sheet anatomy) is **not** required to land — flagged
  for v1.1 only. Don't block on it.
- The `dev_tickets_qol_audit.md` file (architect to write) names
  one ticket per QL-NNN with the file-list / acceptance criteria
  mapped from this doc.
- Verification commands:
  - `flutter test test/features/log_entry/*` — log-save-routes-home
    tests pass.
  - `flutter test test/domain/units/length_test.dart` — height
    formatter + parser tests pass.
  - Manual: walk the four sheet-save flows from QL-002 and confirm
    the user lands on Today.
  - `grep -rn 'CircularProgressIndicator' lib/ widgets/` returns
    zero hits (or only ones inside `Skeleton.dart` as documentation).
  - `grep -rn 'Coming soon' lib/` returns zero hits.

The user named the bar: "do the hard work to do correct refactors
when possible." That means QL-004 (unify the unit-preference seam)
lands *before* QL-001's client work; QL-003 (post-save nav rule)
lands *with* QL-002, not after. Two refactors, two user-facing
features, ~14 papercut fixes — the codebase is structurally cleaner
when this lands, not just visually nicer.

---

## 7. Sequencing recommendation

1. **QL-002 + QL-003** (log-save returns home + nav rule). Ships
   together; QL-003 is the rule that QL-002 instantiates.
2. **QL-004** (unify unit-preference seam). Refactor that QL-001
   depends on.
3. **QL-001 backend** (height unit migration). User signs off on
   wire change.
4. **QL-001 client.** Mirrors the weight pack architecturally.
5. **QL-005 through QL-018** — pull in priority order; the P1 items
   first (QL-005, QL-006, QL-007, QL-008, QL-011, QL-012), then the
   P2 items (QL-009, QL-010, QL-013, QL-014, QL-015, QL-016, QL-017,
   QL-018). Many P1s are single-line PRs; an agent should batch
   them.

The first three items are the "hard work to do correct refactors";
the rest are individual papercuts that compose. The pack as a whole
is sized for one architect-week of plumbing followed by one or two
agent-weeks of mechanical sweep.
