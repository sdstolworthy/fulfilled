# PM Decisions: Flutter UI Architecture v1

PM rulings on the open questions and flagged risks raised by the frontend
architect in `specs/flutter_ui_architecture.md` section 10. These decisions
are binding for v1 — downstream developer agents should treat this doc as
the tiebreaker against the architecture doc and the mocks. Where this doc
contradicts either, this doc wins, and the architecture doc should be
amended in the same change that ships the implementation.

## Context

The two user stories driving v1 are still the lens for every call here:

- **Desktop/web at work.** A user sits down at a browser, opens
  Fulfilled, sees today's progress, and logs what they ate at lunch.
  Keyboard is on the table, network is reliable, the session lasts as
  long as the workday.
- **Mobile on the go.** A user pulls out their phone in line at a
  burrito shop, scans a barcode or types a quick search, and adds an
  entry to today's log in under ten seconds. Network is whatever
  cellular happens to be doing that moment.

Most of the calls below collapse to: do not ship half-working UI, do not
let unit ambiguity reach the user's eyes, and do not let pretty mock
elements set product scope they can't pay for.

---

## Display Units Principle

**The client always renders quantities in the unit the user most expects
to see for that quantity, regardless of how the wire schema stores it.**
The wire is allowed to be "scientifically tidy" (SI, OFF conventions,
per-100 g panels); the screen is not. If a customer would read a
nutrition label in milligrams, we show milligrams. If they'd read it in
pounds, we show pounds. The customer never has to mentally multiply or
convert.

### Where the conversion happens

**Client-side, in the repository layer.** The wire schema (`openapi.yaml`)
stays in canonical units — grams for mass, kg for body weight, kcal for
energy — and the Flutter client converts at the seam between the
generated DTO and the presentation model. A single conversion utility
lives at `lib/domain/units/` and is the only place these constants
appear.

This is the right call for three reasons:

1. **The backend is one shape; the clients are many.** Burdening the
   API with locale-aware display units pushes presentation concerns into
   the wire contract, then forces every future client (a hypothetical
   Apple Watch app, a CLI, a partner integration) to either consume our
   opinion or re-undo it. Canonical units on the wire keep the surface
   composable.
2. **Round-tripping is safer.** The OpenAPI doc already calls out that
   decimals shouldn't be floated. Keeping the wire in canonical SI means
   the client never sends a converted-and-back number to the server —
   the only conversions are display-only, applied on the final
   `Text` widget.
3. **It's a small, well-defined utility.** A few `Decimal` conversion
   helpers and a per-quantity formatter — cheaper than reshaping the
   API.

Trade-off acknowledged: the Flutter client now owns a small "units"
domain (formatters, locale-aware unit selection, conversion math). The
architecture doc already names `lib/domain/decimal_format.dart`; this is
its natural neighbor. **Architect: add `lib/domain/units/` to the
directory layout in section 10's appendix** and treat it as
non-negotiable as `decimal_format.dart`.

### Per-quantity rulings

| Quantity            | Stored as (wire)        | Displayed as (v1)            | Conversion factor              |
|---------------------|-------------------------|------------------------------|--------------------------------|
| Energy              | `kcal` (Decimal)        | `kcal` everywhere            | None (display canonical)       |
| Macros (P/C/F/fiber/sugar/sat. fat) | `g` (Decimal) | `g` everywhere               | None (display canonical)       |
| **Sodium**          | `g` per-100 g; `mg` on log | **`mg` everywhere on screen** | × 1000 from `g`               |
| Body weight         | `kg` (Decimal)          | **kg-only in v1**, profile pref in v2 | × 2.2046226 to `lb`     |
| Height              | `cm` (Decimal)          | **cm-only in v1**, profile pref in v2 | cm → ft/in for v2       |
| Per-100 g panel basis | `100 g`               | `per 100 g` label preserved  | None — see below               |
| Date                | `YYYY-MM-DD`            | `EEEE, MMM d` in user locale | None                           |

**Energy (kcal).** Keep kcal-only for v1. The mocks show `kcal`, the
backend stores `kcal`, both target markets (US/UK primarily, with EU/AU
secondary) recognize kcal on labels — and AU/EU labels carry kJ
alongside kcal rather than instead of it. Adding a profile preference
for `kJ` is a v2 risk only if data shows non-US/UK users complain;
flagging it is sufficient for v1.

