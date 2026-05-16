# UX Review: Fulfilled Flutter Client

Walk-through of the deployed app at commit `a6ba4cf` against a usability
lens — separate from the PM's feature-priority audits. The two prior audits
(`pm_qol_audit.md`, `architect_qol.md`) closed 18 papercuts and a navigation
refactor; what's left is the gap between "code is clean" and "the daily-use
experience pulls a user back tomorrow." This review is opinionated by design:
the user explicitly asked for it, and vague reviews waste their time.

Reading order if you only have ten minutes: §1, §7, §3. The per-screen
walkthrough in §2 is reference; the functional gaps in §4 are where the
product still has room.

---

## 1. Executive summary

The app **renders correctly** on every screen and form factor — the tenants
held, the units rewrites paid off, the post-mutation navigation rule (T-24)
killed the worst friction in the QoL audit, and the empty-day pill plus
TodayPill smoothed two of the rougher first-run moments. What it **doesn't
yet do** is reward a returning user: there is no faster way to log breakfast
on day 14 than there was on day 1, the Today screen has nowhere to put a
"what's next" prompt, and the right rail on desktop spends its real estate
on a static recents/frequents block instead of a daily ritual.

The product walks the line of "scaffolding is done; the experience-shaped
work hasn't started." A user opening the app for the first time succeeds
without confusion. A user opening the app for the fourteenth time is doing
the same six taps they did on day one — and that's where calorie trackers
either become habit or fall off the home screen.

**Top 3 highest-impact recommendations.**

1. **Surface a "Repeat yesterday's breakfast" / "Copy meal" affordance on
   Today.** The `/log/copy` endpoint already exists on the backend and the
   client never calls it. This is the single biggest day-14 win we have
   shipping budget for — and it's already paid for on the wire.
2. **Reduce average-flow log-a-food tap count from ~7 to ~3.** Right now a
   typical log is: Today → search icon → field → type → result → log sheet
   → save. The recents/frequents chips on `/foods/search` could fold into
   Today on every form factor (today they live on the right rail on web
   and inside the search screen on mobile, so the mobile user has to
   navigate *into* search to see what they ate yesterday). A "recent food
   chip row" above the meal sections on compact would change the daily
   ritual.
3. **The Today calorie ring is no longer the screen's anchor on the
   compact view.** The eyebrow "Today" + sub-line "Thursday, May 16" +
   the chevrons + the TodayPill + the bolt icon + the search icon
   collectively pull more visual weight than the ring itself. The header
   has six concurrent affordances above the ring; the ring is what the
   user came to see. Either compress the header or grow the ring.

---

## 2. Per-screen usability walkthrough

### 2.1 Today (compact, the daily-driver screen)

**Works.** The empty-day pill is correct — it answers "is the app
broken?" within the first frame, and the FAB is the implicit affordance
the pill points at. The TodayPill on backdated views is a real win — five
chevron taps collapse to one. Tap-to-edit on logged rows is discoverable
once the user knows about it (more on that below).

**Friction.**
- The compact header has *six* interactive affordances stacked across two
  rows (avatar, bolt, search, prev-day, next-day, sometimes the
  TodayPill) before the user gets to the calorie ring. The mocks gave us
  two icons (avatar + search). The bolt and the TodayPill are good
  additions in isolation but together they make the header read as a
  toolbar — the ring, which is the user's *answer to "am I doing okay?"*,
  starts ~140 px down the screen. Compare a phone screenshot to the
  original mock: the visual hierarchy has tilted noticeably toward
  controls.
- The "tap a row to edit" affordance has no visual hint. The row hovers
  on web (good) but on mobile there's nothing — no chevron, no underline,
  no "press and hold to delete" hint. New users will discover edit only
  by accidental tap. Consider a faint chevron on the right edge of each
  row, or a subtle row-tap-target outline on first run.
- Long-press to delete is the standard expectation from competitor apps;
  the spec says it lives on the row's right-side overflow for pending
  entries but synced entries have no delete affordance at all today.
  Users will hunt for swipe-to-delete and not find it.

### 2.2 Today (expanded / web)

**Works.** The 2×2 meal grid is genuinely pleasant — it makes the day's
shape visible at a glance. The right rail is the right idea.

**Friction.**
- The right rail is **static** in a way that wastes the real estate.
  RingSummaryCard, Quick add chips, mini weight sparkline — all
  informational, none of them daily-ritual triggers. A "Today vs
  yesterday" delta, a "you're on track for week-end weigh-in" callout,
  or a "log breakfast (it's 8:43 AM)" prompt would turn the rail from
  reference into invitation.
- The top-bar search input on web is a tap-target stub (`_TopSearchField`)
  that routes to `/foods/search` — it has placeholder text, an input
  visual, and it doesn't actually accept typing. A user expects to type
  into a field that looks like a field. Either make it a real
  text-on-focus field, or change the visual so it doesn't read as one
  (e.g., a button labeled "Search foods (/)").
