# PM UX Pack: From Scaffolding to Daily Ritual

The UX specialist's review (`specs/ux_review.md`) lands the framing this
pack treats as the design brief: *"the scaffolding is done; the
experience-shaped work hasn't started."* The previous PM passes
(`pm_qol_audit.md`, `pm_log_edit_and_units.md`) cleared the
papercut-and-correctness layer; navigation rule T-24 plus the weight-unit
sweep plus the QL-001..QL-018 cleanup put the floor under the app. What
the review is naming is one tier above that — the gap between *"every
screen renders"* and *"the user reaches for the app on day 14."* The
user authorised the entire review for the pipeline; this doc is the PM
filter that turns that authorisation into work the architect can plan
against. We sequence, we refine, we push back where the review's call
needs a constraint applied, and we name where the architect should
land first.

`specs/ux_review.md`, `specs/pm_decisions_flutter_ui.md` (Display Units
Principle, the six PM Risks), `specs/flutter_ui_architecture.md` (T-01
through T-24, the per-screen §9 briefs), `specs/openapi.yaml` (the
`POST /log/copy` shape), and `specs/audit_followup_pm.md` (the still-open
`/foods/mine` sort question) are the tiebreakers above this doc. Where
this doc decides something contradicting a screen brief, the architect's
implementation plan is the place that resolves it — usually by amending
the screen brief's `Post-save:` or `Compose:` line, not by re-litigating
the rule here.

Reading order:

- `specs/ux_review.md` — the input. §1 + §7 + §3 are the ten-minute
  read.
- `specs/pm_qol_audit.md` — closest analog for prose style and the
  P0/P1/P2 grading discipline.
- `specs/flutter_ui_architecture.md` §8 (tenants) and §9 (per-screen) —
  the constraints any of these items inherits.
- `specs/openapi.yaml` lines 668–698 + 1109–1127 — the `POST /log/copy`
  contract that F1 lights up.

---

## 1. Context

The user, after reading the UX review end to end, said "run everything
through the pipeline." That's a mandate, not an instruction; it converts
the review from a memo into a backlog. PM's job here is to *sequence*
the mandate against the constraints we've already paid for —
post-mutation navigation rule T-24, the outbox, the Display Units
Principle, the empty-day pill, the existing anti-recommendations on
coachmarks / stub Trends / merged sheets — and to push back where the
reviewer's instinct compresses against a constraint we've deliberately
set. The framing for the architect is the reviewer's own phrase: the
Day-1 experience is solid, the Day-14 experience is identical to Day-1,
and the work in this pack is **closing that delta** without inventing
scope the app can't carry. Three of the top five items (F1, F2, the
header re-anchor) are about *making the daily ritual cheaper*; the
remaining two (F4/F5, F10) are about *making the day-over-day signal
visible*. That's the pack: cheaper ritual + visible signal. Everything
else is supporting cleanup.

---

## 2. The five highest-impact items (deep dives)

### F1 — Copy yesterday's meal

**User stories.**

- As a user who eats the same breakfast most weekdays, I tap a single
  affordance on today's Breakfast section and yesterday's Breakfast
  appears under today's Breakfast, with the kcal/macros recomputed
  against the current food state — so my Tuesday log of the same oatmeal
  takes two taps, not seven.
- As a user who missed logging yesterday entirely, I copy *the whole
  day* from the day before in one operation, then edit the few rows
  that differ, so reconstructing a missed log isn't a re-search exercise.

**Decision summary.** Ship **two affordances, one sheet, one wire call**.
Per-meal copy is the headline feature and lives as a **meal-section
overflow item** (the existing meal header's right-edge affordance — same
location the reviewer flagged for long-press). The label is **"Copy
from yesterday"** when yesterday has entries in that meal; **"Copy
from…"** (opens a date+meal picker) when yesterday's meal is empty or
the user wants a different source. Whole-day copy lives at the **bottom
of the day view** as a quiet `OutlinedButton`-shaped row labeled **"Copy
from another day"** — only renders when the *current* day is empty
(otherwise the per-meal affordance is the right scope; we don't want a
"copy day" button hovering over a half-populated day, that would imply
"replace" semantics). Both paths land in a single `CopyDaySheet` widget;
the only difference is the meal filter is pre-set on the per-meal path
and absent on the whole-day path. Per the OpenAPI (line 685–687), the
response is wrapped (`{ copied: [...] }`) and the server **already
recomputes nutrition snapshots from the *current* food state** — so the
client never sends today's snapshots, never duplicates the math, and a
custom food edited between yesterday and today is reflected in the copy
verbatim. We trust the wire.

The failure UX is `T-11`-shaped: a SnackBar on top of the sheet (sheet
stays open, input intact), retry affordance on the SnackBar action. The
specific failure cases worth thinking about: `400` for `from_date > to_date`
with a backward copy (the wire allows it, see line 681–682 — so this is
unlikely), `401` for auth-expired, and a partial-skip case where the
response includes fewer entries than yesterday's meal had. The spec
explicitly notes that **entries whose food is no longer visible or
whose serving was deleted are silently skipped** (line 679–681); we
surface that as an inline `SnackBar`: *"Copied 3 of 4 — 1 entry skipped
(food no longer available)."* No second sheet, no error dialog. The
user already got most of what they asked for.

**Backend implication.** None. `POST /log/copy` is already shipped per
OpenAPI lines 668–698 with `CopyDayBody { from_date, to_date, meal? }`
and `CopyDayResponse { copied: LogEntry[] }`. Server-side snapshot
recomputation against current food state is documented at lines
673–678. The architect should verify the Rust route is wired (it
should be — the OpenAPI commit is upstream of this pack) but the wire
shape is fixed and this pack does not request a change.

**Acceptance criteria.**