**Sodium.** Stored as `g` per-100 g (OFF convention) and as `mg` on
`LogEntry` — already inconsistent in the wire. The directive applies
verbatim: **customers expect mg.** The client converts the per-100 g
`sodium_g` to mg at the repository boundary; downstream presentation
code only ever sees mg. The architect's note 8 already documented the
conversion at the repository — this decision confirms it and adds:

- **Do not change the OpenAPI shape.** The `NutritionPer100g.sodium_g`
  field stays in grams; the `LogEntry.sodium_mg` field stays in mg.
  Aligning them backend-side is a refactor we will get to in a separate
  ticket if and when it becomes painful — for v1 the client absorbs it.
  Rationale: the OFF source data is grams, the wire mirrors it, and we
  don't want a backend conversion bug to taint the canonical numbers.
- **The presentation model only carries `sodium_mg`.** No mixed-unit
  fields in client code. The repository converts on the way in.
- **Add an OpenAPI clarification.** The `sodium_g` description should
  explicitly say "clients should multiply by 1000 to display as
  milligrams, which is the customer-expected unit." This is a one-line
  spec edit, not a wire change.

**Body weight.** This is the locale-sensitive one. v1 ships **kg-only**
across the entire client (weight log, onboarding step 2 weight input,
goal start/target weight, weight summary card, sparkline axis labels).
We do not ship `lb` in v1. Rationale: a real unit preference requires
(a) a `User.weight_unit` field, (b) onboarding prompting for it, (c) a
profile setting to flip it, and (d) careful handling of in-flight
goals/weights that were entered under the old preference. That is more
surface than v1 can absorb cleanly, and shipping lb-only would alienate
the half of the user base outside the US.

- **v2 risk.** Without `lb`, the US user has to convert mentally. This
  is a known shortcoming; the architect should add a comment in
  `weight_repository.dart` noting the v2 follow-up.
- **Onboarding hedge.** Step 2 weight entry must label the field "Weight
  (kg)" explicitly — no ambiguous "Weight" label. Same in the weight
  log dialog.
- **Follow-up ticket.** Open a v2 ticket: "Add `weight_unit` (`kg|lb`)
  to `User`, expose in profile, gate display in `units` utility on
  preference." Owner: backend (schema) + frontend (UI). Not v1.

**Height.** Same call as weight, same reasoning, same v2 ticket — ship
`cm` only in v1, label the onboarding field "Height (cm)". The
mock-implied "ft/in" never materializes in v1.

**Macros (protein / carbs / fat / fiber / sugar / saturated fat).**
Grams everywhere. This matches the wire, matches every nutrition label
on the planet, and matches the mock. No conversion needed. The
`MacroBar`, `MacroChip`, `NutritionTable`, and `LogPreviewBlock` all
render `"33 g"`, never `"0.033 kg"` or `"33000 mg"`.

**Per-100 g panel basis.** The nutrition panel on screen 03 must stay
**"per 100 g"**, not "per serving" or "per default serving". Rationale:
the OFF and USDA data is per-100 g, the European and many international
labels are per-100 g, and showing "per 100 g" on a panel of macro values
matches what a customer recognizes from packaging. The per-serving math
already happens elsewhere — `FoodSummaryCard` shows per-default-serving
kcal, the `LogPreviewBlock` shows per-quantity nutrition. Don't conflate
the two surfaces. **The panel header explicitly reads `Per 100 g`.**

### Implementation impact (Display Units Principle)

- **No OpenAPI wire-shape change.** Sodium remains split (g per-100 g,
  mg per LogEntry). Add a clarifying sentence to
  `NutritionPer100g.sodium_g` description noting the
  display-in-milligrams expectation.
- **New utility directory.** Architect: add `lib/domain/units/` to the
  section-10 appendix. Contains:
  - `mass.dart` — `gramsToMilligrams`, `kgToLb`, formatters that take a
    `Decimal` and return a `String`.
  - `energy.dart` — kcal formatter (and a stub for v2 kJ).
  - `length.dart` — cm helper (and a stub for v2 ft/in).
- **Repository conversion of sodium.** `food_repository.dart` converts
  `NutritionPer100g.sodium_g` to `sodiumMg` on the presentation model.
  `log_repository.dart` passes `sodium_mg` through unchanged. The
  presentation model only ever exposes `sodiumMg`.
- **Token consistency.** Macro bars, chips, and the per-100 g panel
  render labels via `NumberText(value: …, unit: 'g' | 'mg' | 'kcal' |
  'kg')`. Architect: add a `unit` prop to `NumberText` in the section-3
  component inventory if it isn't already there — every numeric leaf
  should know what unit it's rendering so a11y labels can include it
  ("130 kilocalories", "33 grams of protein"), satisfying T-20.