- The meal grid renders the same chrome whether a meal is empty or
  populated. The empty Dinner card at 8 AM is visually loud — it's
  paying full card-cost in the grid even though it carries zero
  information. Consider rendering empty meals at half-height or with a
  ghosted "log dinner" affordance instead of full chrome.

### 2.3 Search

**Works.** Highlight rendering is correct. Debounce is invisible.
Skeleton rows match populated row height (T-08 honored). Recent /
Frequent chip rows are great when discovered.

**Friction.**
- **Search is a separate screen, not a peek.** On mobile, getting to
  search costs a full route push — meaning the recents/frequents I
  saw yesterday are out of view until I'm already committed to
  searching. A small "Recent foods" chip strip on Today (above or below
  the ring) would let me re-log without leaving home.
- The "RESULTS" eyebrow + count is correct but the count animates from
  blank to "12 foods" silently — there's no transition signal that
  loading finished. A 100 ms fade or a dot-pulse would close the gap.
- The case-sensitive autofocus on initial route entry is right, but
  if a user navigates *back* to the search screen (e.g., from a food
  detail), focus is lost. Restoring focus on re-entry would feel like
  a more responsive flow.
- The empty-query state shows Recent + Frequent only — no "Common
  foods" / "What you ate yesterday" affordance. The expanded right rail
  on Today shows this; the search screen should mirror it.

### 2.4 Food detail

**Works.** Layout matches the mock. Per-100g panel is correctly labeled.
Source badge replaces the quality score per the PM ruling. The Edit
affordance for user-source foods is appropriately scoped.

**Friction.**
- The "Add to log" sticky CTA on compact is a single 54-px button at the
  bottom. **But there's no way to log without scrolling first** —
  unlike a button visible on first paint, this requires the user to know
  the page is scrollable. Most users will see hero + summary card and
  scroll naturally, but a first-time user landing from a barcode scan
  may not.
- The nutrition table is dense and quiet — three macros + a few
  sub-rows. There's no visual indication of *how this food fits into my
  day* (e.g., "this serving is 23% of your protein goal"). A returning
  user is doing this math in their head every time. A small "fits into
  today" badge near the kcal would close the loop. (This is similar to
  what the LogEntrySheet does, but the user has to commit to logging
  first to see the comparison.)
- The overflow `more_horiz` icon on the right edge of the app bar has
  `onPressed: () {}` — a no-op (line 300 of `food_detail_screen.dart`).
  Same anti-pattern as the bookmark icon QL-006 cut. Either wire it or
  delete it.

### 2.5 Log entry sheet

**Works.** The DATE row is a meaningful win — backdating from inside the
sheet matches user mental model. Quick multiplier chips bind correctly
to the stepper. The preview block is the right shape. Save-button
skeleton (instead of a spinner) is correct.

**Friction.**
- The sheet is **long** on compact — SERVING, QUANTITY, MEAL, DATE,
  NOTE, preview, save — and the keyboard pops on autofocus, so a user
  sees roughly Serving + Quantity + half the meal chips before they have
  to scroll. On a small phone (Pixel 4a, iPhone SE) the preview block
  is below the fold *during* save. The user can't see "Will log: 195
  kcal · P 33 g" while pressing Save. Consider moving the preview
  block to the top of the form (under the food name) so it's always
  visible — the user can watch the math update as they adjust quantity.
- The serving select opens a *second* modal bottom sheet (a popup) when
  tapped. Two nested sheets on mobile is a smell. Consider rendering
  servings as a row of segmented chips (when there are ≤ 3 servings,
  which is the common case for a custom food) or as inline radio rows
  for OFF foods that often have many servings.
- The meal chip picker uses the same accent for the selected meal as
  the save button. Visually the user has to do a small disambiguation
  ("which thing is the active action vs. the selected chip?"). Consider
  outline-selected for the chip and filled-accent for the save button,
  or vice versa — one of them should be quieter.
- **The NOTE field is autofocus-eligible after the quantity stepper
  commits**, but in practice notes are added rarely and the field
  occupying ~80 px of vertical real estate above the preview pushes the
  preview further off-screen. Consider collapsing the note into a
  "Add note" affordance like the macros toggle in QuickAddSheet —
  showing the field only when the user opts in.

### 2.6 Quick add (calories)

**Works.** Bolt icon discoverability is reasonable (left of search in
both compact and expanded headers). The macros toggle is the right
affordance — keep the common case ("just 200 kcal of something") fast,
expose macros for users who care. The dialog enter animation reads as a
modern, deliberate sheet.