- A new `CopyDaySheet` widget in `lib/features/today/widgets/` exposes
  three fields: source date (defaults to yesterday), source meal
  (defaults to the meal the user opened the sheet from, or "All meals"
  if invoked from the whole-day affordance), and destination date
  (always the current day-view's date — read-only display, not an input).
- Each `MealSection` header gains an overflow icon (existing
  `IconButton36` token, T-06 compliant) whose menu includes "Copy from
  yesterday" as the first item. Tap → open `CopyDaySheet` with the
  source meal + source date pre-set; the user taps Save to commit. Only
  enabled when there's *any* prior day with logged entries in this meal
  in the last 14 days (cheap client-side check against
  `recentFoodsProvider` data or a small new "any-entries-by-meal-window"
  provider — architect's call).
- Empty-day path: when *every* meal section is empty AND the date is
  today, render a `_CopyFromDayRow` between the existing empty-day pill
  and the meal sections — `"Copy from another day"` text +
  `chevron_right`. Tap → open `CopyDaySheet` with no meal filter
  (whole-day copy).
- On successful copy, invalidate `daySummaryProvider`,
  `logEntriesProvider`, and `recentFoodsProvider`. The optimistic
  insert path is **not** required for v1 — copy-meal goes online-only,
  shows a `_SaveButtonSkeleton` while the request is in flight, and the
  user lands back on Today with the new entries already visible after
  the response settles. The outbox does **not** queue `/log/copy`
  requests (the outbox is scoped to single-entry `POST /log` per Risk
  6; copy is a multi-entry op and queueing it correctly is more
  complexity than the daily-ritual win demands).
- Failure: SnackBar with retry; sheet stays open. Partial-skip:
  SnackBar reports `N of M copied`; sheet closes; user is on Today
  with the partial copy applied.
- Post-save navigation is **Case 1 (pop-to-source)** per T-24 — the
  source is Today, the effect lands on Today, no route change needed.
  Architect's dartdoc names the case explicitly.
- A11y: the sheet's Save button label includes the row count (`"Save —
  copy 4 entries"`). The skip case appends ` ("1 skipped")` to the
  post-save SnackBar's semantic label.

---

### F2 — Recent-foods chip row on Today (compact)

**User stories.**

- As a user who ate Greek yogurt yesterday, I see a chip labeled
  "Greek yogurt" above my meal sections on today's view, I tap it, the
  LogEntrySheet opens pre-seeded with yesterday's serving and quantity
  on the current-time-of-day meal — so re-logging is a single
  recognition + two taps, not a search round-trip.
- As a desktop user, the right-rail Quick add card already exposes
  this; I don't need a redundant compact-style row inside the meal grid.

**Decision summary.** Lift `QuickAddChips` from its current
expanded-only home (`features/today/widgets/quick_add_chips.dart`) and
expose it on **compact, above the meal sections, between the
RingSummaryCard and the first MealSection**. Render up to **six chips**
(architect's discretion to tune to 4–6 based on horizontal-scroll
performance; the absolute floor is 4). Ordering is **`recentFoodsProvider`
order** — recency, not frequency. Reasons: (a) recency mirrors what the
user just did and is the strongest signal that "this is still in your
rotation"; (b) frequency requires a window decision (last week? last
month?) we haven't paid for and that the reviewer didn't ask for; (c)
the chip row scrolls horizontally so the long tail isn't lost, just
de-emphasised. Tap behaviour is **opens `LogEntrySheet` pre-seeded** —
not one-tap-with-defaults. Reason: the reviewer explicitly framed this
as cutting taps "from 6 to 3," not "to 1," and one-tap-with-defaults
silently commits a serving/quantity the user might not want for *this*
log. The sheet open carries the previous log's serving + quantity (the
`recentFoodsProvider` row knows it) and the meal defaults to
time-of-day; the user reviews and saves. Three taps: chip → review →
Save.

The whole expanded-vs-compact picture after this change: expanded keeps
its right-rail Quick add card (no behaviour change); compact gets the
new chip strip; both consume the same `recentFoodsProvider` and route
through the same `LogEntrySheet`. T-23 (shared widgets) is honoured —
`QuickAddChips` lifts to `lib/widgets/quick_add_chips.dart` and both
breakpoints import it from there.

**Backend implication.** None. `recentFoodsProvider` already exists
and is wired against `GET /foods/recent`.

**Acceptance criteria.**

- `QuickAddChips` widget moves to `lib/widgets/quick_add_chips.dart`
  (T-23). The expanded right-rail card and the new compact strip both
  import from this canonical location.
- On compact, the strip renders between the `RingSummaryCard` and the
  first `MealSection`. Vertical rhythm matches the existing section
  spacing — no special "tight" or "loose" margin.