- **v2 tickets to open** (not v1 work):
  1. Add `weight_unit` and `height_unit` (or a single locale preference
     that drives both) to `User`. Backend + frontend.
  2. Locale-aware energy display (kcal/kJ).

---

## Risk 1 — Over-budget macro threshold

### Decision

Macro bars flip to `AppColors.danger` at exactly `value > target` (i.e.
the moment the user crosses the goal, no tolerance).

### Rationale

The user story is "see progress" — including over-progress. A 5%
buffer would mean a 200 g protein goal stays "green" until 210 g, which
quietly lies to the user about whether they're inside their plan. The
designer already called this out as the intended behavior; the
architect's concern about visual jitter is real but the fix is to make
the flip stable, not to introduce a fudge factor. We treat the goal as
the goal.

Jitter from a "1 g over at midnight" case is mitigated by two existing
choices: tabular figures (T-02) keep numbers from reflowing, and the
bar's fill is a continuous interpolation — at 100.5% the bar is
visually indistinguishable from 100%, only the color changes. That's
the right feedback.

### Implementation impact

- **T-05 stays as-written** in `specs/flutter_ui_architecture.md`.
  Architect: edit T-05 to add "the threshold is exactly `value >
  target`; no tolerance" so the rule is unambiguous in code review.
- **`MacroBar` and `CalorieRing` widgets** must use a strict `>`, not
  `>=`. Exactly-at-target stays "on track" (`AppColors.accent`).
- **Accessibility:** the rendered semantic label appends ` ("over by
  N g")` whenever in the over state — per T-20, color must not be the
  sole signal.

### Open follow-ups

None.

---

## Risk 2 — "I already have an account" link on onboarding step 1

### Decision

**Remove the link entirely for v1.** Replace with a single primary CTA
(`Get started`). Add it back when auth lands.

### Rationale

V1 runs against `DEV_AUTH_BYPASS` — there is literally no account to
"already have." Shipping a link that goes nowhere, or to a "Coming
soon" affordance, is worse than not shipping it. Either choice
implies an authentication story we haven't built and creates a support
question on day one ("I clicked the link and nothing happened"). The
hypothetical user the link serves doesn't exist yet; the user who hits
onboarding cold does.

We are not shipping a half-built auth flow. The link is real product
scope and it gets real product scope or it gets cut.

### Implementation impact

- **Mock update.** Step 1 of screen 09 loses the secondary text link.
  The architect's section 9 brief for screen 09 already mentions it —
  delete that mention. Designer: re-render the mock without the link
  for cleanliness, but the developer agent can ship without waiting on
  the asset; the architecture doc is authoritative.
- **`OnboardingStepShell`** keeps its single-CTA shape. No "secondary
  link" slot in the v1 widget.
- **`specs/flutter_ui_architecture.md`** section 10 note 12 is
  resolved by this decision — replace with a one-line "removed for v1,
  add back when auth ships" footnote, and strike the open question.

### Open follow-ups

- **v2 ticket.** "Implement authentication (provider TBD: Google /
  Apple / email magic link), then restore the 'I already have an
  account' link on onboarding step 1." Owner: TBD when auth is
  scoped.

---

## Risk 3 — Trends tab

### Decision

**Hide the Trends slot entirely in v1.** No greyed-out tab, no stub
screen, no redirect — the nav simply does not include it on mobile or
desktop.

### Rationale

A greyed slot is a promise we haven't budgeted to keep. Users will tap
it, get nothing, and form an opinion about the app's polish. A stub
screen is worse — it implies we have analytics surfaces and then
disappoints. The architecture's current "redirect to `/weight`" is
clever but creates a navigation lie: the URL says `/trends`, the
sidebar highlights Trends, but the user is looking at the Weight page.
That's confusing on web where URLs are visible.

The mobile and desktop user stories don't require Trends. Today's view
and Weight together cover the v1 "see progress" promise. Trends ships
when there's a designed screen for it.

The four-tab mobile bottom bar becomes Today / Foods / Weight / Me —
which is a more honest reading of what v1 actually does (log food, see
today, track weight, manage account). The desktop sidebar becomes
Today / Foods / Weight / Goals / My foods.

### Implementation impact