**Friction.**
- The synthetic Quick-add food id leaks into the meal section's
  `_metaLine` predicate (`if (entry.foodId == _quickAddFoodId) return
  '';`). The row reads as "Quick add ... 105 kcal" — fine, but the
  rendered title is "Quick add" which is generic. A user logging "200
  kcal pre-workout shake" can't differentiate yesterday's quick-add from
  today's quick-add when reviewing their log. Consider letting the user
  set a one-line label on the quick-add (renders as the food name in the
  row), or auto-naming as `"Quick add · 200 kcal"` so two entries don't
  visually merge.
- The macros are entered as plain values without any "this should equal
  4·P + 4·C + 9·F = kcal" cross-check. A user typing 30g protein, 30g
  carb, 30g fat into a 200-kcal quick-add will silently mismatch. A
  quiet warning if the macros don't roughly add up to the kcal would
  help — but only as a hint, not a block (some entries genuinely don't
  sum cleanly).

### 2.7 Custom food (create + edit)

**Works.** Three-section flow is clear. Inline validation rows are
correct (T-11 honored). Edit-mode disabled-until-changed save is right.
Servings list with default + synthetic always visible matches the
nutrition panel (T-10 anchor honored).

**Friction.**
- The nutrition section asks for **per-100g** values, which is the
  correct wire convention — but a US user looking at a Nutrition
  Facts label has a "per serving" number in front of them. They have to
  do the math: "the label says 240 kcal per 1 cup, the package says 1
  cup is 230 g, so per 100 g is..." A "I have a serving" / "I have
  per-100g" radio toggle at the top of the nutrition section would let
  users enter the more natural number for what's in front of them, and
  the math happens once on the client.
- The "Servings" editor is a separate section that gets little visual
  attention but does the heavy lifting for accurate logging. Most users
  will fill in name + nutrition and forget servings entirely. A nudge
  ("Add a serving so this is easier to log later") next to the
  "Add serving" affordance would help, especially in create-mode.
- The barcode field on the create form is plain text on web with a
  helper line ("Use the mobile app to scan"). This is correct for v1,
  but if a user pastes a barcode here (e.g., from a manufacturer's
  website or a chrome extension), there's no validation feedback that
  the digits look right. Consider mirroring the search screen's
  barcode-affordance heuristic (`^\d{8,14}$`) and highlighting a valid
  barcode with a green check.

### 2.8 Weight

**Works.** Summary card + sparkline + history list is exactly what a
user expects. The WeightStepper / HeightStepper stacked-not-side-by-side
fix (recent UX work) is invisible to the user, which is the goal.
Range segmented control on the chart is the right size.

**Friction.**
- The "RECENT ENTRIES" eyebrow has a "See all" affordance on the right
  that **isn't wired** (it's a plain `Text`, not a button — line 300 of
  `weight_screen.dart`). Same anti-pattern again. Either wire it to a
  full history route or remove it.
- The calendar icon in the top bar has `onPressed: null` (line 152).
  This is the exact pattern QL-006 / QL-007 cut for the food-detail
  bookmark and profile rows: a tappable-looking icon that does nothing.
- The chart has no way to **scrub** to read individual values. A user
  tapping a point on the line (or hovering on web) expects a tooltip
  showing "May 14, 78.4 kg". Today the chart is decorative only.
- The "Log weight" sheet doesn't pre-fill with the user's last weight —
  every entry starts from a default seed. Real weight measurements vary
  by ±0.5 kg day-to-day; pre-filling with yesterday's value and letting
  the user adjust would cut the tap count significantly.

### 2.9 Goals

**Works.** Active goal card hero treatment matches the mock. The
no-active-goal CTA is friendly. Edit / New goal sheets are consistent
with the rest of the editor patterns.

**Friction.**
- The "Edit current" + "New goal" buttons on the active card are both
  primary-styled, which makes the user pause: "wait, do I edit or do I
  start over?" Make one quiet (outlined) and the other primary. The
  90% case is "edit current"; "new goal" is a deliberate restart.
- The history list lists past goals but doesn't tell me **how I did
  against each one**. A small "achieved" / "ended early" / "still
  active" status pill on each history row would turn the list from
  "list of strings" into "look back at progress."
- The goal rate is in kg/week regardless of `weight_unit` (per the PM
  decision, deliberate). For an lb user, the rate "0.5 kg/week" is
  awkward — they have to mentally convert. Either lift the same
  customer-expected-unit principle to rates (lb/week, st/week) or
  surface a conversion footnote near the rate. The current design
  silently violates the Display Units Principle for one quantity.

### 2.10 Profile

**Works.** Settings card pattern is consistent. Sign-out confirmation
dialog is appropriately scary. Units chooser sheet (joined weight +
height) is a nice solution to a pattern problem.

**Friction.**
- The identity row shows "SS" placeholder avatar and an email that's
  often the dev-auth-bypass value. Once auth lands this will look real;
  in v1 it reads as "this is half-built." Consider rendering "Sign in
  to sync" or similar copy when the user is on the dev token, so the
  state is communicated honestly.