- The strip renders **only on today's day-view** (`date ==
  local-now`). On backdated views, it's hidden — the user explicitly
  navigated to a past date, and re-logging *yesterday's* food onto
  *another past day* is rare enough that the chip strip would be more
  noise than signal.
- Maximum chip count is 6; minimum is 4 (if fewer than 4 recents exist,
  hide the whole strip — empty-but-present chrome is worse than absent
  chrome). If the strip is hidden and the day is also empty, the
  empty-day pill is the only nudge above the meal sections — that's
  fine.
- Tap a chip → opens `LogEntrySheet` pre-seeded with: the food, the
  food's default serving (or the serving used in the most recent log
  of this food — architect's pick; recency is correct), quantity from
  the most recent log of this food (the `recentFoodsProvider` row
  carries this), and meal = time-of-day default.
- The sheet's "Save" → standard T-24 Case 2 routing to
  `/today/:consumedOn` (already shipped via QL-105).
- A11y: each chip has a Semantics label combining food name + last-log
  context (`"Greek yogurt, last logged Tuesday, 130 kilocalories"`).
  T-20 honoured.
- Per Theme A (header compression), the chip strip lives **below** the
  ring, not above it — the ring remains the screen's first focal
  element. The strip is a secondary affordance, not a primary one.

---

### F4 + F5 — Weight chart scrub-to-read & Log Weight pre-fill

**User stories.**

- As a user who weighs in most mornings, I open the Log Weight sheet
  and the stepper is pre-filled with my last entered weight, so I
  nudge by 0.6 lb instead of typing 141.2 from scratch.
- As a user reviewing my sparkline, I drag my finger along the line
  (or hover on web) and a tooltip near my finger shows the exact date
  + weight at that point, so the chart is something I can read, not
  just a vibe.

**Decision summary.** Two related-but-separable items. We ship them
together because they share the same `WeightSparkline` + `LogWeightSheet`
seam and the same provider (`weightHistoryProvider`).

**F5 (pre-fill).** `LogWeightSheet`'s initial seed becomes a fall-through:
`weightHistoryProvider.first.weightKg` if any history exists, else
`user.currentWeightKg` (the seeded onboarding value) if that's set,
else the existing default seed. The unit follows `user.weightUnit` per
the Display Units Principle and T-21 — the stepper renders in lb / st /
kg per preference, the canonical kg goes to the wire. This is a
**single-line behavior change** in `LogWeightSheet`'s constructor; the
test surface is "open the sheet against a non-empty history, assert
the stepper's initial value equals the most recent weight (in display
unit)."

**F4 (scrub).** On compact, the gesture is **drag** (`onHorizontalDrag*`)
not long-press — the reviewer called it long-press OR drag; drag is
the lower-friction option and matches the iOS Health / Strava
convention. The drag begins on first touch (no long-press delay), the
chart shows a vertical guideline at the touch X-coordinate, and a
tooltip floats above the line with date + weight. On web, the gesture
is **hover** (`MouseRegion` over the chart area). On release / pointer
exit, the guideline + tooltip fade away over `motion('chart.scrub.out')`
(architect: pick a 120ms standard from the motion tokens). The
readout shape is two lines stacked: top = date in `EEE, MMM d` format
(short weekday + month abbreviation + day, matching the rest of the
app's date format), bottom = weight in the user's display unit with
the tabular-figures rendering (T-02). Tooltip background is
`AppColors.ink` with white text — high contrast, no semitransparent
overlay over chart strokes (which would be unreadable on the dashed
moving-average line).

Implementation seam: this lives inside the existing `WeightSparkline`
CustomPainter (T-19 — no new chart package). The hit-testing is a
linear search through the painted points for the nearest x — at the
~30-point cap a binary search is overkill and the linear pass costs
nothing. Architect: the gesture is a `RawGestureDetector` wrapped
around the painter, not a `GestureDetector` (which would conflict with
the parent `ListView`'s vertical scroll on compact — vertical drag
must still scroll the page, only horizontal drags scrub the chart).

**Backend implication.** None. Both items consume providers we already
have.

**Acceptance criteria.**

- F5: `LogWeightSheet` constructor accepts an optional `Decimal?
  initialWeightKg`. The call site (the FAB's `onPressed`) reads
  `weightHistoryProvider.firstOrNull?.weightKg ?? user.currentWeightKg`
  and passes it. Sheet's `WeightStepper` initial state honours it.
  Format respects `user.weightUnit` per T-21.
- F4 (compact): drag horizontally on the sparkline → vertical
  guideline at touch X + floating tooltip above. Tooltip shows
  `EEE, MMM d` + `formatWeight(value, unit)`. Drag end → guideline +
  tooltip fade out over the standard motion duration.
- F4 (expanded): hover over the chart → same guideline + tooltip.
  `MouseRegion` exit → fade out.
- The vertical drag gesture inside the chart **does not block** the
  parent `ListView`'s vertical scroll (T-12 spirit — gestures don't
  hijack their parent inappropriately). Confirmed by a test that
  drags vertically over the chart and asserts the `ScrollController`
  offset changes.
- A11y: the chart's `Semantics(value: ...)` is a brief "Weight trend
  over $range, ranging $low to $high in $unit, $deltaSign $delta over
  the period" — same shape as the existing label, no change needed.
  The scrub gesture is a sighted-user affordance; screen-reader users
  consume the history list immediately below.
- The chart's empty-state (zero points) is unchanged — no scrubbing on
  an empty chart.

---

### Today compact header compression (Theme A)

**User story.** As a user opening Today on my phone, the calorie ring
appears within the first 80px of viewport — it's what I came to see,
not a toolbar of six icons.

**Decision summary.** Of the six concurrent affordances the reviewer
named, we **cut one, merge one, move one, and keep three**. Specifically:

- **Avatar — CUT.** It's a placeholder until auth (PM Risk 2). Profile
  is one tap away on the bottom tab bar. Carrying a placeholder avatar
  in the top-left of the most-viewed screen is the same anti-pattern
  QL-006 / QL-007 cut for the bookmark and the export row. The
  reviewer suggested cutting it; we agree.
- **Bolt (quick-add) — MOVE.** Move it into the FAB's secondary slot
  via **long-press FAB → two-up menu (Log food / Quick add kcal)**.
  This is the reviewer's recommended fix and it matches T-12 (the FAB
  is the only floating action — a long-press on the FAB exposing a
  second action stays inside the rule). The bolt icon disappears from
  the top bar.
- **Search — KEEP.** Search is the primary discovery affordance and
  cutting it would push the search-route discovery into the bottom
  tab bar (which doesn't have a Search tab and shouldn't grow one).
  Keep the icon, top-right where it is today.
- **TodayPill — KEEP.** On backdated views it's a high-value affordance
  (QL-009 was specifically about this). It only renders when `date !=
  today` so its visual weight on the canonical view is zero.
- **Date chevron pair — MERGE.** Collapse `chevron_left` + date title +
  `chevron_right` into a **single tappable date title** that opens
  `showDatePicker` with `firstDate = today - 1 year, lastDate = today`.
  The chevrons disappear in their current always-visible form;
  swipe-left / swipe-right gestures on the day view (which already
  exist per the architect's compact transform) carry the per-day
  navigation. This is the most aggressive of the four moves and it
  needs an explicit anti-recommendation acknowledgement: **the reviewer
  flagged a "compress to tap-to-pick-date" affordance; PM blesses it,
  but only with the swipe gesture preserved as the per-day fallback so
  the gesture-comfortable user isn't forced into a date picker for
  yesterday.** If the architect finds the swipe gesture isn't yet
  shipped, the chevrons stay until the swipe lands — we don't ship a
  date-picker-only flow.
- **Date title (eyebrow "Today" + sub-line "Thursday, May 16") —
  MERGE INTO TAPPABLE.** This is the same node as the chevron merge
  above; the eyebrow + sub-line become a single tappable element with
  one Semantics node (the reviewer also called this out in
  Accessibility). One tap opens the date picker; the eyebrow + sub-line
  remain visually distinct (two text styles, single button surface).

Net effect: the top of the compact view goes from `[avatar | bolt |
search | chevron-left | "Today" / date | chevron-right | TodayPill]`
to `[search] / [tappable date pill] / [TodayPill on backdated]`. The
ring's top edge moves from ~140px down the viewport to ~60px down,
giving the ring its rightful gravitational center.

**Backend implication.** None.

**Acceptance criteria.**

- The avatar is removed from the compact header. Profile remains
  reachable via the "Me" bottom tab. No fallback text-avatar, no
  "Sign in" link, no replacement.
- The bolt icon is removed from the compact header. A long-press on
  the `LogFoodFab` reveals a two-up sheet ("Log food" routes to
  `/foods/search` as today; "Quick add kcal" opens `QuickAddSheet` as
  today). Short-press on the FAB retains its single primary action
  (Log food), matching what users have learned over the last 30 days.
- The date title + chevrons collapse into a single button. Tap →
  `showDatePicker(firstDate: today - 1 year, lastDate: today)`. The
  per-day navigation moves to the horizontal swipe gesture on the day
  view. If the swipe gesture is not yet implemented in the codebase,
  this acceptance criterion **gates on** the architect's swipe-gesture
  ticket — the chevrons remain until swipe lands.
- The `TodayPill` continues to render only when `date != today` and
  sits to the right of the date button.
- The `RingSummaryCard` is the first scrollable element after the
  header row. On a Pixel 4a viewport (393×851), the ring's center is
  no further than 280px from the top of the safe area (the prior was
  ~380px).
- A11y: the date button is a single `Semantics(button: true, label:
  "Today, Thursday May 16, open date picker")`. The reviewer's
  Accessibility note about the five-focusable-nodes-for-one-control is
  resolved by this merge.
- Test: launch Today on compact, assert the ring's `globalKey` paints
  within the first 320 vertical px of the scrollable area on a
  reference viewport.

---

### F10 — Streak / week-progress pill

**User story.** As a user who's been logging food for a week, I open
Today and see a small honest pill near the ring telling me "5-day
streak" or "this week: 4/7 days logged" — a single glance of
day-over-day continuity that turns logging into a habit without crossing
into gamification.

**Decision summary.** The metric is **"days logged this week"** — a 7/7
counter rendered as `"$logged / 7 this week"`. Not consecutive-day
streaks (which break when a user misses one day and demoralise
disproportionately), not "days hit kcal target" (we don't have a
"target" surface for non-active-goal users and the metric would silently
exclude them), not "days within ±10% of target" (precision invites
debate about the band). The week is **Monday–Sunday in the user's local
time**, matching the bottom of weekly grids in every fitness app the
user has seen. The visual is a **pill** (not a mini bar — the bar would
read as a progress affordance and invite a tap-to-fill mental model we
don't pay for), placed **immediately below the calorie ring inside the
RingSummaryCard, above the macro row**. It carries `weeklyLoggingProvider`
data and renders a single line:
`"This week · 4/7 days logged"` with `4/7` in `AppColors.accent` and the
rest in `ink2`. The pill is hidden when the count is 0/7 — empty state
is the empty-day pill's job; we don't double up.

The metric is **client-side aggregated for v1** — fold over the last 7
day-summary providers (Monday through Sunday of the current local week)
and count days where `entries.length > 0`. The architect's call: if the
fold is more than ~10 lines, lift it to `weeklyLoggingProvider` in
`lib/providers/`. The reviewer flagged a possible server-side
computation; PM ruling is **v1 stays client-side**, BE-002 is flagged
for the backend team as a v1.1 optimisation if the day-summary fan-out
becomes expensive. We do **not** introduce a streak history surface,
celebratory animation, or any "you broke your streak" notification.
The pill is a counter, not a system.

**Backend implication.** None for v1. BE-002 (flagged, non-blocking): a
`GET /me/weekly-logging` endpoint that returns
`{ week_start, days_logged }` for the current week. Worth doing if and
when `daySummaryProvider`'s fan-out shows up in telemetry.

**Acceptance criteria.**

- New provider `weeklyLoggingProvider` in `lib/providers/` returns an
  int 0–7 representing days-with-any-log in the current local week
  (Mon–Sun).
- A new private widget `_WeekProgressPill` renders inside
  `RingSummaryCard`, immediately below the ring caption and above the
  `MacroBar` row. On compact, full-width within the card's padding;
  on expanded, the same widget renders inside the right-rail
  `RingSummaryCard` clone.
- Hidden when count is 0. Renders `"This week · N/7 days logged"` for
  count 1–7. When count is 7, an `AppColors.accent` "·" or check is
  acceptable but **no animation**, **no fire emoji**, **no
  "celebration" surface**.
- A11y: the pill is a single Semantics node — `"This week, four of
  seven days logged"`. T-20 honoured.