- **`specs/flutter_ui_architecture.md` section 4** ("Navigation &
  routing") — remove the `trends` route entirely. Update the route
  table; update the "Shell structure" description; update the prose
  paragraph after the diagram (currently lists "Trends (disabled
  stub)").
- **No `BarcodeScanButton`-style `SizedBox.shrink()` workaround.** The
  nav config simply omits the tab.
- **Mobile bottom tabs** are now four-up: Today / Foods / Weight / Me.
- **Desktop sidebar** is five-up: Today / Foods / Weight / Goals / My
  foods.
- **Designer:** the mocks show Trends in both the bottom bar and
  sidebar. Re-render is nice-to-have but not blocking; the architect's
  doc is the implementation contract.

### Open follow-ups

- **v2 ticket.** "Design and ship Trends." Owner: design first, then
  product, then engineering. Out of v1.

---

## Risk 4 — Sodium and other display units

See the **Display Units Principle** top-level section above. The summary:

### Decision

Adopt the Display Units Principle. Sodium is displayed in `mg`
everywhere on screen, derived from the wire's split (`g` per-100 g and
`mg` per-LogEntry) at the client repository layer. Other quantities are
ruled per-row in the table above; the headline v1 rulings are:
energy in `kcal`, macros in `g`, body weight in `kg`-only (lb deferred
to v2), the per-100 g panel keeps its `per 100 g` basis.

### Rationale

See the principle section. One sentence: the customer never converts in
their head, and the wire never carries a presentation concern it
shouldn't.

### Implementation impact

See the principle section's "Implementation impact" subsection. Net:

- **OpenAPI:** one descriptive sentence added to
  `NutritionPer100g.sodium_g`. No wire shape change.
- **Client:** new `lib/domain/units/` directory; `food_repository`
  converts sodium; `NumberText` learns a `unit` prop.
- **v2 tickets:** weight/height unit preference, kJ option.

### Open follow-ups

- **Architect:** amend section 10's appendix to add `lib/domain/units/`
  to the directory layout.
- **Architect:** amend section 5 ("State management") to note that the
  presentation model converts sodium from `g` to `mg`, so screens
  consume `sodiumMg` exclusively.
- **Designer:** confirm `Per 100 g` label copy on screen 03's nutrition
  table (it is already implied; just make sure no future iteration
  drops the label).

---

## Risk 5 — Profile "Appearance" toggle

### Decision

**Hide the Appearance row in v1.** Do not ship a non-functional toggle,
do not "default to System and call it done." The row is removed from
screen 08 until dark mode actually ships.

### Rationale

A toggle that doesn't do anything is the most common bug-report
generator in a settings screen. Either it sets a value and the app
respects it, or it shouldn't exist. Dark mode is explicitly out of v1
scope (section 2.1 of the architecture doc). The token layer is
already structured to allow a dark theme later via `ThemeExtension`,
so hiding the row costs us nothing future-wise.

"Hide in release builds, show in debug" was considered and rejected:
developer agents and QA still need a consistent profile screen, and
having a build-flag-gated row creates a category of "works in debug,
broken in release" reports.

### Rationale (continued)

Note that the architecture doc section 9, screen 08 gotcha already
flags this dilemma. We resolve it: hide.

### Implementation impact

- **`specs/flutter_ui_architecture.md` section 2.1** — strike the
  "wire to a no-op or hide" sentence and replace with "the Appearance
  row is hidden in v1; the `ThemeExtension` token plumbing remains so
  dark mode is a swap when it ships."
- **`specs/flutter_ui_architecture.md` section 9 screen 08 gotcha** —
  resolve it: "hide the Appearance row in v1."
- **`SettingsCard` for the Preferences section** simply omits the
  Appearance row.
- **Designer:** mock update nice-to-have, not blocking.

### Open follow-ups

- **v2 ticket.** "Ship dark theme: design a dark-mode token sweep,
  wire `AppColors` dark variant, restore Appearance row." Owner:
  design first.

---

## Risk 6 — Offline log creation

### Decision

**Override the architecture's "no queue" stance for the mobile log-food
flow.** v1 ships a **minimal local outbox** for `POST /log` on mobile
only. Web continues to surface the error directly. The outbox holds
log entries while offline and flushes on reconnect; it is a single-table
on-device queue with no merge logic and no UI beyond a status indicator.

### Rationale

The mobile user story is "pulling out my phone on the go." Real users
in real lines at real burrito shops have flaky cellular. Telling them
"sorry, save again" *while the sheet is open with their input intact*
sounds fine in an architecture doc and is genuinely awful in practice
— they close the sheet by reflex, lose the entry, and stop using the
app on cellular. This is the exact failure mode every calorie tracker
gets reviewed for on the App Store.