- The "Body" card mixes immutable identity (sex, birth date) with
  highly-mutable measurements (height, current weight, activity). They
  feel like different concepts. Consider splitting into "About you"
  (sex, birth date, height) and "Today" (current weight, activity)
  — the user is more likely to update activity weekly than birth date
  ever.
- The version footnote at the bottom reads "Fulfilled · v0.1.0 (dev)"
  — fine for now, but the "(dev)" tag will linger after release if no
  one threads through the build flavor. Worth grepping for it before
  shipping.

### 2.11 Onboarding

**Works.** Three steps, clear progression, start-over affordance, draft
persistence. The unit pickers on step 2 are correct (locale-aware
defaults). The TDEE estimate on step 3 closes the loop ("here's why we
asked for height + weight").

**Friction.**
- Step 1 is a single full-screen "Get started" hero with no preview of
  what's coming. The user signs up with no idea whether onboarding is
  3 steps or 13. A small "3-step setup" tag near the CTA, or step
  indicators visible from step 1, would set expectations.
- Step 2 collects 5 pieces of information (sex, birth date, height,
  weight, activity) — that's a lot for one screen. Consider whether
  any of them are actually required for v1's TDEE estimate vs.
  optional with a sensible default. (Birth date is one of the harder
  to ask for; some users will balk.)
- Step 3 derives a daily kcal target client-side. If the user is
  borderline between two plausible rates (e.g., 0.25 vs. 0.5 kg/week),
  there's no preview of "you'd eat 1850 kcal vs. 1650 kcal" before
  committing. The preview block is good but a side-by-side comparison
  of two adjacent rates would help the indecisive user pick.
- The "Start over" affordance is correct but lives on every step,
  including step 1 where there's nothing to start over from. Consider
  hiding it on step 1.

### 2.12 My foods

**Works.** Clean list, instant filter, empty-state CTA for first-time
users. Row tap routes to edit mode for user-source foods.

**Friction.**
- No sort options. Recently created first is the right default but a
  long-tenure user wants "most-logged" or "alphabetical." (Backend
  doesn't support this yet — PM `audit_followup_pm.md` deliberately
  punted; flag for v1.1.)
- No bulk operations. Once a user has 50+ customs, "delete all the
  test ones I made" requires 50 individual tap-and-confirms. Worth
  flagging but probably v2.
- The filter is local-only — fast and snappy, but doesn't search
  by brand or barcode. If a user remembers the brand but not the
  custom name, they're stuck. Worth a `barcode || brand || name`
  substring on v1.1.

### 2.13 Barcode scanner

**Works (mobile).** Modern viewfinder overlay, format whitelist,
torch button, permission-denied surface. Detected codes route through
the resolver cleanly.

**Friction.**
- **No scan history.** A user who scans the same barcode three times
  (e.g., they buy the same yogurt every week) goes through the full
  camera dance each time. The `/foods/recent` endpoint already
  surfaces by-food-id; the equivalent for barcodes would skip the
  camera round-trip entirely. Flag this when scan analytics show
  repeat-scans.
- **Web paste-a-barcode** lives only on the search screen and only
  on expanded (`_BarcodeAffordanceRow`). A mobile-web user typing 12
  digits into search gets no affordance. The affordance row gate is
  `if (!context.formFactor.isExpanded) return null;` — consider
  loosening to "compact-web also gets it" since web-on-phone has no
  camera path.

---

## 3. Cross-cutting usability themes

### Theme A — The Today screen has lost its anchor

**Observation.** The compact Today screen has accumulated six top-of-screen
affordances above the ring: avatar, bolt (quick-add), search,
chevron-left, chevron-right, optional TodayPill. Each was justified in
isolation; together they make the header read as a control surface. The
ring — which is the screen's *answer to the user's question* — is no
longer the visual anchor.

**Proposed fix.** Drop the avatar (it's a placeholder until auth, and
profile is reachable from the bottom tab bar). Move the bolt icon into
the FAB's secondary slot (a long-press FAB that exposes "quick add" /
"log food" as a two-up menu), or into the meal section's `_AddFootRow`
as a second affordance. Compress the date chevrons to a tap-to-pick-date
affordance (one tap opens a date picker instead of one tap = one day
back). Net result: the ring appears within the first 80 px of the
viewport on every phone.

**Priority.** P1.

---

### Theme B — Daily-ritual paths are too long

**Observation.** The fastest path to log a food the user ate yesterday
involves: open app → tap search → tap recent chip → tap "Add to log" →
adjust quantity → save. That's 6 taps on a hot path. The mocks didn't
draw this — the QuickChipRow lives inside Search, which means a user
has to *route into* search to see what they ate yesterday.