- The pill does **not** route on tap. It is read-only.
- Test: with fixture data of 3 logged days in the current week, the
  pill renders `3/7`; with 0, the pill is absent from the tree.

---

## 3. Cross-cutting usability themes

The review's seven themes (A–G); my PM response on each.

### Theme A — The Today screen has lost its anchor (P0)

**ACCEPTED**, with the per-affordance decisions made in §2 above
("Today compact header compression"). The architect picks up the
specific cut/merge/move list as the implementation contract. Push-back
applied: the reviewer's chevron-merge call required a swipe-gesture
prerequisite that's now an explicit gate in the acceptance criteria.

### Theme B — Daily-ritual paths are too long (P0)

**ACCEPTED**, instantiated as F1 + F2 in §2. F2 alone cuts the
re-log path from 6 taps to 3; F1 cuts the *re-meal* path from 12+ taps
to 2. The reviewer's framing was "the widget exists for expanded;
expose it on compact" — agree, and we lift `QuickAddChips` to
`lib/widgets/` in the same change per T-23.

### Theme C — Tappable affordances that do nothing (P1)

**ACCEPTED**, expanded scope. The reviewer named three specific sites:

- `food_detail_screen.dart:300` — `more_horiz` overflow icon with
  `onPressed: () {}`.
- `weight_screen.dart:152` — calendar icon with `onPressed: null`.
- `weight_screen.dart:300` — "See all" plain text that visually reads
  as a button.