The architecture's reasoning ("users want to know") is correct in
spirit but wrong in shape: users want to know **that it'll get logged**,
not that it failed. A subtle "Will sync when online" toast plus a small
sync-pending indicator gives them that confidence without lying.

We scope the outbox aggressively to keep it from blowing up:

- **`POST /log` only.** Not weights, not goals, not food creation, not
  edits, not deletes. Just "I ate this." That's the on-the-go path.
- **Mobile only.** Web keeps the architecture's "surface the error"
  behavior. If someone's at their desk and the internet is out, they
  have bigger problems than logging a yogurt.
- **No conflict resolution.** Each queued POST is replayed verbatim
  on reconnect. If it fails server-side (404 food, 400 validation),
  the entry is moved to a "sync failed" state and the user sees an
  inline error on the offending row in the day view. We do not silently
  drop. We do not retry indefinitely on 4xx — three attempts, then
  surface.
- **Optimistic insert in the day view.** The architecture already does
  optimistic updates for `POST /log` (section 5, "Optimistic
  updates"). The outbox is the natural extension: optimistic inserts
  show with a small "pending" badge until the POST succeeds.
- **No background sync.** The queue flushes on `AppLifecycleState.resumed`
  and on the next user-initiated action that requires network. v1 does
  not run iOS background tasks (architecture section 6 already commits
  to this); we don't change that.

This is more scope than the architect proposed, but the user story
demands it. We're not building a full offline-first app — we're
buying the mobile user the ten seconds of cellular dropout that
they'll definitely have.

### Implementation impact

- **`specs/flutter_ui_architecture.md` section 5** — replace the
  "Offline write queue: out of scope" line with: "Mobile-only outbox
  for `POST /log`. See PM decisions doc for scope. Other writes
  (weights, goals, food creation, edits, deletes) remain online-only
  and surface errors."
- **New repository surface.** `log_repository.dart` exposes
  `logEntryWithOutbox(...)` that writes to a Hive box first, then
  attempts the POST. The day-view provider reads from a merged view
  (server entries + pending outbox entries) so optimistic inserts work.
- **New widget state.** `FoodRow` learns a `syncStatus`
  (`synced | pending | failed`) and renders a small badge accordingly.
  Architect: add this to the section 3 component inventory.
- **New tenant.** Suggest `T-21 Mobile log writes are outbox-backed`
  to make the rule reviewable. Architect: discretion.
- **No OpenAPI change.** The wire stays as-is; this is purely a client
  concern.

### Open follow-ups

- **Architect:** spec the outbox in section 5 in enough detail that a
  developer agent can implement it (table shape in Hive, retry policy,
  conflict surfacing, optimistic provider integration). Treat as a
  follow-up architecture doc edit, not blocking on me.
- **Designer:** add a "pending sync" affordance to the `FoodRow`
  mock — a small dot or badge. Color: `AppColors.ink3`. Architect can
  define the spec without the asset; mock catches up.
- **QA scenario:** "Log three foods in airplane mode, re-enable
  network, confirm all three show up in the day total." Add to the
  v1 acceptance test plan.

---

## Summary of decisions

| # | Risk                                      | Decision                                                                 |
|---|-------------------------------------------|--------------------------------------------------------------------------|
| — | Display Units Principle                   | Client converts at repository; canonical SI on wire; customer-expected units on screen. |
| 1 | Over-budget macro threshold               | Flip at strict `value > target`; no tolerance.                           |
| 2 | "I already have an account" link          | Remove from v1; restore when auth ships.                                 |
| 3 | Trends tab                                | Hide entirely from v1 nav (no stub, no greyed slot).                     |
| 4 | Sodium / units                            | mg on screen; kg/cm-only for body; per-100 g panel preserved; v2 tickets opened for unit preferences. |
| 5 | Appearance toggle                         | Hide the row in v1; ship dark mode in v2.                                |
| 6 | Offline log creation                      | Mobile-only outbox for `POST /log`; web surfaces error as before.        |

## Documents this decision touches

- `specs/flutter_ui_architecture.md` — multiple amendments per decision
  (T-05 text, section 2.1 Appearance text, section 4 nav table, section
  5 offline write queue, section 9 screen 08 gotcha and screen 09
  step-1 description, section 10 open questions list, appendix
  directory layout for `lib/domain/units/`).
- `specs/openapi.yaml` — one descriptive-only edit to
  `NutritionPer100g.sodium_g` clarifying the mg display convention.
  No wire-shape change.
- New v2 tickets (no v1 implementation work): auth, dark mode, Trends,
  weight/height unit preferences, energy kJ option.