**Proposed fix.** Promote a "Quick log" chip row to Today on every
breakpoint. On compact, render it between the ring and the meal
sections. Tap a chip → opens LogEntrySheet pre-seeded for that food
with current-meal default. This is the single biggest tap-count win
available without backend changes; it's also where every competitor
puts their "log again" affordance. (See also Functional Gap F1 on
"copy meal".)

**Priority.** P0.

---

### Theme C — Tappable affordances that do nothing

**Observation.** QL-006 / QL-007 cut three (food-detail bookmark, profile
identity edit, profile export). There are at least two more in the
shipped app:
- `food_detail_screen.dart:300` — `more_horiz` overflow icon with
  `onPressed: () {}`.
- `weight_screen.dart:152` + `weight_screen.dart:155` — calendar icon
  and more_horiz icon with `onPressed: null`.
- `weight_screen.dart:300` — "See all" plain text that visually reads
  as a button.

**Proposed fix.** Apply the QL-006 / QL-007 rule consistently:
non-functional UI is worse than missing UI. Delete or wire each. The
"See all" specifically is high-impact for a weight tracker (the
recent-entries list shows ~5 rows; users with months of data want
full history).

**Priority.** P1.

---

### Theme D — Edit/Save flows are visually consistent but conceptually inconsistent

**Observation.** T-24 codified the post-save navigation rule, which fixed
the worst of it. But the *enablement* logic varies sheet-to-sheet:

- LogEntrySheet (edit mode): save disabled until `!_isUnchanged()`.
- CustomFoodScreen (edit mode): save disabled until draft != seed
  snapshot.
- HeightStepperSheet, CurrentWeightSheet: save always enabled (even
  if user changes value and changes it back).
- SexPicker / ActivityLevelPicker: tap-to-save (no separate save
  button).

So a user has three different save-button mental models depending on
which editor they're in. The HeightStepperSheet enabled-when-unchanged
case is the worst — a user who taps Save without changing anything has
the field re-flash without explanation (the no-op PATCH succeeds
silently).

**Proposed fix.** Unify the rule: every editor with an explicit Save
button disables it when the form equals its seed. The tap-to-select
editors (sex, activity) keep their no-button shape — those are clearly
different. Worth a 30-minute audit + a 3-line lint rule.

**Priority.** P2.

---

### Theme E — Loading states are skeletons (good) but error states are noisy

**Observation.** T-08 / T-13 are honored everywhere (no spinners on
populated lists). But the *error path* is inconsistent — most surfaces
fire both a SnackBar AND an inline EmptyState on the same transition.
On a flaky network, this can mean three SnackBars stacked (food detail
+ profile + day summary all error in quick succession), each lasting
3 seconds. The user can't read them, can't dismiss them fast enough,
and the screen looks more broken than it is.

**Proposed fix.** A single global "Connection issues" snackbar with a
retry affordance, debounced to one fire per N seconds, would be more
honest than N per-screen SnackBars. The inline EmptyStates still carry
the per-screen retry CTA (they're the persistent surface). The
SnackBar shim is the transient signal; one is enough.

**Priority.** P2.

---

### Theme F — The medium breakpoint is "phone with padding"

**Observation.** The architecture defines `medium` as 600–1024 px. In
practice, opening the app at 800 px wide renders the compact layout
with extra horizontal space — the right-rail cards don't appear (per
spec), the FAB still floats, the bottom tab bar still shows. An iPad
in portrait is in this band. The mock didn't draw medium, and the
implementation treats it as compact-with-padding. Functionally it
works; experientially it's a missed opportunity.