All three: **delete in v1, restore when wired**. Same shape as QL-006
(bookmark) and QL-007 ("Coming soon" rows). The architect's
implementation ticket should grep for `onPressed: () {}` and
`onPressed: null` across `features/*` to catch any further instances
the reviewer didn't enumerate. The "See all" specifically — the
reviewer noted weight history is high-value and a full history route
would be product surface; we're **deferring the full-history route to
v1.1** and cutting the dead "See all" for now. The 5-row recent
entries list stays; users with months of data are a small cohort in
v1's window.

### Theme D — Edit/Save enablement is inconsistent (P2)

**MODIFIED to MIXED-RESPONSE.** The reviewer is correct that the
HeightStepperSheet / CurrentWeightSheet save-always-enabled is the
worst case (no-op PATCH succeeds silently). We accept the **"disable
when unchanged"** rule for the two sheets that do silent no-op PATCHes:
`HeightStepperSheet` and `CurrentWeightSheet`. We **do not** ship the
broader 30-minute audit + lint-rule the reviewer suggested for v1 —
unifying SexPicker / ActivityLevelPicker (tap-to-save) under a
"disabled-when-seed" rule would require introducing a save button
where there isn't one, which is anti-pattern for those pickers. The
audit lands in v1.1 alongside QL-015's test-coverage extension. The
two sheet-level fixes ship now; the architectural unification is
deferred. Push-back acknowledged: the reviewer earned the right to ask
for the lint rule, and PM is saying "smaller scope this pack, full
audit next pack." A four-line dartdoc note in each affected sheet
naming its current mental model is acceptable as a placeholder.

### Theme E — Loading states are skeletons, error states are noisy (P2)

**MODIFIED.** The reviewer's "single global Connection-issues snackbar,
debounced" is the right shape, but it touches a seam (the SnackBar
plumbing across screens) we haven't yet generalised. PM ruling:
**defer the global debounced SnackBar to v1.1** as a single
architect-led refactor (BE-N/A, FE-only); for *this* pack, the
narrowest fix is to **add a per-screen 3-second cooldown** to
SnackBar.showSnackBar calls — same screen, same error code, within
3s, swallow. This is a 10-line `lib/widgets/snackbar_throttle.dart`
helper that screens opt into; not a full debouncer. Three stacked
SnackBars on a flaky-network burst go to one. The inline EmptyStates
are unchanged.

### Theme F — The medium breakpoint is "phone with padding" (P2)

**DEFER (v1.1).** The reviewer correctly identifies that medium
renders compact-with-padding and that's experientially unintentional.
But the iPad-portrait user is rare in our cohort, and the fix
(compress medium → 720px boundary, or commit medium to rail-style nav)
is a layout-substantial change that pulls the architect into a
breakpoint design pass. The pack is large enough without it. **v1.1
ticket flagged: "Medium breakpoint design pass — pick rail-style nav
or shrink boundary to 720."** Not in this pack.

### Theme G — Discoverability of recent features lags their value (P2)

**MODIFIED — DEFERRED MOST, ACCEPT ONE.** The reviewer correctly says
"don't ship coachmarks" (this is also explicitly an anti-recommendation
in §8 of the review and §7 of this doc) — agree. Their suggested
softer alternatives:

- A subtle dot on the bolt icon for the first three opens: **REJECT**.
  The bolt is moving off the top bar entirely per Theme A; a dot on a
  disappearing affordance is wasted budget.