**Proposed fix.** Either commit to "medium gets a rail-style nav and
the right-rail cards stacked in a horizontal row below the meal grid"
(architect §1's stated intent) or compress the medium → compact
boundary to 720 px so iPad-portrait users get the expanded experience.
The current "medium == compact with breathing room" reads as
unintentional.

**Priority.** P2 (the iPad-portrait user is rare; not a v1 blocker).

---

### Theme G — Discoverability of recent features lags their value

**Observation.** Several recent ships (DATE row in LogEntrySheet,
edit-by-tap, backdating via chevron, the bolt quick-add) are real
wins, but the user has no way to discover them. There's no "What's
new", no onboarding-second-run nudge, no contextual coachmark. The
TodayPill at least surfaces *because* of a backdate; the others are
silent.

**Proposed fix.** Don't ship coachmarks (they age badly), but consider:
- A subtle dot on the bolt icon for the first three opens after a new
  feature lands (e.g., "we added quick add — tap to try").
- A one-line tip below the ring on day 2 ("Tap a logged food to edit
  it") that dismisses on first tap.
- A "What's new" footnote in the profile screen's data card.

**Priority.** P2.

---

## 4. Functional gaps

### F1 — "Copy yesterday's meal" / "Repeat last week's breakfast"

**Who benefits.** Every user past day 3.

**Why now.** The backend endpoint `POST /log/copy` already exists. It
re-snapshots entries from `from_date` to `to_date`, optionally filtered
by `meal`. The client never calls it.

**Proposed shape.** Long-press a meal section header → "Copy from
yesterday" / "Copy from last [meal]". On compact, render as a sheet
with date + meal selectors. Single tap → entries land in the
destination meal with the kcal/macros recomputed from current food
state.

**Fast vs slow.** Fast — the wire is already there. Mostly a sheet UI +
one provider invalidate.

---

### F2 — Surface recent foods on Today (Quick log row)

**Who benefits.** Daily users; cuts taps from 6 to 2 for the most
common log-a-food path.

**Why now.** Recents are already cached client-side
(`recentFoodsProvider`); the right rail on expanded already renders
them. Compact has no equivalent.

**Proposed shape.** A horizontal scroll of 4-6 chip-style recent foods
between the RingSummaryCard and the first meal section on compact. Tap
→ opens LogEntrySheet pre-seeded with the chip's food + current meal.

**Fast vs slow.** Fast. The widget exists (`QuickAddChips` in
`features/today/widgets/quick_add_chips.dart`). It's gated to expanded
form factor; expose it on compact too.

---

### F3 — Show "fits in your day" badge on Food detail

**Who benefits.** Users actively trying to stay under budget; gives them
context before they tap "Add to log".

**Why now.** All inputs are already in client state (day summary +
food nutrition + default serving). No backend work needed.

**Proposed shape.** A small accent-soft badge in `FoodSummaryCard`
reading "Fits in 812 kcal left" (green) or "Would exceed by 23 kcal"
(danger-soft) using the same threshold logic as the calorie ring.

**Fast vs slow.** Fast.

---

### F4 — Weight chart point hover/tap shows the value

**Who benefits.** Anyone reviewing weight trends. The chart is currently
decorative-only.

**Why now.** Standard chart UX; users will assume it's broken otherwise.

**Proposed shape.** On hover (web) / tap-and-hold (mobile), show a
tooltip with the date and weight. A vertical guideline at the touch
point would close the loop.

**Fast vs slow.** Medium — the CustomPainter would need hit-testing.
Pulling in a chart package would conflict with T-19; the painter
approach is correct but takes work.

---

### F5 — Weight log pre-fills with last entered weight

**Who benefits.** Every weight logger. Real-world day-to-day weight
varies by ±0.5 kg; pre-filling makes the stepper a small adjust, not
a full re-entry.

**Why now.** Tap-count win on a near-daily action.

**Proposed shape.** The `LogWeightSheet` initial seed pulls from
`weightHistoryProvider.first.weightKg` if present, otherwise
`user.currentWeightKg`, otherwise a sensible default.

**Fast vs slow.** Fast.

---

### F6 — Water tracking

**Who benefits.** A subset of daily users; water is the most-requested
"non-calorie" tracker across competitors.

**Why now.** Even MyFitnessPal made this table stakes a decade ago. Not
having it is a sticking point in reviews.

**Proposed shape.** A small water row in the Today right rail (web)
and as a third FAB-shaped affordance on compact (long-press FAB →
[log food | quick add | log water]). Stored as a daily count of
servings of a fixed size (e.g., 250 ml).

**Fast vs slow.** Slow — requires a new wire field on `LogEntry` or a
separate `WaterEntry` table. Flag for product decision before
investment.

---

### F7 — Photo of a meal (label-scan or just decoration)

**Who benefits.** Aspirational; users like seeing their food log as a
visual diary.

**Why now.** Low-hanging if the photo is purely decorative (per-entry
URL/blob, no parsing). Becomes a real product if it triggers OCR or
suggested foods.

**Proposed shape.** v1.1: an optional photo on `LogEntry`. v2: ML-
backed "what's in this photo?" search seed.

**Fast vs slow.** Slow. Backend work + storage. Worth scoping
deliberately, not punting reflexively.

---

### F8 — Exercise / calories burned

**Who benefits.** Users who exercise regularly; closes the loop on the
"calories in - calories out" mental model that every fitness app
ships.

**Why now.** The `_BurnedKvRow` widget exists in `ring_summary_card.dart`
already, derived from the user's TDEE. But it's derived, not entered —
the user can't say "I went on a 5K run today, add 350 kcal." That's a
significant gap for an "intermediate" user.

**Proposed shape.** An "Exercise" affordance somewhere (Today FAB
long-press, or a dedicated screen). A simple "[activity name] [duration]
[calories burned]" entry. Subtract from the day's kcal target visibly.

**Fast vs slow.** Slow. Needs backend modeling (`ExerciseEntry`). Worth
flagging now because the `_BurnedKvRow` UI shape already exists — the
real ask is "let me edit this number, not just see the TDEE estimate."

---

### F9 — Saved meals / favorites

**Who benefits.** Users with recurring meal patterns (the "I eat the
same breakfast every weekday" cohort).

**Why now.** QL-006 cut the bookmark icon; the underlying feature was
never built. With copy-meal (F1) shipped, favorites can be deferred
further. But it's the natural v1.1 evolution.

**Proposed shape.** v1.1: a `Food.is_favorite` user-scoped flag.
Surfaces a "Favorites" row on Today / a star-toggle on Food Detail.

**Fast vs slow.** Slow. Wire + UI. Lower-priority than F1 because
copy-meal substitutes for most of the use cases.

---

### F10 — Streak / weekly progress on Today

**Who benefits.** Users motivated by gamification; a small visible
"week so far" feedback loop turns daily logging into a habit.

**Why now.** Pulling users back to the app the next day is the single
biggest retention lever any tracker has. The current Today screen has
no day-over-day continuity surface.

**Proposed shape.** A small "5-day streak" or "this week: 4/7 days
logged" pill near the ring. No celebratory animation, no fire emoji —
just a small honest counter.

**Fast vs slow.** Medium. Requires a backend "logging streak" query
or a client-side aggregation over the day-summary provider.

---

## 5. Accessibility findings

**Solid.**
- Tap targets ≥ 44 px on mobile across audited surfaces (T-06).
- Semantics labels with rendered numbers on most numeric widgets
  ("130 kilocalories"). The `LogEntry` row composes a single merged
  label that screen readers announce as one unit (T-20).
- Reduce-motion respected via the `motion()` helper for the pending-sync
  pulse, the dialog enter animation, and the ring color flip.
- Color is never the sole signal — over-budget macros append " (over by
  N g)" to their semantic label.

**Gaps.**
- The `_TopSearchField` on Today expanded is a `Tooltip` + `InkWell`
  with no `Semantics(button: true, label: ...)`. Screen readers will
  announce it as "Search foods (⌘K)" because of the tooltip, but the
  role won't read as button. Add an explicit Semantics wrapper.
- The compact day-view date bar reads as separate Semantics nodes for
  "Today" / "Thursday, May 16" / chevrons / pill. A screen reader user
  navigating the page hears five focusable nodes for one logical
  control. Consider merging the title + sub-line into a single Semantics
  region (or wrapping the entire date bar in a `MergeSemantics`).
- The Today bolt + search icons have tooltips but the bolt's tooltip
  says "Quick add calories" while the screen reader announcement
  doesn't disambiguate from any other "quick add" affordance. Worth a
  contextual semantics label like "Quick add calories button, opens
  sheet".
- Focus order on web is mostly correct but on the LogEntrySheet, the
  serving select opens a *second* modal that traps focus inadvertently
  when tabbed past — the modal's first focusable element should be the
  first option, not the back button. Standard Material behavior here
  but worth a quick test.
- The CalorieRing's center label is a single Semantics node combining
  the number + caption ("812 kcal left"). Good. But the macro bars
  below are three independent labels — a user has to navigate through
  all three to hear the day's macro snapshot. A single
  `MergeSemantics` wrapper would let the screen reader announce
  "protein 33 of 130 grams, carbs 14 of 200 grams, fat 6 of 60 grams"
  as one statement.
- The pending-sync badge is `ExcludeSemantics`'d (correct — the row's
  merged label carries the suffix), but the post-flush fade has no
  semantic announcement. A user who logged offline doesn't get a
  screen-reader confirmation when their entry syncs. Consider a
  `LiveRegion` announcement when the badge fades out.

---

## 6. Onboarding-to-day-2 narrative

A hypothetical user, call her Maya, opens the app for the first time at
8:13 AM on a Tuesday in Boston. She's 34, US, mostly tracked food in a
spreadsheet for the last year, decided to give a real tracker another
try.

**Sign-up → step 1.** She lands on a centered welcome screen. The
single "Get started" CTA is honest — no fake "I already have an
account" link, no decorative skip. She taps it. No expectations were
set about how long the next steps will take.

**Step 2.** A form: sex, birth date, height, weight, activity. The
sex segmented control is clear. The birth date picker uses Material's
default — fine but the dialog is heavy for what should be three taps.
Height: she's US, the segmented control pre-selected "ft + in" because
of locale. She enters 5 ft 6 in. Weight: she enters 142 lb. Activity:
the radio list is dense but readable; she picks "Lightly active."
She taps Continue.

**Step 3.** "Set a goal" — three goal-direction options (lose / maintain
/ gain). She picks lose. A rate slider appears. She moves it to 0.5
kg/week — wait, *kg*? She's been using lb everywhere else. There's a
preview block ("Daily target: 1640 kcal · P 130 g · C 200 g · F 55 g")
which lands the math. But the rate-in-kg violates the customer-expected
unit principle for her — and the PM doc deliberately punted on this.
She accepts it because she has to.

**Finish → Today.** She lands on Today with zero entries and an empty-day
pill saying "No food logged for this day · Log a food." The calorie ring
shows "1640 left." The pill is genuinely friendly. She taps "Log a
food," which routes her to Search. Search autofocuses; she types
"oatmeal." Results appear; she taps the first OFF result. Food detail
opens. She taps "Add to log." The sheet pops; she adjusts quantity (the
chip "1.5×" mirrors the stepper). She taps Save. The sheet closes, she
lands on Today with her oatmeal under Breakfast.

**Friction noticed in step 1 walk.**
1. Six taps to log her first food (search → search field already
   focused → type → result → add to log → save). Three of those are
   wasteful — the search route is a route push when on Today she could
   have a chip row of common foods.
2. The kg/lb rate mismatch on step 3 is a niggle.
3. Nothing in the flow told her she could backdate. She'll discover
   this only when she misses logging dinner and chevrons backward.

**Day 2, 7:55 AM.** Maya opens the app expecting to see yesterday's
log. She does — Today defaults to today's date. She immediately wants
to log breakfast, which is the same oatmeal as yesterday. She taps the
search icon. The Recent chip row shows "Quaker Oatmeal" first. She
taps it. Sheet opens with the previous serving + quantity (good — the
defaults persist). She taps Save.

**Friction on day 2.** Six taps to log a food she ate yesterday. A
"Copy yesterday's breakfast" affordance would have made this two taps
(open app, tap "repeat breakfast"). The Recent chip on the Today
screen would have made it three (open app, tap chip, tap save).
**This is the difference between "I'll keep using this" and "I'll
forget about this app in two weeks."** Maya is doing the same six
taps she did yesterday. Day 14 looks identical to day 1.

**Day 7.** Maya weighs in: 141.2 lb. She taps the Weight tab,
taps the FAB "Log weight." The stepper opens. It seeds her last
weight? No — it seeds a default. She has to type 141.2 from scratch.
Small friction; she keeps going. She glances at the sparkline. Two
points so far, both showing as dots. She wants to tap one to see the
date — nothing happens. She moves on.

**Day 14.** Maya's done this fourteen times. She has 30 log entries
spread across breakfasts, lunches, and dinners. The app does what she
asked it to. It doesn't do anything *more*. There's no week-over-week
summary, no "you're tracking 5 days a week," no "your protein average
is 110 g/day, up from 95 last week." The Trends tab was deliberately
hidden in v1 (PM Risk 3) — but the gap is real, and it's where the
habit either solidifies or doesn't.

**Where the app loses her, if it does.** Not at sign-up. Not at the
first log. At day 7-14, when she realizes the ritual is just as
expensive as it was at day 1.

---

## 7. What you'd ship next (top 5)

In priority order, independent of effort. Pick from the top down.

1. **F1 — Copy yesterday's meal / day.** Backend already exists. Biggest
   day-14 retention lever. Single sheet + one provider invalidate.
2. **F2 — Recent-foods chip row on compact Today.** Cuts the daily-log
   tap count from 6 to 3. The widget exists for expanded; expose it on
   compact.
3. **Theme A — Compress the Today compact header.** Move the avatar
   off, fold the bolt into the FAB's secondary slot or into the meal
   section's "Add food" footer. Reclaim ring real estate.
4. **F4 + F5 — Weight scrub-to-read and Log Weight pre-fill.** Two
   small wins on a daily action. Together they make weight feel like a
   first-class tracker, not a sparkline.
5. **F10 — Tiny streak/week-counter pill near the ring.** Cheapest
   single-tap-of-retention lever in the app. Even a static "Logged
   today" / "5-day streak" is better than nothing.

---

## 8. Anti-recommendations (things NOT to do)

1. **Don't add a coachmark / first-run tour.** They age badly, they
   block the first-meaningful-action, and they imply we don't trust
   our own affordances. The empty-day pill is the right model:
   contextual nudges that disappear when no longer needed. If a
   feature is too hard to find without a coachmark, fix the
   affordance, not the coachmark.

2. **Don't ship a Trends tab "lite" to fill the gap.** PM Risk 3 was
   right — a stub Trends tab implies analytics surfaces we don't have
   and disappoints. A real Trends screen is a design exercise that's
   worth waiting for. In the meantime, the streak pill (F10) is the
   minimum viable retention surface; that's enough.

3. **Don't fold the QuickAdd into the regular LogEntrySheet.** It's
   tempting — "why have two sheets when one could handle both?" — but
   the cognitive load is different. The LogEntrySheet's "search for a
   food first" precondition is genuinely separable from QuickAdd's
   "just give me a number" intent. Two sheets, two clear use cases.
   Merging them would gain consistency and lose clarity.