- A one-line tip below the ring on day 2 ("Tap a logged food to edit
  it"): **DEFER (v1.1)**. The pattern is right but it intersects with
  the F10 streak pill's real estate. Pick after the streak pill
  ships.
- A "What's new" footnote in the profile screen's data card:
  **REJECT for v1**. "What's new" surfaces age badly (the reviewer
  herself flags this on coachmarks) and v1 has no shipping cadence
  yet. The footnote is real product surface; we'll design it after we
  have a release.

So Theme G nets to "deferred." That's the honest read.

---

## 4. Per-screen quick takes

**Today (compact).** Heavy churn this pack. Header compression
(Theme A / §2), recent-foods chip row (F2), copy-from-yesterday
overflow on meal headers (F1), whole-day-copy row on empty days (F1),
streak pill inside RingSummaryCard (F10). The screen's daily-ritual
density goes up by 3–4 affordances and *down* by 4 (avatar, bolt,
chevron pair as separate clickables). Net visual weight stays roughly
constant; net cognitive weight drops because the affordances now serve
the user's intent rather than chrome it.

**Today (expanded / web).** Light touch. The right-rail Quick add
card is unchanged (it was already the model for F2). The streak pill
renders inside the right-rail `RingSummaryCard` per F10. The top-bar
`_TopSearchField` stays a stub-look-real-input for this pack
(reviewer's call to either real-text or button-shape it — deferred,
see §5). No header compression — expanded's header doesn't have the
six-affordance problem.

**Search.** Untouched in this pack. The reviewer's friction items
(loading transition signal, focus restoration on back-nav, "common
foods" surface on empty-query) are all deferred to v1.1. The
recents/frequents-on-Today change (F2) reduces the urgency on
re-entering search at all.

**Food detail.** Two cuts (the no-op `more_horiz` icon and any other
`onPressed: () {}` site — Theme C). F3 ("fits in your day" badge) is
deferred (see §5). The dense nutrition table stays as-is.

**Log entry sheet.** Stable. The reviewer's "move preview to top of
form," "collapse note into opt-in," and "rethink serving as inline
radios instead of nested modal" are all real but they touch the sheet
shape in a way that requires its own pass. Deferred to v1.1.

**Quick add (calories).** Stable. The "synthetic quick-add row is
generic" friction (reviewer §2.6) is a real product question (do we
let users name quick-adds?) deferred to v1.1. The bolt icon moves
into the FAB long-press menu per Theme A.

**Custom food (create + edit).** Stable. The reviewer's "per-serving
nutrition entry mode" toggle is a real ergonomic win but adds a unit
seam (per-100g ↔ per-serving on input) that needs its own design.
Deferred to v1.1.

**Weight.** F5 (pre-fill) + F4 (scrub-to-read) ship this pack. The
"See all" plain-text stub (Theme C) is cut. The calendar icon
(Theme C) is cut. The chart gains a gesture path.

**Goals.** Stable. The "two equal-weight primary buttons on the active
card" friction is real (reviewer §2.9) and lands as a **one-line
change** in this pack: make "Edit current" primary, "New goal" outlined.
The kg/week rate friction stays open per the goal-rate-stays-in-kg
ruling in the Display Units Principle; the reviewer's "lift the
customer-expected-unit principle to rates" call is **rejected** for v1
— see §5. Goal-history "achieved / ended early" badges are deferred to
v1.1.

**Profile.** Stable except for the "(dev)" version-tag grep — flag for
the architect to thread build flavour before release. The
identity-row + Body card splitting suggestions are deferred to v1.1.

**Onboarding.** Stable. The reviewer's step-count tag, the side-by-side
rate comparison on step 3, and the hide-Start-Over-on-step-1 are all
deferred to v1.1. Onboarding shipped, works, isn't broken.

**My foods.** Stable. Sort options, bulk operations, brand+barcode
filter — all already deferred to v1.1 per `audit_followup_pm.md`.

**Barcode scanner.** Stable. Scan history (review §2.13) is a real
v1.1 product idea (flag for backend team — see §9). Web-on-phone
paste-barcode parity is a small architect-led tweak; deferred.

---

## 5. Functional gaps — accept / defer / reject

The reviewer's functional-gaps list (F1–F10) plus the per-screen
friction items, each with a one-line disposition.

- **F1 — Copy yesterday's meal.** **ACCEPT.** See §2 deep dive.
- **F2 — Recent-foods chip row on Today compact.** **ACCEPT.** See §2
  deep dive.
- **F3 — "Fits in your day" badge on Food detail.** **DEFER (v1.1).**
  Real win, but lands in a future "Food detail polish" pack so it can
  ship alongside the F3 sibling we'd want — "fits with my goal-day
  remaining macros," which is a richer surface. Shipping just the
  kcal-fits-in badge is acceptable v1.1 work; not blocking this pack.
- **F4 — Weight chart scrub-to-read.** **ACCEPT.** See §2 deep dive.
- **F5 — Weight log pre-fill.** **ACCEPT.** See §2 deep dive.
- **F6 — Water tracking.** **REJECT for v1, DEFER to v2.** This is real
  scope (new wire field on LogEntry or a separate `WaterEntry` table) and
  intersects with F8 (exercise / calories burned) — both are "non-food
  trackers" and they should be designed as a coherent category, not
  bolted on one at a time. The reviewer agrees this is slow work; PM
  agrees and adds: it doesn't make the v1 cut.
- **F7 — Photo of a meal.** **DEFER to v2.** Backend + storage; out of
  v1's window. The reviewer noted this is worth scoping deliberately;
  PM agrees, parking ticket BE-not-yet-numbered.
- **F8 — Exercise / calories burned.** **DEFER to v2.** Same shape as
  F6 — needs a coherent "non-food entry" design before we ship the
  first one.
- **F9 — Saved meals / favourites.** **DEFER to v1.1.** F1 (copy meal)
  substitutes for ~80% of the favourite-meals use case; we ship F1
  and watch usage before designing favourites.
- **F10 — Streak / week-progress pill.** **ACCEPT.** See §2 deep dive.

**Per-screen friction items that warrant explicit acceptance / defer
calls (the reviewer's §2 walk):**

- **Goals card — "Edit current" vs "New goal" both primary.**
  **ACCEPT.** "Edit current" stays primary; "New goal" becomes
  outlined. One-line change, lands in this pack.
- **Goals — goal rate in kg/week regardless of `weight_unit`.**
  **REJECT changes for v1.** This is explicitly resolved in
  `pm_decisions_flutter_ui.md` (Display Units Principle addendum:
  "Goal rate stays in kg/week regardless of weight_unit"). The
  reviewer's call to lift the unit principle to rates is reasonable
  but lifts an explicit prior PM ruling; we don't invert that
  silently. v1.1 follow-up flagged.
- **Food detail — `more_horiz` no-op.** **ACCEPT.** Delete the icon.
- **Weight screen — calendar icon no-op + "See all" stub.** **ACCEPT.**
  Delete both.
- **Profile — identity row Edit / Export data "Coming soon."**
  Already resolved in `pm_qol_audit.md` (QL-007) — both rows hidden
  until real auth / export design. Nothing changes here.
- **Profile — "(dev)" version tag.** **ACCEPT.** Architect grep + fix
  before release; one-line per `pubspec.yaml` flavour wiring.
- **Onboarding — Start Over on step 1.** **DEFER to v1.1.** Small
  win, not load-bearing this pack.
- **Log entry sheet — preview block above the fold during save.**
  **DEFER to v1.1.** Real friction; intersects with the sheet's
  shape, which has its own pack coming.
- **Log entry sheet — nested second modal on serving select.**
  **DEFER to v1.1.** Same as above.
- **Quick add — synthetic row reads as generic.** **DEFER to v1.1.**
  The "give quick-adds an optional name" path is the right
  v1.1 ticket.
- **Top-bar search input on web (`_TopSearchField`).** **DEFER to
  v1.1.** Either fix path the reviewer named (real-text vs button-shape)
  is a small change; bundling with the Search-screen v1.1 pack is the
  right cadence.
- **Custom food — per-serving nutrition entry mode toggle.** **DEFER
  to v1.1.** Real ergonomic win, separate design pass.
- **Empty meal cards at full chrome on expanded grid.** **DEFER to
  v1.1.** "Render empty meals at half-height" is a real polish item;
  not load-bearing this pack.
- **Barcode scanner — no scan history.** **DEFER to v1.1.** Worth
  doing when scan analytics show repeat-scans. BE-003 flagged for
  backend.

---

## 6. Accessibility findings response

The reviewer's accessibility section (§5) named six items. Disposition:

- **`_TopSearchField` missing explicit `Semantics(button: true)`.**
  **ACCEPT.** Add the wrapper. One-line fix in this pack.
- **Compact day-view date bar — five focusable nodes for one logical
  control.** **ACCEPT, INSTANTIATED IN THEME A.** The header
  compression collapses the date title + chevrons into a single
  tappable element; this is the same node-merge the accessibility
  finding wants. Lands as a side-effect of Theme A.
- **Bolt icon tooltip disambiguation.** **N/A** — the bolt is removed
  from the top bar entirely (Theme A); the FAB long-press menu items
  carry their own Semantics labels ("Log food", "Quick add calories")
  which are already unambiguous.
- **`LogEntrySheet` serving-select nested modal focus trap.** **DEFER
  to v1.1.** Intersects with the deferred "rethink serving select"
  item; ships in the same pack.
- **`CalorieRing` + macro bars — `MergeSemantics` on the macro
  row.** **ACCEPT.** Wrap the three `MacroBar`s in a single
  `MergeSemantics` so the announcement is one statement. Two-line
  change in `RingSummaryCard`.
- **Pending-sync badge — no `LiveRegion` on flush.** **ACCEPT.** Wrap
  the badge in `LiveRegion` so the screen-reader user gets a "Synced"
  announcement on the post-flush fade. Confirms T-22's spirit
  (pending-sync state is visible, not silent) for the a11y surface.

Net: four accept (one is a side-effect of Theme A), one N/A, one defer.

---

## 7. Anti-recommendations honoured

The reviewer's §8 anti-recommendations are inherited as constraints
for this pack:

1. **No coachmark / first-run tour.** Honoured. F10's streak pill, F2's
   chip row, and F1's overflow item are all *visible affordances*
   that disappear when context dictates — not training surfaces. The
   one-line tip below the ring (Theme G) was the closest the reviewer
   came to a coachmark; we deferred it.
2. **No stub Trends tab.** Honoured. F10 ships a single line inside an
   existing card, not a tab; PM Risk 3 stays resolved.
3. **No merging QuickAdd into the LogEntrySheet.** Honoured. F1 ships
   `CopyDaySheet` as a *third* sheet, distinct from both
   `LogEntrySheet` and `QuickAddSheet` — three sheets, three intents.
   The reviewer's framing ("the cognitive load is different") stays the
   rule.

The architect should treat these as immovable constraints in the
implementation plan. Any future PM pack that wants to invert one of
these starts with explicit naming of the inversion, not a quiet
re-litigation.

---

## 8. Sequencing recommendation

The architect will refine, but the PM-level ordering matters because
some items reserve real estate others want:

1. **Theme A — Today compact header compression.** Ships first. This
   reclaims the top of the viewport for the ring and for F10's pill,
   and reclaims the meal-section overflow slot for F1's "Copy from
   yesterday." Touching these in the wrong order means F1 and F10 ship
   into a header that hasn't been compressed yet — F1's overflow
   item conflicts visually with the existing bolt-and-search density,
   and F10's pill renders below a ring that's still pushed down.
2. **F2 — Recent-foods chip row on compact.** Lift `QuickAddChips` to
   `lib/widgets/`, expose on compact. Depends on Theme A only because
   the strip's vertical position is "between the ring and the meal
   sections" and the ring's vertical position changes in Theme A. The
   widget lift itself is independent.
3. **F1 — Copy yesterday's meal.** Both the per-meal overflow and the
   whole-day empty-day row depend on the meal-section header layout
   landing post-Theme A. The `CopyDaySheet` itself is independent of
   the header work.
4. **F4 + F5 — Weight chart scrub + log pre-fill.** Independent of the
   Today work entirely. Can ship in parallel with the Today pack as a
   separate review-able PR. Architect: this is a good slot for a
   parallel agent.
5. **F10 — Streak / week-progress pill.** Ships last in the Today
   pack. Depends on the F10 pill having real-estate inside
   `RingSummaryCard` which is shaped by Theme A. Trivial work; just
   sequence after.
6. **Theme C cleanup — delete the dead `onPressed` sites.** Anytime.
   Mechanical sweep, can land as a single PR ahead of or after the
   feature work.
7. **Goals card — "Edit current" / "New goal" button hierarchy fix.**
   Anytime. One-line.
8. **Accessibility accepts (§6).** Anytime. Small, mechanical.

Critical-path is **Theme A → F1 + F2 + F10** (the Today changes); F4/F5
runs in parallel; everything else is cleanup that lands either side.

---

## 9. Backend tickets flagged

`POST /log/copy` (the F1 wire) is **already shipped** per OpenAPI lines
668–698 + `CopyDayBody`/`CopyDayResponse` schemas at lines 1109–1127.
Server-side snapshot recomputation is documented at lines 673–678 and
is the behaviour the client relies on. No backend work blocks F1. The
architect should confirm the Rust route is wired against the OpenAPI
operation (it should be — the spec commit precedes this pack), but
that's verification, not implementation.

Other backend tickets flagged for the backend team — **not blocking**
this pack:

- **BE-002 — Weekly logging count endpoint** (`GET /me/weekly-logging`
  → `{ week_start, days_logged }`). For F10. v1 ships client-side
  fold; this endpoint becomes the optimisation when `daySummaryProvider`
  fan-out shows up in telemetry or when we add server-side caching.
  Non-blocking, low priority.
- **BE-003 — Barcode scan history** (`GET /scan-history` or a column on
  `LogEntry` that surfaces "last scan timestamp"). For the deferred
  scan-history v1.1 affordance. Non-blocking, design needs PM follow-up
  before this is well-specified.
- **BE-004 — Goal achievement status** (a `goals.status` field or
  derived flag — `active | achieved | ended_early`). For the deferred
  goal-history "achieved" badges (v1.1). Non-blocking.

No wire-breaking changes requested by this pack. The Display Units
Principle holds, the `User.weightUnit` field continues to drive display
through the existing `formatWeight` seam, the outbox stays scoped to
single-entry `POST /log` per Risk 6, and the OpenAPI shape is unchanged.

---

## 10. Punt list

Explicit deferrals beyond what the reviewer already deferred:

- **F3 (fits-in-your-day badge on Food detail).** v1.1 — ships alongside
  a "fits with goal-day remaining macros" sibling so the surface is
  designed once.
- **Search screen improvements** (loading transition signal, focus
  restoration, "common foods on empty-query"). v1.1 — bundled.
- **Log entry sheet shape** (preview above fold, opt-in note, inline
  serving select). v1.1 — bundled, this is its own pack.
- **Custom food per-serving entry mode.** v1.1.
- **Top-bar `_TopSearchField` on expanded.** v1.1.
- **Empty meal cards at half-height on expanded grid.** v1.1.
- **Onboarding niceties** (step count tag, side-by-side rate
  comparison, hide Start Over on step 1). v1.1 — bundled.
- **Profile splits** (immutable identity vs measurements). v1.1.
- **Quick-add row naming.** v1.1.
- **Medium breakpoint design pass.** v1.1.
- **Goal-history "achieved" badges.** v1.1 (depends on BE-004).
- **Goal rate in customer-expected units (lb/week, st/week).** REJECTED
  for v1 (explicit prior PM ruling stays); v1.1 if user data shows
  the kg-only rate is genuinely confusing in practice.
- **Theme D unification** (sheet save-button enablement audit + lint).
  v1.1 — this pack ships only the two HeightStepperSheet /
  CurrentWeightSheet fixes.
- **Theme E global error SnackBar debouncer.** v1.1 — this pack ships
  only the per-screen 3-second cooldown helper.
- **Theme G one-line tip below ring on day 2.** v1.1 — after F10's
  pill ships and the real estate is settled.
- **F6 / F7 / F8 (water / photo / exercise).** v2 — designed as a
  coherent non-food-entry category, not piecemeal.
- **F9 (favourites).** v1.1 — observe F1 usage first.
- **Scan history.** v1.1 (depends on BE-003).
- **Full weight history route ("See all" wired).** v1.1.
- **Profile identity Edit / Export data rows.** v2 (auth, export
  design).
- **Trends tab.** v2 (Risk 3 stays resolved).
- **Dark mode.** v2 (Risk 5 stays resolved).

The bar for this pack: the user opening Today on day 14 has **two
new affordances** that make re-logging cheaper (F1 + F2), **one new
affordance** that makes day-over-day continuity visible (F10), **two
small wins** on the weight surface (F4 + F5), and a **compressed
header** that puts the ring back where the user looks first. That's
the daily-ritual delta. Everything else is supporting cleanup or
deferred to the next pack.

---

## 11. Acceptance for the entire pack

"The UX pack is shipped" means:

- F1 lands client-side against the already-shipped `POST /log/copy`,
  with the per-meal overflow + the empty-day "Copy from another day"
  row both wired. Failure UX is `T-11`-shaped; partial-skip surfaces in
  the SnackBar.
- F2 lifts `QuickAddChips` to `lib/widgets/` (T-23) and exposes it on
  compact between the `RingSummaryCard` and the first `MealSection`.
  Tap → seeded `LogEntrySheet`.
- F4 lands a drag (compact) / hover (expanded) scrub gesture on
  `WeightSparkline` that paints a guideline + tooltip without
  hijacking parent scroll.
- F5 pre-fills `LogWeightSheet` from
  `weightHistoryProvider.firstOrNull?.weightKg ?? user.currentWeightKg`,
  in the user's display unit.
- F10 ships a `_WeekProgressPill` inside `RingSummaryCard` driven by
  a client-side `weeklyLoggingProvider`.
- Theme A re-anchors the compact header: avatar cut, bolt moved to FAB
  long-press, chevrons collapsed into a tappable date pill (gated on
  the swipe-day gesture being in the codebase). The ring lands within
  the first 320 vertical px of the scrollable area.
- Theme C deletes the named no-op `onPressed` sites
  (`food_detail_screen.dart:300`, `weight_screen.dart:152` and `:300`)
  plus any others a grep surfaces.
- Goals — "Edit current" stays primary; "New goal" goes outlined.
- Accessibility accepts (§6): `_TopSearchField` button Semantics,
  `MergeSemantics` on `MacroBar` row, `LiveRegion` on pending-sync
  badge.
- Verification commands:
  - `flutter test test/features/today/copy_day_sheet_test.dart`
  - `flutter test test/features/today/quick_add_chips_compact_test.dart`
  - `flutter test test/features/weight/log_weight_prefill_test.dart`
  - `flutter test test/features/weight/sparkline_scrub_test.dart`
  - `flutter test test/widgets/ring_summary_card_streak_pill_test.dart`
  - `flutter test test/features/today/header_compression_test.dart`
  - `grep -rn 'onPressed: () {}' lib/features/` → zero hits.
  - `grep -rn 'onPressed: null' lib/features/weight/` → zero hits.
- The architect produces `architect_ux_pack.md` mapping each of the
  pack's items to a developer-pickable ticket (UX-001..UX-NNN) with
  the file list per item.

The user named the bar: "all of these." We have run all of them through
the filter. Three made the deep-dive list (F1, F2, F10), two more got
deep dives because they pair (F4 + F5), one cross-cutting theme got
the compression treatment (A), one got modified scope (D + E), three
were deferred with rationale (F, G, plus several per-screen items),
and three got the rejection treatment because they invert an existing
PM ruling or invent v2 scope (F6, F7, F8, plus the goal-rate-in-lb
call). The codebase is one ritual-compression pack closer to "the
user opens this on day 14 because the daily friction stayed low."
