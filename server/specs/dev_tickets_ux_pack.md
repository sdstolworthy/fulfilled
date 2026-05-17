# Developer Tickets — UX Pack (cheaper ritual + visible signal)

Source of truth for the post-QoL UX pack. Every ticket below is sized
for a single developer agent to pick up, finish, and review in one
session (1–4 focused hours; ~10–25 agent-minutes per ticket). Agents
do **not** have a Flutter SDK — they write tests to disk
inspection-correct, but they do **not** run `flutter test` or
`flutter analyze`. Inspect for typos; assume CI gates run on a host
machine later.

**Read order**:

1. This file (you are here).
2. `specs/pm_ux_pack.md` — the PM's *what* and *why* across F1, F2,
   F4, F5, F10, Theme A, and the cross-cutting refinements.
3. `specs/architect_ux_pack.md` — the architect's *how*: file-level
   seams, the three-PR split for Theme A (§6.5), the `copyDay`
   repository contract (§3.2), the `QuickAddChips` compact-mode flag
   (§4.2), the F10 `weeklyLogDaysProvider` shape (§7.2), and the six
   open questions in §12.
4. `specs/flutter_ui_architecture.md` — the 24 tenants. Cited by ID.
   T-12 (FAB), T-14 (routes vs sheets), T-15 (form-factor at root),
   T-18 (minimal invalidation), T-19 (no chart deps), T-20 (a11y),
   T-21 (display units), T-23 (lifted-widget package imports), T-24
   (post-mutation navigation) are the load-bearing ones in this pack.
5. `specs/pm_decisions_flutter_ui.md` — Display Units Principle.
6. `specs/dev_tickets.md`, `specs/dev_tickets_log_edit_and_units.md`,
   `specs/dev_tickets_barcode.md`, `specs/dev_tickets_qol.md` — prior
   ticket shapes. Same conventions; same Owns-files discipline.

Tickets reference these docs by section/ID instead of re-quoting them.

**Numbering note.** Prior packs used `T-`, `LU-`, `SC-`, `QL-`, `BE-`
prefixes. To avoid ID collision this pack prefixes its tickets
`UX-101 … UX-1NN`. The PM pack's letter codes (F1, F2, F4, F5, F10,
Theme A, Theme C, Theme D, Theme E) and the architect's PR numbers
(PR 1 … PR 8) map to UX-1NN via the "Per-item map" table near the end
of this doc.

**Branch model**: dispatch on top of `main` at the head of the QL
pool plus any `UX-1NN` commits that landed first. Each ticket lists
`Owns files:` — an agent must not touch any file outside that list
without flagging in the ticket Notes. If two tickets share a file in
their `Owns files:` list, the dependency graph below sequences them.

**Ticket status legend**:

- `pending` — not started.
- `pending (backend)` — assigned to the backend team; the Flutter
  pool does not pick this up.
- `pending-pm` — surfaced as v1.1 by the architect or PMgr; not
  blocking and not in this pack's scope.
- `in-progress` — claimed by an agent; uncommitted work-in-progress.
- `done` — committed to `main`; agent has updated this doc.
- `blocked-needs-pm` — agent gave up; see failure protocol at the
  bottom.

---

## UX-101  Lift `QuickAddChips` to `lib/widgets/` (T-23)

**Status**: pending
**Priority**: P0
**Effort**: S
**Depends on**: none
**Owns files**:
- `client/lib/widgets/quick_add_chips.dart` (new — verbatim move of
  the feature-local file with adjusted relative imports)
- `client/lib/features/today/widgets/quick_add_chips.dart` (delete)
- `client/lib/features/today/day_view_expanded.dart` (one import-line
  swap from `widgets/quick_add_chips.dart` to
  `package:fulfilled/widgets/quick_add_chips.dart`)
- `client/test/widgets/quick_add_chips_test.dart` (new location —
  move from `client/test/features/today/quick_add_chips_test.dart`
  if present; same content, adjusted import)
- `client/test/features/today/quick_add_chips_test.dart` (delete if
  present)
- `specs/flutter_ui_architecture.md` (§3 inventory row for
  `QuickChipRow` — extend the "Used by" column to anticipate the F2
  compact consumer landing in UX-107; do not rename
  `QuickAddChips → QuickChipRow` per architect §2.2)

### Goal
Lift the existing `QuickAddChips` widget from
`lib/features/today/widgets/` to the canonical `lib/widgets/`
location so F2's compact mount (UX-107) is a purely additive change.
The widget contract — constructor, fields, render — is unchanged;
this is a pure file move with relative-import adjustments. After this
ticket, both the today-expanded right rail (already consumes) and
the future today-compact strip (UX-107 adds the second consumer)
import from a single canonical path, per T-23.

### Context
Architect §2 (Refactor 1 in full — the lift rationale in §2.1, the
file moves in §2.2, the acceptance criteria in §2.3). PM doc §2 F2
"Lift `QuickAddChips` to `lib/widgets/`". Tenants: **T-23** (shared
widgets are package-imported — the lift is the rule-enforcement),
**T-15** (form-factor branches at the screen root — the widget body
stays the same; the lift doesn't introduce a compact branch, that
lands in UX-107 / §4.2).

### Scope
- [ ] `git mv client/lib/features/today/widgets/quick_add_chips.dart
      client/lib/widgets/quick_add_chips.dart` (or the equivalent
      delete + create — the diff shape matters less than the
      destination contents).
- [ ] Adjust the new file's relative imports: `../../../domain/...`,
      `../../../routing/...`, `../../../theme/...`,
      `../../../widgets/...` collapse to `../domain/...`,
      `../routing/...`, `../theme/...`, `../widgets/...` respectively.
      Verify each import resolves to a real file.
- [ ] In `day_view_expanded.dart`, swap the import:
      ```dart
      // Before:
      import 'widgets/quick_add_chips.dart';
      // After:
      import 'package:fulfilled/widgets/quick_add_chips.dart';
      ```
      `grep -rn 'features/today/widgets/quick_add_chips' client/lib/
      client/test/` must return zero hits after this ticket.
- [ ] Move any existing widget test from
      `client/test/features/today/quick_add_chips_test.dart` to
      `client/test/widgets/quick_add_chips_test.dart`. Update its
      import of the widget to the new package path.
- [ ] In `specs/flutter_ui_architecture.md` §3, the inventory row for
      `QuickChipRow` (currently line ~153) — extend the "Used by"
      column to anticipate the F2 compact consumer:
      `"01 compact (between ring + meals — F2), 01-W (right rail), 02 (mobile)"`.
      No other shape change.

### Out of scope
- Adding the `compact` flag to `QuickAddChips` — that lives in
  UX-107.
- Renaming `QuickAddChips → QuickChipRow` (the inventory's name) —
  architect §2.2 explicitly defers this to a v1.1 spec-vs-code
  reconciliation sweep.
- Adding `frequents` ordering tweaks, chip cap changes, or any other
  rendering refinement. The widget's public API is byte-identical
  after the lift modulo imports.

### Acceptance criteria
- [ ] `client/lib/widgets/quick_add_chips.dart` exists and is a
      verbatim copy of the old feature-local file modulo import
      paths.
- [ ] `client/lib/features/today/widgets/quick_add_chips.dart` does
      not exist.
- [ ] `day_view_expanded.dart`'s import is
      `package:fulfilled/widgets/quick_add_chips.dart`.
- [ ] `grep -rn "features/today/widgets/quick_add_chips" client/lib/
      client/test/` returns zero hits.
- [ ] The widget's public API (constructor, props, render) is
      unchanged. No new fields, no new defaults, no new branches.
- [ ] Tenants honored: T-23.

### Tests
- The existing `quick_add_chips_test.dart` (if any) is moved to
  `client/test/widgets/quick_add_chips_test.dart` and its import of
  the widget updates to the new package path. No new test cases are
  added in this ticket.

### Notes / gotchas
- Architect §2.2 names this as the canonical-import shape for §3
  inventory widgets: same shape as `meal_section.dart`,
  `ring_summary_card.dart`, `empty_state.dart`. Reviewable by
  `grep -rn "package:fulfilled/widgets/" client/lib/features/today/`
  — there should be at least one hit after the ticket lands.
- The expanded right-rail mount site is the only current consumer.
  Verified by `grep -rn "features/today/widgets/quick_add_chips"
  client/lib` returning one hit before the ticket starts.
- This is a pure refactor; visual regression on Today expanded
  should be zero. If a reviewer reports a visual change, the
  relative-import adjustment introduced a typo — recheck the import
  chain.

---

## UX-102  Theme A PR 2 — avatar cut + bolt → FAB long-press menu

**Status**: pending
**Priority**: P0
**Effort**: M
**Depends on**: none
**Owns files**:
- `client/lib/features/today/day_view_compact.dart` (delete the
  avatar `Container` from `_CompactHeader`; delete the bolt
  `IconButton36` from `_CompactHeader`; wire `LogFoodFab`'s new
  `onQuickAdd` parameter; the `_DateBar` block is unchanged in this
  ticket — chevron-merge lives in UX-104)
- `client/lib/features/today/widgets/log_food_fab.dart` (add
  `onQuickAdd: VoidCallback` parameter; wrap the existing
  `FloatingActionButton.extended` in a `GestureDetector(onLongPress:
  ...)` that opens a `showMenu`-style popup with two items)
- `client/test/features/today/header_compression_test.dart` (new —
  asserts the ring's `globalKey` paints within 320 vertical px of the
  safe-area top on a 393×851 reference viewport; asserts the avatar
  and bolt are absent from the tree)
- `client/test/features/today/log_food_fab_long_press_test.dart`
  (new — asserts long-press opens the two-item menu; asserts short
  press still routes to the original `onPressed`; asserts selecting
  "Quick add calories" invokes `onQuickAdd`)

### Goal
Re-anchor the compact Today header by removing the placeholder
avatar and folding the bolt (quick-add) icon into the FAB's secondary
slot via a long-press menu. After this ticket the compact header
row goes from `[avatar | bolt | search]` to `[search]`; the FAB
exposes "Log food" on short-press (unchanged) and "Quick add
calories" on long-press. The chevron-merge and swipe-day gesture
live in UX-103 / UX-104; this ticket ships the two cuts plus the FAB
long-press wiring as PR 2 of the three-part Theme A split.

### Context
Architect §6.1 (drop the avatar), §6.2 (FAB long-press menu — the
`showMenu`-style popup, the T-12 reading in §10.1), §6.6 PR 2
acceptance criteria. PM doc §2 Theme A ("CUT / MOVE / KEEP / MERGE"
list) and the §6 a11y note about the bolt tooltip becoming N/A
because the bolt itself is removed. Tenants: **T-12** (the FAB is
the only floating action — architect §10.1 confirms the long-press
menu stays inside T-12 under the strict reading because `showMenu`
is a route-modal not a floating widget; UX-113 ships the optional
clarifying rider), **T-20** (Semantics on each menu item).

### Scope
- [ ] In `_CompactHeader`:
      - Delete the avatar `Container` block (the 36×36 SS-initials
        circle at `day_view_compact.dart:~120`). No replacement
        text-avatar, no "Sign in" link, no fallback widget.
      - Delete the bolt `IconButton36(icon: Icons.bolt_outlined,
        ...)` block (at `day_view_compact.dart:~160`). The bolt's
        `onPressed` handler — `() => showQuickAddSheet(context)` —
        moves to `LogFoodFab`'s `onQuickAdd` parameter.
      - The `Row` resolves to `Row(mainAxisAlignment:
        MainAxisAlignment.end, children: [searchIconButton])`. One
        child: the search `IconButton36`. Remove the now-unused
        `Spacer` if any.
- [ ] In `log_food_fab.dart`:
      - Add `required VoidCallback onQuickAdd` to the constructor.
      - Wrap the existing `FloatingActionButton.extended` in a
        `GestureDetector(onLongPress: () => _showLongPressMenu(...))`
        with `behavior: HitTestBehavior.opaque` so the long-press
        registers on the FAB surface (not the underlying scaffold).
      - Implement `_showLongPressMenu` as a private method that
        opens `showMenu<_FabAction>` anchored above the FAB. Items:
        ```dart
        const PopupMenuItem(
          value: _FabAction.logFood,
          child: Row(children: [
            Icon(Icons.add),
            SizedBox(width: 12),
            Text('Log food'),
          ]),
        ),
        const PopupMenuItem(
          value: _FabAction.quickAdd,
          child: Row(children: [
            Icon(Icons.bolt_outlined),
            SizedBox(width: 12),
            Text('Quick add calories'),
          ]),
        ),
        ```
      - On `_FabAction.logFood` selection: invoke `onPressed`
        (the existing short-press handler).
      - On `_FabAction.quickAdd` selection: invoke `onQuickAdd`.
      - Add a file-private `enum _FabAction { logFood, quickAdd }`.
- [ ] `day_view_compact.dart` passes `onQuickAdd: () =>
      showQuickAddSheet(context)` to the `LogFoodFab` constructor.
      The short-press `onPressed: () =>
      context.push(Routes.foodsSearchPath)` is unchanged.
- [ ] A11y: each `PopupMenuItem`'s `child` Row already carries the
      visible Text; verify `Semantics(label: 'Log food')` and
      `Semantics(label: 'Quick add calories')` are read by VoiceOver
      via Flutter's default Material a11y plumbing. If they are not
      (the `PopupMenuItem` swallows the child Row's Semantics), wrap
      each `Text` in `Semantics(label: ..., child: ...)`.

### Out of scope
- The chevron-merge (`DatePill` + chevron removal). Lives in
  UX-104; gated on UX-103's swipe gesture.
- The swipe-day gesture. Lives in UX-103.
- The streak pill (`_WeekProgressPill`). Lives in UX-110.
- The F2 chip strip. Lives in UX-107.
- Any change to `QuickAddSheet` itself — this ticket only rewires
  the entry point.

### Acceptance criteria
- [ ] `_CompactHeader` no longer renders an avatar (the avatar's
      `Container` is gone; no fallback rendered in its place).
- [ ] `_CompactHeader` no longer renders the bolt `IconButton36`. The
      search `IconButton36` stays.
- [ ] `LogFoodFab` gains `onQuickAdd: VoidCallback` (required). The
      widget wraps the FAB in a `GestureDetector(onLongPress: ...)`
      that opens a `showMenu` with two items (Log food, Quick add
      calories).
- [ ] Short-press on the FAB still routes to `onPressed` (the
      original behaviour: open `/foods/search`).
- [ ] Long-press + selecting "Quick add calories" invokes
      `onQuickAdd`, which in `day_view_compact.dart` opens
      `showQuickAddSheet(context)`.
- [ ] Long-press + selecting "Log food" invokes the same handler as
      short-press (the existing `onPressed`).
- [ ] On a Pixel 4a reference viewport (393×851), the
      `RingSummaryCard`'s `globalKey.currentContext`'s render-box
      top is ≤ 320 px from the safe-area top. (This ticket's avatar
      cut alone moves the ring up by ~36 px; the additional ~24 px
      from UX-104's chevron-merge is needed to fully land within
      280 px, which is the PM doc §2 Theme A AC target. This
      ticket's target is the 320 px ceiling.)
- [ ] A11y: each `PopupMenuItem` carries a Semantics label matching
      its visible text. T-20 honoured.
- [ ] Tenants honored: T-12 (architect §10.1 reading), T-20.

### Tests
- `client/test/features/today/header_compression_test.dart`:
  - `compact header has no avatar` — pump `DayViewCompact`, assert
    `find.byKey(const Key('compact-header-avatar'))` returns zero
    widgets. (The avatar block has a `Key` today; the test asserts
    the key is gone post-cut.)
  - `compact header has no bolt icon` — assert
    `find.byIcon(Icons.bolt_outlined)` is zero inside the
    `_CompactHeader` subtree.
  - `ring lands within 320 px of safe-area top on Pixel 4a viewport`
    — use `tester.binding.window` overrides to set viewport size;
    pump `DayViewCompact(date: today)`; read the `RingSummaryCard`'s
    `globalKey.currentContext.findRenderObject().localToGlobal(...)`.
- `client/test/features/today/log_food_fab_long_press_test.dart`:
  - `short press routes through onPressed` — pump `LogFoodFab(
    onPressed: spyA, onQuickAdd: spyB)`, tap the FAB, assert
    `spyA.called && !spyB.called`.
  - `long press + Log food routes through onPressed` — pump,
    long-press the FAB, tap the "Log food" item, assert
    `spyA.called && !spyB.called`.
  - `long press + Quick add calories routes through onQuickAdd` —
    pump, long-press, tap "Quick add calories", assert
    `spyB.called && !spyA.called`.

### Notes / gotchas
- Architect §10.1 names two readings of T-12 against the FAB
  long-press menu. **Reading 1 (strict)**: the menu is a route-modal
  not a floating widget; the FAB stays the only floating action.
  Reading 1 is the one this ticket ships under; UX-113 ships the
  optional clarifying rider that bakes the precedent into the
  tenant's wording. If UX-113 is declined, the menu still ships
  under Reading 1 and the next reader treats this ticket as the
  precedent.
- The `showMenu` `position: RelativeRect.fromLTRB(...)` anchors the
  popup above the FAB; tune the offsets so the menu doesn't clip on
  smaller viewports. Architect §6.2 names `(overlay.width - 220,
  overlay.height - 200, 24, 24)` as a starting point — adjust if
  the menu clips on the Pixel 4a viewport.
- Do not change the FAB's icon, label, or short-press behaviour.
  Users have learned the short-press over the prior 30 days; this
  ticket adds a secondary path, not a replacement.
- The `_CompactHeader`'s vertical padding (`space.x1 + 2` top,
  `space.x3` bottom) stays unchanged. The header's height shrinks
  naturally because the avatar's 36 px circle is removed; no padding
  adjustment is needed.

---

## UX-103  Theme A PR 3 — `DaySwipeWrap` horizontal swipe gesture

**Status**: pending
**Priority**: P1
**Effort**: M
**Depends on**: none
**Owns files**:
- `client/lib/features/today/today_internals.dart` (add
  `DaySwipeWrap` widget; alternatively a new
  `widgets/day_swipe_wrap.dart` if the agent prefers a separate
  file in the same feature folder — note in the PR if so)
- `client/lib/features/today/day_view_compact.dart` (wrap the
  `CustomScrollView` in `DaySwipeWrap(date: date, child:
  CustomScrollView(...))`; no other behavioural change)
- `client/test/features/today/day_swipe_gesture_test.dart` (new —
  four tests covering left swipe, right swipe, below-threshold
  swipe, vertical drag pass-through)

### Goal
Land the horizontal-swipe gesture that lets the user navigate
between days without using the chevrons. Left swipe routes to the
next day; right swipe routes to the previous day. The gesture
short-circuits when velocity is below ~200 px/s so a casual scroll
attempt doesn't accidentally change the day. Vertical drags pass
through to the inner `CustomScrollView` so the page still scrolls
normally. This ticket lands the gesture as a standalone PR (PR 3 of
the Theme A split) so the chevron-merge in UX-104 has a working
non-chevron per-day affordance to gate on.

### Context
Architect §6.4 (the swipe shape, thresholds, `HitTestBehavior.translucent`
reasoning), §6.5 (the two-ticket-vs-one-ticket call — Option B, this
is PR 3), §6.6 PR 3 acceptance criteria. PM doc §2 Theme A
("swipe-left / swipe-right gestures on the day view (which already
exist per the architect's compact transform) carry the per-day
navigation"). Tenants: **T-12** (no floating affordances — the
gesture is invisible chrome on the existing scroll surface), **T-15**
(the wrap mounts inside the screen root, not a leaf).

### Scope
- [ ] In `today_internals.dart`, add `DaySwipeWrap` per architect
      §6.4:
      ```dart
      class DaySwipeWrap extends StatelessWidget {
        const DaySwipeWrap({
          required this.date,
          required this.child,
          super.key,
        });

        final DateTime date;
        final Widget child;

        static const double _velocityPxPerSec = 200;

        @override
        Widget build(BuildContext context) {
          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragEnd: (d) {
              final velocity = d.primaryVelocity ?? 0;
              if (velocity.abs() < _velocityPxPerSec) return;
              if (velocity < 0) {
                navigateDay(context, date, 1);
              } else {
                navigateDay(context, date, -1);
              }
            },
            child: child,
          );
        }
      }
      ```
      `navigateDay(context, date, ±1)` is the existing helper used
      by the chevron `IconButton36`s; reuse it verbatim. If it
      doesn't exist (it should — the chevrons need it), inline its
      shape: `context.go(pathForDay(date.add(Duration(days: ±1))))`.
- [ ] In `day_view_compact.dart`, wrap the body's `CustomScrollView`:
      ```dart
      body: DaySwipeWrap(
        date: date,
        child: CustomScrollView(slivers: ...),
      ),
      ```
- [ ] Do not change the chevron `IconButton36`s' onPressed handlers
      in this ticket. The chevrons stay; UX-104 removes them.
- [ ] `HitTestBehavior.translucent`: vertical drags inside the
      `DaySwipeWrap` bounds pass through to the inner scroll view.
      The test surface (Tests below) confirms this — the
      `ScrollController.offset` changes when the test fires a
      vertical drag.

### Out of scope
- Removing the chevron `IconButton36`s from `_DateBar` — that's
  UX-104.
- Wiring `DatePill` (the tappable date title) — that's UX-104.
- Animating the day transition. `context.go` uses the router's
  built-in motion which honours `MediaQuery.disableAnimations`
  already; no new animation introduced here.
- Adding a swipe-day gesture to expanded. Expanded uses
  multi-column layout; swipe is compact-only.
- A swipe gesture inside any sheet/dialog. Sheets have their own
  drag-to-dismiss gesture; this ticket only wraps the day view's
  body.

### Acceptance criteria
- [ ] `DaySwipeWrap` widget exists at
      `client/lib/features/today/today_internals.dart` (or a new
      `widgets/day_swipe_wrap.dart` in the same feature folder —
      agent's choice).
- [ ] The widget uses `GestureDetector` with
      `HitTestBehavior.translucent` and
      `onHorizontalDragEnd`. Vertical drags pass through.
- [ ] On a horizontal-drag-end with `|primaryVelocity| > 200 px/s`:
      left (negative velocity) → next day; right (positive velocity)
      → previous day. Below-threshold drags are no-ops.
- [ ] `day_view_compact.dart`'s body wraps the existing
      `CustomScrollView` in `DaySwipeWrap(date: date, child: ...)`.
- [ ] The chevron `IconButton36`s in `_DateBar` are unchanged
      (their removal lives in UX-104).
- [ ] Tenants honored: T-12 (gesture is invisible chrome), T-15
      (wrap at the screen root).

### Tests
- `client/test/features/today/day_swipe_gesture_test.dart`:
  - `left fling routes to next day` — pump `DayViewCompact(date:
    DateTime(2026, 5, 15))`; `tester.fling(find.byType(DaySwipeWrap),
    const Offset(-200, 0), 400)`; pump and settle; assert the router
    is at `/today/2026-05-16`.
  - `right fling routes to previous day` — same setup; fling
    `const Offset(200, 0), 400`; assert the router is at
    `/today/2026-05-14`.
  - `below-threshold drag is a no-op` — fling
    `const Offset(-20, 0), 50` (well below the 200 px/s floor);
    assert the router is still at `/today/2026-05-15`.
  - `vertical drag passes through to parent scroll` — pump with a
    seeded `daySummaryProvider` so the body has enough content to
    scroll; `tester.drag(find.byType(DaySwipeWrap), const Offset(0,
    -100))`; pump; assert the inner `ScrollController.offset > 0`.

### Notes / gotchas
- Architect §6.4 notes that the 50 px total-displacement threshold
  is "implicit in the 200 px/s × 0.25 s typical drag duration." Do
  not add a separate displacement guard — `primaryVelocity` alone
  is the heuristic. If the agent finds the threshold too sensitive
  in manual testing, raise the px/s floor; don't add a second
  guard.
- The `navigateDay` helper is the same one the chevron
  `IconButton36`s call. If it doesn't exist, inline its body
  (`context.go(pathForDay(date.add(Duration(days: delta))))`); do
  not invent a new helper in this ticket.
- `HitTestBehavior.translucent` is load-bearing. `opaque` would
  swallow vertical drags. Verify the vertical-drag test before
  closing the PR.
- The gesture wrap doesn't animate the day transition. The router's
  page transition (a fade or slide depending on `GoRouter` config)
  is the only motion; no `AnimatedSwitcher` or custom transition is
  added here.

---

## UX-104  Theme A PR 4 — `DatePill` + chevron removal

**Status**: pending
**Priority**: P1
**Effort**: S
**Depends on**: UX-103
**Owns files**:
- `client/lib/features/today/today_internals.dart` (add `DatePill`
  widget — public, since it's only used by the compact day view but
  shipped as a named class for testability)
- `client/lib/features/today/day_view_compact.dart` (in `_DateBar`:
  delete the two chevron `IconButton36`s; replace the title
  `Column` with `DatePill(date: date)`; the `TodayPill` continues to
  render conditionally to the right)
- `client/test/features/today/date_pill_test.dart` (new — tap opens
  date picker bounded to [today-60, today]; picker return routes via
  `pathForDay(picked)`; Semantics is a single button node)

### Goal
Collapse the date title block + the two chevron `IconButton36`s
into a single tappable `DatePill` widget. After this ticket
`_DateBar` renders `[DatePill] [optional TodayPill]`. Tapping the
pill opens a date picker bounded to `[today - 60 days, today]`. The
swipe-day gesture (UX-103) carries the per-day navigation; the
chevrons are gone. The five-focusable-nodes-for-one-control finding
from the UX review's Accessibility section is resolved by the
single Semantics node on `DatePill`.

### Context
Architect §6.3 (`DatePill` shape, the 60-day floor matching QL-009),
§6.5 (the two-ticket split — this is PR 4), §6.6 PR 4 acceptance
criteria. PM doc §2 Theme A ("Date chevron pair — MERGE" + the
gating clause: "If the swipe gesture is not yet implemented in the
codebase, this acceptance criterion **gates on** the architect's
swipe-gesture ticket"). Tenants: **T-20** (single Semantics node
where there were three), **T-06** (the pill's tap target is the
full title block; ≥ 44 px tall).

### Scope
- [ ] In `today_internals.dart`, add `DatePill` per architect §6.3:
      a `StatelessWidget` whose `build` returns a `Semantics(button:
      true, label: '$headline, $subline, open date picker',
      excludeSemantics: true, child: Material(color:
      Colors.transparent, child: InkWell(onTap: ..., child: Padding(...
      Column(eyebrow, sub-line)))))`. The eyebrow and sub-line read
      from the existing `todayHeadline(date)` and `todaySubline(date)`
      helpers.
- [ ] The `onTap` opens `showDatePicker(context: context, initialDate:
      date, firstDate: DateTime.now().subtract(const Duration(days:
      60)), lastDate: DateTime.now())`. On non-null return,
      `context.go(pathForDay(picked))`. The 60-day floor matches
      QL-009's TodayPill range — architect §3.4 (C) for the
      `CopyDaySheet` floor cross-references this; symmetry.
- [ ] In `_DateBar`:
      - Delete the two chevron `IconButton36`s (the `Icons.chevron_left`
        and `Icons.chevron_right` blocks).
      - Replace the title `Column` (the eyebrow `Text("Today")` +
        sub-line `Text("Thursday, May 14")`) with `DatePill(date:
        date)`.
      - The post-ticket `_DateBar` shape:
        ```dart
        Padding(
          padding: EdgeInsets.fromLTRB(
            context.space.x5, 0, context.space.x5, context.space.x2,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: DatePill(date: date)),
              if (!isLocalNowDay(date)) const TodayPill(),
            ],
          ),
        )
        ```
- [ ] The `TodayPill` continues to render to the right of the
      `DatePill` only when `date != local-now` (QL-009 behaviour
      unchanged).
- [ ] A11y: `DatePill`'s Semantics is `Semantics(container: true,
      button: true, excludeSemantics: true, label: 'Today, Thursday
      May 14, open date picker')`. The `excludeSemantics: true`
      collapses the inner eyebrow + sub-line Text Semantics into the
      single parent — three nodes → one.

### Out of scope
- The `DaySwipeWrap` gesture — lands in UX-103. If UX-103 is not yet
  in main when this ticket is picked up, the PR description must
  flag that the chevrons should remain until UX-103 lands. Per the
  PM doc gate, **do not ship the chevron removal ahead of the
  swipe**.
- A "Today" quick-return button. The user navigates back via the
  existing `TodayPill` (which renders on backdated views).
- A "Jump to date" search field. The date picker is the only way to
  pick a non-adjacent date.
- Changing the date format. Eyebrow stays `"Today"` / `"Yesterday"`
  / weekday name; sub-line stays `DateFormat('EEEE, MMM d')`.

### Acceptance criteria
- [ ] `DatePill` widget exists in `today_internals.dart`. Public
      named class.
- [ ] Tap on `DatePill` opens `showDatePicker(firstDate: today - 60
      days, lastDate: today, initialDate: date)`. On non-null return,
      routes via `pathForDay(picked)`.
- [ ] `_DateBar` no longer renders chevron `IconButton36`s.
      `find.byIcon(Icons.chevron_left)` and
      `find.byIcon(Icons.chevron_right)` return zero widgets inside
      the `_DateBar` subtree.
- [ ] `_DateBar` renders `DatePill` (full-width via `Expanded`)
      followed by an optional `TodayPill` on backdated views.
- [ ] A11y: the `DatePill` reads as a single Semantics button node
      with label `"Today, Thursday May 14, open date picker"` (or
      the equivalent for the current date). The inner Text Semantics
      are excluded.
- [ ] The ring's `globalKey` paints within 280 px of the safe-area
      top on a Pixel 4a viewport — this is the cumulative
      UX-102 + UX-104 target the PM doc §2 Theme A AC names. (The
      `header_compression_test.dart` from UX-102 extends to assert
      this tighter ceiling once UX-104 lands.)
- [ ] Tenants honored: T-20, T-06.

### Tests
- `client/test/features/today/date_pill_test.dart`:
  - `tap opens date picker with 60-day floor` — pump `DatePill(date:
    DateTime(2026, 5, 15))`; tap; assert `find.byType(DatePicker)`
    finds the picker; programmatically inspect the picker's
    `firstDate` is `today - 60 days` (or assert via the picker's
    public API as exposed).
  - `picker return routes via pathForDay` — pump; tap; pick a date;
    assert the router is at `/today/<picked>`.
  - `Semantics is a single button node` — pump; use
    `tester.getSemantics(find.byType(DatePill))`; assert the
    `SemanticsNode` has `isButton: true` and the label matches the
    expected string. Assert the inner Text widgets do not emit
    their own SemanticsNodes.
- `client/test/features/today/header_compression_test.dart` (extend
  the UX-102 test):
  - `_DateBar has no chevron icons` — assert
    `find.byIcon(Icons.chevron_left)` and
    `find.byIcon(Icons.chevron_right)` return zero widgets in the
    `_DateBar` subtree.
  - `ring lands within 280 px of safe-area top on Pixel 4a viewport`
    — the cumulative-target version of UX-102's 320 px assertion.

### Notes / gotchas
- **Strict serial dependency on UX-103**. Per PM doc §2 Theme A AC
  ("the chevrons remain until swipe lands"), do not ship this
  ticket ahead of UX-103. If UX-103 is `pending` or
  `blocked-needs-pm`, leave this ticket `pending` too.
- The 60-day floor on the date picker is the same range QL-009
  picked for the TodayPill backdate flow. Architect §3.4 (C) names
  the symmetry. Do not change the floor without coordinating with
  the `CopyDaySheet`'s source-date floor (UX-105).
- The eyebrow + sub-line text styles are unchanged. The existing
  `context.text.pageTitle` and `context.text.meta` styles apply to
  the two `Text` children inside the `Column`. The pill's tap area
  is the full `Padding` block — ~48 px tall by default; T-06 is
  honoured.
- The dialog/sheet-on-expanded distinction does not apply here. The
  date picker is a native Material `showDatePicker` route on both
  form factors; no T-15 branching needed.

---

## UX-105  F1 — `LogRepository.copyDay` + `CopyDaySheet` + preview provider

**Status**: pending
**Priority**: P0
**Effort**: L
**Depends on**: none
**Owns files**:
- `client/lib/repositories/log_repository.dart` (add `copyDay`
  method per architect §3.2; add `entriesForDate(DateTime)` helper
  if not present; add `@invalidates` dartdoc block per architect
  §3.3)
- `client/lib/providers/log_providers.dart` (add
  `copyDayPreviewProvider` family + `CopyDayPreview` value class +
  `CopyDayPreviewKey` family-key per architect §3.4 (C))
- `client/lib/features/today/widgets/copy_day_sheet.dart` (new —
  the `CopyDaySheet` widget + `showCopyDaySheet(context, ref,
  {required targetDate, Meal? sourceMeal})` entry function;
  source-date stepper + picker, meal-scope chips, live preview,
  sticky save button; compact bottom sheet vs expanded dialog
  branch at the entry function root per T-15)
- `client/test/repositories/log_repository_copy_day_test.dart`
  (new — mock semantics: skip-missing-food, skip-missing-serving,
  current-food-state snapshot recomputation, partial-skip subset,
  whole-day vs meal-filter, no source-date invalidation)
- `client/test/features/today/copy_day_sheet_test.dart` (new —
  four widget tests covering the four paths from architect §3.5)

### Goal
Land the F1 copy-day machinery — the repository method that mirrors
`POST /log/copy`, the preview provider that drives the live
"N entries · M kcal" line, and the `CopyDaySheet` widget that
houses both copy paths (per-meal copy and whole-day copy). The
sheet's two entry points (per-meal overflow on `MealSection` and
empty-day "Copy from another day" row) land in UX-106; this ticket
ships the sheet + repository + provider as a self-contained unit
so UX-106 is purely additive on the surfaces side.

### Context
Architect §3 (Feature F1 deep dive — the wire shape in §3.1, the
repository contract in §3.2, the provider invalidation list in
§3.3, the UI surfaces in §3.4, acceptance criteria in §3.5). PM
doc §2 F1 (the two-affordances-one-sheet decision, the partial-skip
SnackBar shape, the outbox-not-used note). Tenants: **T-11** (errors
inline, not modal — the sheet stays open on failure), **T-14**
(sheets vs routes — `CopyDaySheet` is a sheet/dialog, not a
route), **T-15** (form-factor at the root — `showCopyDaySheet`
picks sheet-vs-dialog), **T-18** (minimal invalidation — only
target-side providers, source-date is read-only), **T-24** Case 2
(route-to-effect — on save, route via `pathForDay(targetDate)`).

### Scope
- [ ] In `log_repository.dart`, add `copyDay` per architect §3.2:
      ```dart
      Future<List<LogEntry>> copyDay({
        required DateTime sourceDate,
        required DateTime targetDate,
        List<Meal>? meals,
      });
      ```
      Mock semantics per architect §3.2:
      1. Filter `_state` by `consumedOn == sourceDate` AND
         `meals == null || meals.contains(entry.meal)`.
      2. For each source entry, look up the food via
         `_foodRepo.lookup(entry.foodId)`. If missing — silently
         skip.
      3. For each survivor, look up the serving by id. If missing —
         silently skip.
      4. Construct a new `LogEntry` via `computeLogEntry(...)` (the
         same path `create` uses), against the *current* food's
         `nutritionPer100g`. `consumedOn = targetDate` (normalised
         to Y/M/D). `createdAt = DateTime.now()`.
      5. Append each surviving new entry to `_state` and to a local
         `created` list. Call `_foodRepo.noteFoodLogged(food.id)` so
         the recents-and-frequents rankings update.
      6. Return `created`. Partial-skip is implicit in
         `created.length < filtered.length`.
      The repository **does not** route through `_outbox` for
      `copyDay`. Per PM doc §2 F1 AC: copy is online-only.
- [ ] Add the `@invalidates` dartdoc block on `copyDay` per architect
      §3.2 / §3.3:
      ```
      /// @invalidates
      /// - daySummaryProvider(targetDate)
      /// - logEntriesProvider(targetDate)
      /// - recentFoodsProvider
      /// - frequentFoodsProvider
      /// - weeklyLogDaysProvider (added when UX-110 lands; see Notes)
      /// Notably NOT invalidated: daySummaryProvider(sourceDate) /
      /// logEntriesProvider(sourceDate) — source is read-only.
      ```
- [ ] If `entriesForDate(DateTime)` does not exist on the repository,
      add it: a thin `Future<List<LogEntry>>` reader that returns
      `_state.where((e) => isSameDay(e.consumedOn, date))`. The
      preview provider reads this.
- [ ] In `log_providers.dart`, add the preview provider per architect
      §3.4 (C):
      ```dart
      class CopyDayPreview {
        final int count;
        final Decimal totalKcal;
        const CopyDayPreview({required this.count,
            required this.totalKcal});
      }

      class CopyDayPreviewKey {
        final DateTime sourceDate;
        final List<Meal>? meals;
        const CopyDayPreviewKey({required this.sourceDate,
            this.meals});
        // == and hashCode that treat null and equal-list meals as
        // family-equivalent. List<Meal>? equality is by content.
      }

      final copyDayPreviewProvider =
          FutureProvider.family<CopyDayPreview, CopyDayPreviewKey>(
        (ref, key) async {
          final repo = ref.watch(logRepositoryProvider);
          final entries = await repo.entriesForDate(key.sourceDate);
          final filtered = key.meals == null
              ? entries
              : entries.where((e) => key.meals!.contains(e.meal));
          return CopyDayPreview(
            count: filtered.length,
            totalKcal: filtered.fold<Decimal>(
              Decimal.zero,
              (acc, e) => acc + e.caloriesKcal,
            ),
          );
        },
      );
      ```
- [ ] In `copy_day_sheet.dart`:
      - Define `Future<void> showCopyDaySheet(BuildContext context,
        WidgetRef ref, {required DateTime targetDate, Meal? sourceMeal})`.
        Compact: `showModalBottomSheet` with
        `DraggableScrollableSheet` (initialChildSize ~0.55, snap to
        0.55 / 0.88). Expanded: `showDialog` with a 480×~520 dialog.
        The body widget is form-factor blind per T-15.
      - Define `class CopyDaySheet extends ConsumerStatefulWidget`
        whose state owns: `_sourceDate` (defaults to
        `targetDate.subtract(Duration(days: 1))`), `_meals`
        (defaults: if `sourceMeal != null` → `[sourceMeal]`; else
        `null` meaning "All meals"), `_isSubmitting`.
      - The body composes (top-down):
        1. A **source-date row**: `Text('From')` + a date display +
           `IconButton36(icon: Icons.chevron_left)` (step −1 day) +
           `IconButton36(icon: Icons.chevron_right)` (step +1 day,
           capped at `targetDate - 1`) + a calendar `IconButton36`
           that opens `showDatePicker(firstDate: today - 60 days,
           lastDate: today, initialDate: _sourceDate)`. The 60-day
           floor matches QL-009 / UX-104.
        2. **Meal-scope chips**: a `Wrap` of five `FilterChip`-shaped
           buttons — "All meals", "Breakfast", "Lunch", "Dinner",
           "Snack". Multi-select semantics:
           - Selecting "All meals" deselects the four single-meal
             chips. The state stores `_meals = null`.
           - Selecting any of the four deselects "All meals" if it
             was active. The state stores `_meals = [...selected]`.
           - The chips render their own state via the local
             `_meals` set.
        3. **Live preview**: a single line
           `Text('${preview.count} entries · ${formatKcal(preview.totalKcal)}')`
           driven by `ref.watch(copyDayPreviewProvider(CopyDayPreviewKey(
           sourceDate: _sourceDate, meals: _meals)))`. Show a small
           skeleton while loading; show "—" on error (T-08 — but
           the preview is in-memory so loading is near-instant).
        4. **Sticky save button**: `PrimaryButton(label: 'Save —
           copy $count entries', onPressed: count == 0 ||
           _isSubmitting ? null : _save)`.
      - The `_save` handler:
        1. `setState(() => _isSubmitting = true);`
        2. `try { final created = await
           ref.read(logRepositoryProvider).copyDay(sourceDate:
           _sourceDate, targetDate: widget.targetDate, meals:
           _meals); }`
        3. On success:
           - `ref.invalidate(daySummaryProvider(targetDate));`
             `ref.invalidate(logEntriesProvider(targetDate));`
             `ref.invalidate(recentFoodsProvider);`
             `ref.invalidate(frequentFoodsProvider);`
             (Add `ref.invalidate(weeklyLogDaysProvider);` once
             UX-110 lands — see Notes.)
           - If on expanded dialog: `Navigator.of(context, rootNavigator:
             true).pop();` first (T-24 dialog-pop-first rule).
           - `context.go(pathForDay(widget.targetDate));`
           - Show SnackBar:
             - On full copy (`created.length == requestedCount`):
               `'Copied $count entries'`.
             - On partial-skip (`created.length < requestedCount`):
               `'Copied ${created.length} of $requestedCount — ${requestedCount - created.length} skipped (food no longer available)'`.
             `requestedCount` is the live preview's count at the
             time of save.
        4. On failure (`catch` block): `setState(() => _isSubmitting
           = false);` Show SnackBar with "Try again" action that
           re-invokes `_save`. Sheet stays open.
- [ ] A11y per architect §3.5: each chip's Semantics combines meal
      name + selected state ("Breakfast, selected" / "Lunch, not
      selected"). The save button's semantic label includes the row
      count.

### Out of scope
- The per-meal overflow icon on `MealSection` and the empty-day
  "Copy from another day" affordance — both land in UX-106.
- The `weeklyLogDaysProvider` invalidation line on `copyDay`'s
  `@invalidates` block — added in UX-110 when the provider
  exists. UX-105 ships the four other invalidations and a
  forward-referenced comment.
- The `LogRepository.adoptOptimistic` invalidation list update — F1
  doesn't use the outbox; the optimistic path is unchanged.
- A `Replace day` UI. PM doc §2 F1 names this as out of scope; copy
  is purely additive on the target day.

### Acceptance criteria
- [ ] `LogRepository.copyDay({sourceDate, targetDate, meals})` exists
      with the exact signature in architect §3.2. The `@invalidates`
      dartdoc lists the four (later five) target-side providers.
- [ ] Mock semantics: read entries from `sourceDate`, filter by
      `meals`, recompute snapshots against current food state (food
      lookup → serving lookup → `computeLogEntry`), append to
      `_state`, return new entries. Partial skips happen silently;
      the caller compares `created.length` to the requested count.
- [ ] `copyDay` does **not** touch `_outbox`. The method runs the
      same way on compact, medium, and expanded.
- [ ] `copyDayPreviewProvider` exists in `log_providers.dart`. Family
      key is `CopyDayPreviewKey(sourceDate, meals)`. Returns
      `CopyDayPreview(count, totalKcal)`.
- [ ] `CopyDaySheet` lives at
      `client/lib/features/today/widgets/copy_day_sheet.dart`. The
      file exports `showCopyDaySheet(context, ref, {targetDate,
      sourceMeal})`. Compact = bottom sheet; expanded = dialog. Body
      composes source-date row + meal chips + live preview + sticky
      save button.
- [ ] On save success: target-side providers invalidated; route via
      `pathForDay(targetDate)` (T-24 Case 2); SnackBar with the
      copied-count message (full or partial-skip).
- [ ] On save failure: SnackBar with "Try again" action; sheet
      stays open; submit re-enables (T-11).
- [ ] The source-date stepper / picker is bounded to `[today - 60
      days, today]` and `[targetDate - any-prior, targetDate - 1]`
      (i.e., source < target; the stepper caps at `targetDate - 1`).
- [ ] The save button's label includes the count ("Save — copy 4
      entries"); the button is disabled when count == 0 or while
      submitting.
- [ ] A11y: chip Semantics labels include selected state; save
      button label includes count; partial-skip SnackBar
      announcement appends "(K skipped)".
- [ ] Tenants honored: T-11, T-14, T-15, T-18, T-24 (Case 2), T-20.

### Tests
- `client/test/repositories/log_repository_copy_day_test.dart`:
  - `copyDay recomputes snapshots against current food state` — seed
    food with `caloriesPer100g: 200`; log entry on day 1 with
    quantity 1, kcal snapshot 200. Edit food to
    `caloriesPer100g: 300`. Copy day 1 → day 2. Assert: copied
    entry's kcal snapshot is 300, not 200.
  - `copyDay skips entries whose food was deleted` — seed; delete
    food; copy; assert returned list is empty.
  - `copyDay skips entries whose serving was deleted` — same shape.
  - `copyDay returns subset when partial skip` — three source
    entries, one with deleted food; copy; assert `created.length ==
    2`.
  - `copyDay accepts whole-day (meals: null) and meal-filter` —
    seed three entries across breakfast/lunch; copy with `meals:
    [Meal.breakfast]`; assert only the breakfast entry copies.
  - `copyDay does not invalidate source-date providers` — this is a
    documentation-level assertion (the `@invalidates` block doesn't
    list source-date providers); the test can verify by spying on
    `ref.invalidate` calls when the sheet's save handler runs (test
    in `copy_day_sheet_test.dart` is the more appropriate place).
- `client/test/features/today/copy_day_sheet_test.dart`:
  - `per-meal copy on compact with yesterday non-empty` — pump the
    sheet via `showCopyDaySheet(context, ref, targetDate: today,
    sourceMeal: Meal.breakfast)`; assert the breakfast chip is
    pre-selected; assert the source-date stepper defaults to
    `today - 1`; tap save; assert the repository's `copyDay` is
    called with `(sourceDate: yesterday, targetDate: today, meals:
    [Meal.breakfast])`.
  - `per-meal copy with custom source-date picker` — pump; tap
    calendar; pick a date 5 days ago; assert the live preview
    updates; tap save; assert the repository call carries the
    picked source date.
  - `whole-day copy from empty-day affordance` — pump with
    `sourceMeal: null`; assert "All meals" is selected by default;
    tap save; assert the repository call carries `meals: null`.
  - `partial-skip SnackBar message` — seed the mock so `copyDay`
    returns `created.length: 3` against a `requested: 4`
    preview; assert the SnackBar text is "Copied 3 of 4 — 1
    skipped (food no longer available)".

### Notes / gotchas
- The `weeklyLogDaysProvider` invalidation is forward-referenced in
  the `@invalidates` dartdoc but **not** actually invoked from
  `_save` until UX-110 lands. Add a `// TODO(UX-110): once
  weeklyLogDaysProvider lands, add the invalidation line here.`
  comment in `_save`'s invalidation block. UX-110's PR description
  must call out the cross-ticket edit.
- The 60-day floor on the source-date picker matches the
  `DatePill` floor (UX-104) and QL-009's TodayPill backdate range.
  Architect §3.4 (C) names the symmetry. Do not change without
  coordinating.
- The PM open question (architect §12.4) confirmed 60 days as the
  ruling. See the "Architect's open questions → resolution" section
  below.
- The chip multi-select state lives in the widget's `_LocalState`,
  not a provider. The preview provider re-runs on each chip toggle
  because `CopyDayPreviewKey` changes; the family invalidation is
  automatic.
- `requestedCount` for the partial-skip SnackBar text is computed
  from `_save`'s preview snapshot at submit time, not from a fresh
  read. Snapshot once at the top of `_save` to avoid race
  conditions where a chip toggle changes the preview mid-submit.
- The sheet uses the existing `_SaveButtonSkeleton` shape for the
  submitting state (per PM doc §2 F1 AC). If `_SaveButtonSkeleton`
  doesn't exist as a named widget, inline its shape — a
  `PrimaryButton(label: 'Saving…', onPressed: null)` is acceptable.

---

## UX-106  F1 — `MealSection` overflow + empty-day "Copy from another day"

**Status**: pending
**Priority**: P0
**Effort**: M
**Depends on**: UX-105
**Owns files**:
- `client/lib/widgets/meal_section.dart` (add `onCopyMeal:
  void Function(Meal)?` and `canCopyMeal: bool Function(Meal)?`
  constructor parameters; render the `IconButton36`-shaped
  overflow icon to the right of the kcal total when `onCopyMeal !=
  null`; the icon opens a `showMenu` with the "Copy from
  yesterday" / "Copy from…" entry; greyed when `canCopyMeal !=
  null && !canCopyMeal(meal)`)
- `client/lib/features/today/day_view_compact.dart` (in
  `_MealsSliver`: thread `onCopyMeal: (meal) =>
  showCopyDaySheet(context, ref, targetDate: date, sourceMeal:
  meal)` into each `MealSection`; in `_EmptyDayPill`: convert to
  `ConsumerWidget`; below the existing "Log a food" primary
  button, render a `TextButton` "Copy from another day" when
  `entries.isEmpty && isLocalNowDay(date)`)
- `client/lib/features/today/day_view_expanded.dart` (same
  threading on the expanded grid's `MealSection` mounts — the
  overflow icon renders on the expanded card too; the empty-day
  affordance is compact-only)
- `client/test/widgets/meal_section_copy_overflow_test.dart` (new
  — renders the overflow icon when `onCopyMeal != null`; hides it
  when null; greys it when `canCopyMeal` returns false; tap invokes
  `onCopyMeal(meal)` with the section's meal)
- `client/test/features/today/empty_day_copy_from_test.dart` (new
  — renders "Copy from another day" when day is empty AND today;
  hides on backdated empty day; hides when day has entries; tap
  invokes `showCopyDaySheet` with `sourceMeal: null`)

### Goal
Wire the two F1 entry surfaces: the per-meal overflow icon on
`MealSection` headers (compact + expanded) and the "Copy from
another day" secondary affordance inside the empty-day pill
(compact-only, today-only). Both open `CopyDaySheet` (UX-105) with
the appropriate pre-seeds. After this ticket, F1 is end-user
reachable from the two places the PM doc named.

### Context
Architect §3.4 (A) (per-meal overflow), §3.4 (B) (empty-day "Copy
from another day"), §3.5 acceptance criteria. PM doc §2 F1
acceptance ("Each `MealSection` header gains an overflow icon
whose menu includes 'Copy from yesterday'", "render a
`_CopyFromDayRow` between the existing empty-day pill and the meal
sections"). Tenants: **T-06** (the overflow `IconButton36` is the
standard 36-px tap target), **T-20** (Semantics on the new
affordances), **T-23** (`MealSection` is a lifted widget; new
parameters are part of the public API).

### Scope
- [ ] In `meal_section.dart`, extend the constructor:
      ```dart
      class MealSection extends StatelessWidget {
        const MealSection({
          required this.subtotal,
          required this.entries,
          required this.onAddTap,
          this.dense = false,
          this.onEntryTap,
          this.isPendingSync,
          // NEW for F1 (UX-106):
          this.onCopyMeal,
          this.canCopyMeal,
          super.key,
        });

        final void Function(Meal meal)? onCopyMeal;
        final bool Function(Meal meal)? canCopyMeal;
      }
      ```
      Behavior:
      - When `onCopyMeal == null`: overflow icon is **not**
        rendered. Existing test fixtures that don't opt in see no
        visual change.
      - When `onCopyMeal != null`: render an `IconButton36(icon:
        Icons.more_horiz_outlined, tooltip: 'Copy from another day',
        onPressed: () => _showCopyMenu(context, meal))` to the
        right of the kcal total, separated by `space.x2`. The kcal
        total moves left by the icon's width.
      - When `canCopyMeal != null && !canCopyMeal(meal)`: the icon
        renders with `color: context.colors.ink2.withOpacity(0.5)`
        (greyed) and the menu's "Copy from yesterday" item changes
        to "Copy from…" (the date+meal picker default).
- [ ] The `_showCopyMenu` method renders a single-item `showMenu`:
      ```dart
      final selected = await showMenu<_CopyAction>(
        context: context,
        position: ..., // anchored on the overflow icon
        items: [
          PopupMenuItem(
            value: _CopyAction.copyFromYesterday,
            child: Row(children: [
              Icon(Icons.content_copy_outlined),
              SizedBox(width: 12),
              Text(canCopy ? 'Copy from yesterday' : 'Copy from…'),
            ]),
          ),
        ],
      );
      if (selected == _CopyAction.copyFromYesterday) onCopyMeal!(meal);
      ```
- [ ] In `day_view_compact.dart`'s `_MealsSliver` (and the parallel
      mount in `day_view_expanded.dart`), thread the new parameters:
      ```dart
      MealSection(
        subtotal: ...,
        entries: ...,
        onAddTap: ...,
        onCopyMeal: (m) => showCopyDaySheet(
          context,
          ref,
          targetDate: date,
          sourceMeal: m,
        ),
        // canCopyMeal: omit for now — architect §3.4 (A)
        // notes the predicate is optional; the menu's label
        // still flips when yesterday's same-meal is empty,
        // but the icon stays enabled. See Notes.
      )
      ```
- [ ] In `day_view_compact.dart`'s `_EmptyDayPill`:
      - Convert from `StatelessWidget` to `ConsumerWidget` (it
        needs `ref` to invoke `showCopyDaySheet`).
      - Below the existing "Log a food" `PrimaryButton`, add a
        `TextButton` (or `OutlinedButton` per agent's choice, but
        the PM doc names "text-shaped secondary affordance") with
        a `Row` containing `Text('Copy from another day')` +
        `SizedBox(width: 4)` + `Icon(Icons.chevron_right, size: 16)`.
      - The button's `onPressed: () => showCopyDaySheet(context,
        ref, targetDate: date, sourceMeal: null)`.
      - Gate the entire `TextButton` on `entries.isEmpty &&
        isLocalNowDay(date)`. The existing pill's gate is
        `entries.isEmpty`; the new affordance adds the today-only
        condition.
- [ ] A11y: the overflow `IconButton36` has tooltip "Copy from
      another day" (or per-meal "Copy breakfast from another day"
      if the agent prefers; either is T-20 compliant). The empty-
      day `TextButton` carries Semantics "Copy from another day,
      open copy sheet".

### Out of scope
- The `canCopyMeal` predicate's wire — architect §3.4 (A) notes
  this is an "any-entries-by-meal-window" provider the agent may
  defer. UX-106 ships **without** the predicate; the overflow
  icon is always enabled. The menu's label flip ("Copy from
  yesterday" vs "Copy from…") can also be omitted for v1 — the
  sheet's source-date stepper lets the user adjust. If the agent
  wants to flip the label, read the existing `recentFoodsProvider`
  data or a small "did any meal log on yesterday" check; otherwise
  default to "Copy from yesterday".
- The 14-day window cap on the overflow's enabled state (per PM
  doc §2 F1 AC "only enabled when there's *any* prior day with
  logged entries in this meal in the last 14 days"). Architect
  §3.4 (A) names this as `canCopyMeal`'s job; deferred. The
  overflow stays always-enabled in v1; the menu opens the sheet
  which handles the empty-source case via the disabled save button.
- The `CopyDaySheet` widget itself. Lives in UX-105.

### Acceptance criteria
- [ ] `MealSection` constructor gains `onCopyMeal: void Function(Meal)?`
      and `canCopyMeal: bool Function(Meal)?`. When `onCopyMeal ==
      null`, no overflow icon is rendered. When non-null, the icon
      renders.
- [ ] Tap on the overflow icon opens a `showMenu` with one item
      ("Copy from yesterday" / "Copy from…"). Selecting the item
      invokes `onCopyMeal(meal)` with the section's meal.
- [ ] In `day_view_compact.dart` and `day_view_expanded.dart`, each
      `MealSection` is wired with `onCopyMeal: (m) =>
      showCopyDaySheet(context, ref, targetDate: date, sourceMeal:
      m)`.
- [ ] `_EmptyDayPill` is a `ConsumerWidget`. Below the existing
      "Log a food" button, it renders a "Copy from another day"
      `TextButton` only when `entries.isEmpty && isLocalNowDay(date)`.
- [ ] Tap on "Copy from another day" opens `showCopyDaySheet(context,
      ref, targetDate: date, sourceMeal: null)`.
- [ ] On backdated empty days, the "Copy from another day"
      affordance is hidden (only the "Log a food" button shows).
- [ ] A11y: overflow icon has a tooltip + Semantics label; the
      empty-day `TextButton` has a Semantics label. T-20 honoured.
- [ ] Tenants honored: T-06, T-20, T-23.

### Tests
- `client/test/widgets/meal_section_copy_overflow_test.dart`:
  - `overflow icon hidden when onCopyMeal is null` — pump
    `MealSection(..., onCopyMeal: null)`; assert
    `find.byIcon(Icons.more_horiz_outlined)` finds zero widgets.
  - `overflow icon visible when onCopyMeal is non-null` — pump
    with `onCopyMeal: (_) {}`; assert one widget.
  - `tap on overflow icon invokes onCopyMeal with the section's
    meal` — pump with `onCopyMeal: spy`; tap; tap the menu item;
    assert `spy.calledWith(Meal.breakfast)` (or whatever meal the
    section renders).
- `client/test/features/today/empty_day_copy_from_test.dart`:
  - `Copy from another day visible on empty today` — pump
    `_EmptyDayPill(entries: [], date: today)`; assert
    `find.text('Copy from another day')` finds one widget.
  - `Copy from another day hidden on backdated empty day` — pump
    with `date: yesterday`; assert zero widgets.
  - `Copy from another day hidden when day has entries` — pump
    with `entries: [seededEntry]`; assert zero widgets.
  - `tap routes through showCopyDaySheet with null sourceMeal` —
    pump on today; tap; assert `showCopyDaySheet` is called with
    `sourceMeal: null` (use a function spy or override the entry
    function via DI/ProviderContainer).

### Notes / gotchas
- The `canCopyMeal` predicate is deferred in v1. Architect §3.4 (A)
  named it as optional; the sheet's empty-source state (count == 0
  → save button disabled) is the fallback UX. If user testing shows
  too many users opening the sheet on a fresh day with no
  yesterday-data, escalate to a v1.1 ticket adding the predicate.
- The expanded grid's kcal-total layout — when the overflow icon
  is added, the kcal text shifts left by 36 px + `space.x2`.
  Architect §3.4 (A) notes this is < 5% of the card width; visual
  regression is acceptable. If a reviewer reports the kcal text
  clipping on a narrow expanded column, raise `space.x2` to
  `space.x3` between the kcal text and the overflow icon — small
  layout knob, no shape change.
- The `_EmptyDayPill`'s conversion from `StatelessWidget` to
  `ConsumerWidget` is mechanical. The build method gains a
  `WidgetRef ref` parameter; the call site in `day_view_compact.dart`
  doesn't change (the parent already passes `ref` via the
  enclosing `ConsumerWidget`).
- The expanded grid's empty-day surface is unchanged in v1. The
  "Copy from another day" affordance is compact-only because the
  expanded grid renders all five meal cards even when empty; the
  per-meal overflow on each card is the right path on expanded.
- Threading `ref` into the `MealSection` callbacks happens at the
  call site (in `_MealsSliver`), not inside `MealSection` itself.
  `MealSection` stays `StatelessWidget`; only the call sites
  become `ConsumerWidget`-aware.

---

## UX-107  F2 — `QuickAddChips.compact` flag + Today compact mount

**Status**: pending
**Priority**: P0
**Effort**: M
**Depends on**: UX-101
**Owns files**:
- `client/lib/widgets/quick_add_chips.dart` (add `compact: bool =
  false` and `maxChips: int?` constructor parameters; add the
  `_buildCompactStrip` branch in `build`; keep the existing
  card-shaped branch as the default)
- `client/lib/features/today/day_view_compact.dart` (in the body's
  `CustomScrollView.slivers`, add a `SliverToBoxAdapter(child:
  _TodayRecentChipsRow(date: date))` between the `RingSummaryCard`
  slot and the `_EmptyDayPill` / `_MealsSliver` block; add the
  `_TodayRecentChipsRow` private `ConsumerWidget` per architect
  §4.3)
- `client/test/widgets/quick_add_chips_compact_test.dart` (new —
  asserts compact mode renders horizontal-scroll strip, recents-
  only, no card chrome; asserts `compact: false` default
  preserves the existing card branch)
- `client/test/features/today/recent_chips_row_compact_test.dart`
  (new — three tests: rendered-on-today-with-recents,
  hidden-on-backdate, hidden-when-recents-empty; tap routes
  through `LogEntrySheet` create mode with the time-of-day meal
  seeded)

### Goal
Wire F2 — the recent-foods chip strip on Today compact. Two
changes: extend `QuickAddChips` with a `compact` flag that swaps
the card-shaped render for a horizontal-scroll strip; add a thin
`_TodayRecentChipsRow` wrapper inside `day_view_compact.dart` that
gates on `isLocalNowDay(date)` AND `recents.isNotEmpty` and mounts
the lifted widget. After this ticket, on today's compact day-view
with non-empty recents, the strip renders between the ring and
the meal sections; tapping a chip opens `LogEntrySheet` pre-seeded
with the food + the time-of-day meal default.

### Context
Architect §4 (Feature F2 deep dive — the mount in §4.1, the
flag-on-public-widget choice in §4.2, the wrapper widget in §4.3,
tap behavior in §4.4, empty state in §4.5, acceptance in §4.6).
PM doc §2 F2 ("expose `QuickAddChips` on compact, above the meal
sections, between the RingSummaryCard and the first MealSection";
"max 6 chips; min 4 — if fewer than 4 recents exist, hide the whole
strip"). The architect's open question on the provider source
(architect §12.3) is resolved in favour of `recentFoodsProvider`
as-is — see the "Architect's open questions → resolution" section.
Tenants: **T-15** (form-factor branches inside the screen — the
strip is compact-only via the wrapper widget's gate, not via
breakpoint switching on the widget itself), **T-20** (chip
Semantics preserved verbatim), **T-23** (`QuickAddChips` is now
canonical per UX-101).

### Scope
- [ ] In `quick_add_chips.dart`, extend the constructor:
      ```dart
      class QuickAddChips extends StatelessWidget {
        const QuickAddChips({
          required this.recents,
          required this.frequents,
          required this.onTapFood,
          this.compact = false,
          this.maxChips,
          super.key,
        });

        final bool compact;
        final int? maxChips;
      }
      ```
- [ ] Add the compact branch in `build`:
      ```dart
      @override
      Widget build(BuildContext context) {
        if (compact) return _buildCompactStrip(context);
        return _buildCardWithSections(context);
      }

      Widget _buildCompactStrip(BuildContext context) {
        final shown = _take(recents, maxChips ?? 6);
        if (shown.isEmpty) return const SizedBox.shrink();
        return SizedBox(
          height: 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: context.space.x5),
            itemCount: shown.length,
            separatorBuilder: (_, __) => SizedBox(width: context.space.x2),
            itemBuilder: (_, i) => _QuickAddChip(
              food: shown[i],
              onTap: () => onTapFood(shown[i]),
            ),
          ),
        );
      }
      ```
      The `_take` helper truncates to `min(list.length, max)`.
      `_QuickAddChip` is the existing private chip leaf in the
      widget file — reuse verbatim.
- [ ] The card branch (`_buildCardWithSections`) is the current
      `build()` body, extracted into a private method. No render
      change.
- [ ] In `day_view_compact.dart`, add the `_TodayRecentChipsRow`
      private widget per architect §4.3:
      ```dart
      class _TodayRecentChipsRow extends ConsumerWidget {
        const _TodayRecentChipsRow({required this.date});
        final DateTime date;

        @override
        Widget build(BuildContext context, WidgetRef ref) {
          if (!isLocalNowDay(date)) return const SizedBox.shrink();
          final recentsAsync = ref.watch(recentFoodsProvider);
          final recents = recentsAsync.valueOrNull ?? const <Food>[];
          if (recents.length < 4) return const SizedBox.shrink();
          return Padding(
            padding: EdgeInsets.only(bottom: context.space.x3),
            child: QuickAddChips(
              compact: true,
              recents: recents,
              frequents: const <Food>[],
              onTapFood: (food) => showLogEntrySheet(
                context,
                food: food,
                defaultMeal: mealForLocalTime(DateTime.now()),
              ),
            ),
          );
        }
      }
      ```
- [ ] In the body's `CustomScrollView.slivers`, mount the row
      between the `RingSummaryCard` slot and the `_EmptyDayPill` /
      `_MealsSliver` block:
      ```dart
      CustomScrollView(slivers: [
        SliverToBoxAdapter(child: _CompactHeader(...)),
        SliverToBoxAdapter(child: _DateBar(date: date)),
        SliverToBoxAdapter(child: ... RingSummaryCard ...),
        SliverToBoxAdapter(child: _TodayRecentChipsRow(date: date)), // NEW
        SliverToBoxAdapter(child: _EmptyDayPill(...)),
        SliverPadding(... _MealsSliver(...)),
      ])
      ```

### Out of scope
- A `recentRealFoodsProvider` that filters out Quick-add synthetic
  entries — architect §12.3 ruled in favour of `recentFoodsProvider`
  as-is. The Quick-add food is already excluded via the
  `noteFoodLogged` guard added in commit a6ba4cf (the architect's
  rationale: PM doc §2 F2 consistency-with-the-right-rail; if
  user testing shows Quick-adds as confusing in the strip,
  escalate to v1.1).
- Recency-quantity-seed for the `LogEntrySheet` open — architect
  §4.4 defers this to v1.1. The tap handler passes only `food` and
  `defaultMeal`; quantity defaults to 1 inside `LogEntrySheet`.
- A frequency-based ordering option. Architect §4 ships recency
  only.
- A "see more" tail / overflow chip. The horizontal-scroll
  surface is the long-tail affordance.
- Renaming `QuickAddChips` to `QuickChipRow` (the inventory's
  name). Deferred per architect §2.2.

### Acceptance criteria
- [ ] `QuickAddChips` accepts `compact: bool = false` and
      `maxChips: int?`. The compact branch renders a
      horizontal-scroll strip of ≤ `maxChips ?? 6` chips;
      recents-only; no card chrome; no empty-state placeholder.
- [ ] The expanded right-rail caller is unchanged (compact stays
      false, default behaviour preserved). Visual regression on
      the expanded right rail is zero.
- [ ] `_TodayRecentChipsRow` widget lives in `day_view_compact.dart`
      (private). Gates on `isLocalNowDay(date)` AND
      `recents.length >= 4`.
- [ ] On compact day-view of the local-now day with `recents.length
      >= 4`, the strip renders between the `RingSummaryCard` and
      the `_EmptyDayPill`.
- [ ] Tap a chip → `showLogEntrySheet(context, food: f,
      defaultMeal: mealForLocalTime(DateTime.now()))`. The existing
      sheet handles create-mode T-24 Case 2 routing (already
      shipped via QL-105).
- [ ] Backdated days (`date != local-now`): the strip is hidden.
- [ ] Empty recents (`recents.length < 4`): the strip is hidden;
      no placeholder rendered.
- [ ] Each chip's existing `Semantics(button: true, label:
      "$foodName, $kcal kilocalories")` is preserved verbatim.
- [ ] Tenants honored: T-15 (gate at the wrapper, not the leaf),
      T-20, T-23.

### Tests
- `client/test/widgets/quick_add_chips_compact_test.dart`:
  - `compact false renders card branch` — pump
    `QuickAddChips(compact: false, recents: ..., frequents: ...,
    onTapFood: ...)`; assert the card eyebrow ("Quick add") is
    visible.
  - `compact true renders horizontal-scroll strip` — pump with
    `compact: true`; assert the eyebrow is absent; assert the
    `ListView`'s `scrollDirection` is `Axis.horizontal`.
  - `compact true respects maxChips` — pump with `compact: true,
    maxChips: 4` and 6 recents; assert 4 chips render.
  - `compact true returns SizedBox.shrink when recents empty` —
    pump with `compact: true, recents: const []`; assert the widget
    has zero size.
- `client/test/features/today/recent_chips_row_compact_test.dart`:
  - `renders on today with non-empty recents` — pump
    `DayViewCompact(date: today)` with seeded `recentFoodsProvider`
    of 5 foods; assert one `_TodayRecentChipsRow` widget renders.
  - `hidden on backdated day` — pump with `date: yesterday`; assert
    the row's `child` is `SizedBox.shrink` (or absent).
  - `hidden when recents empty (< 4)` — pump on today with
    seeded `recentFoodsProvider` of 2 foods; assert hidden.
  - `tap routes through LogEntrySheet create mode with time-of-day
    meal` — pump on today; tap a chip; assert
    `LogEntrySheet` is in the widget tree with `existing: null`
    and `defaultMeal == mealForLocalTime(DateTime.now())`.

### Notes / gotchas
- The `>= 4` floor (PM doc §2 F2 AC: "minimum is 4 — if fewer
  than 4 recents exist, hide the whole strip") is implemented in
  `_TodayRecentChipsRow`'s gate, not inside `QuickAddChips`. The
  widget itself short-circuits only when `shown.isEmpty`. This
  preserves the widget's reusability — a future surface that
  wants the strip on fewer chips can pass `maxChips: 3` without
  the gate.
- The `recentFoodsProvider` already excludes the Quick-add
  synthetic food via the `noteFoodLogged` guard (commit a6ba4cf).
  No filter is needed on the consumer side.
- The strip's vertical position is "between the ring and the
  meals" per the PM doc §2 F2 AC. The sliver order matters; do
  not mount the strip above the `_DateBar` or below the
  `_MealsSliver`. The architect's §4.1 ordering is canonical.
- The `_TodayRecentChipsRow` is a `ConsumerWidget`, not a
  `StatelessWidget` — it watches `recentFoodsProvider`. The
  enclosing widget tree already has a `ProviderScope`; no
  additional setup needed.
- If `recentFoodsProvider` is still loading when the strip is
  first mounted, `valueOrNull` returns null and the strip is
  hidden. The PM doc accepts this — no skeleton renders in the
  strip's slot.

---

## UX-108  F4 — Sparkline scrub-to-read gesture

**Status**: pending
**Priority**: P1
**Effort**: M
**Depends on**: none
**Owns files**:
- `client/lib/features/weight/widgets/weight_sparkline.dart` (add
  `_ScrubGestureWrap` + `_ScrubOverlayPainter` inside the file;
  wrap the existing `CustomPaint` in `_ScrubGestureWrap`; the
  painter renders a vertical guideline + floating tooltip when
  scrubbing)
- `client/test/features/weight/sparkline_scrub_test.dart` (new —
  four tests: drag emits guideline + tooltip; drag end fades;
  vertical drag does not block parent scroll; reduce-motion
  bypasses fade)

### Goal
Land F4 — drag-to-scrub on compact, hover-to-scrub on expanded for
the `WeightSparkline` chart. The user drags their finger
horizontally along the chart (or hovers on web) and a vertical
guideline + floating tooltip renders at the touch X, showing the
exact date + weight at the nearest data point. Tooltip text honours
T-21 (`formatWeightWithUnit` in the user's unit). The vertical
drag gesture inside the chart does not hijack the parent
`ListView`'s scroll. Fade animations honour `MediaQuery.disableAnimationsOf`.

### Context
Architect §5.1 (F4 — gesture wrap shape, hit-testing, painter
extension, reduce-motion handling). PM doc §2 F4 (drag-not-long-press
on compact, hover on web, `RawGestureDetector`-style wrap to avoid
parent-scroll conflict, `EEE, MMM d` date format). Tenants:
**T-12 spirit** (vertical drag doesn't get hijacked), **T-19**
(painter-only extension; no new chart package), **T-20** (the
chart's existing `Semantics(value: ...)` carries the range
summary; scrub is a sighted-user affordance), **T-21**
(`formatWeightWithUnit` for the tooltip's weight line).

### Scope
- [ ] In `weight_sparkline.dart`, add `_ScrubGestureWrap` per
      architect §5.1. The widget is a `StatefulWidget` with
      `SingleTickerProviderStateMixin`. State owns:
      - `double? _scrubX` — active scrub X-coordinate, null when
        inactive.
      - `AnimationController _fade` — 120 ms in / 120 ms out.
- [ ] The `build` branches on form factor:
      - Expanded (`FormFactor.of(context).isExpanded`): wrap the
        child in `MouseRegion(onEnter, onHover, onExit)`.
      - Compact: wrap in `GestureDetector(behavior:
        HitTestBehavior.translucent, onHorizontalDragStart,
        onHorizontalDragUpdate, onHorizontalDragEnd,
        onHorizontalDragCancel)`. `HitTestBehavior.translucent`
        lets vertical drags pass through to the parent scroll.
- [ ] The child of `_ScrubGestureWrap` is the existing
      `CustomPaint` with the `_ChartPainter`. Wrap it again in an
      `AnimatedBuilder(animation: _fade)` that, when `_scrubX !=
      null`, layers a `CustomPaint(foregroundPainter:
      _ScrubOverlayPainter(scrubX: _scrubX!, opacity: _fade.value,
      points: widget.points, unit: widget.unit))`. The
      `foregroundPainter` draws *over* the existing chart strokes.
- [ ] Implement `_ScrubOverlayPainter.paint(Canvas, Size)` per
      architect §5.1:
      1. Linear-scan `widget.points` for the nearest x to `scrubX`.
         Capture the matching `WeightSeriesPoint`.
      2. Draw a 1-px vertical line at `scrubX` from chart-top to
         chart-bottom in `AppColors.ink2` at `opacity`.
      3. Draw a 4-px filled dot at `(pointX, pointY)`.
      4. Compose the tooltip text:
         - Top line: `DateFormat('EEE, MMM d').format(point.date)`.
         - Bottom line: `formatWeightWithUnit(point.weightKg,
           widget.unit)`.
      5. Lay out the text in a `TextPainter`; draw an
         `AppColors.ink`-filled `RRect` background (8-px padding,
         `radius.r2`); paint the text in white at `opacity`.
      6. Position the tooltip above the dot, clamped to the chart's
         horizontal bounds.
- [ ] Wire the gesture handlers to the state:
      - `_startAt(x, disableAnims)`: `setState(() => _scrubX = x)`;
        if `disableAnims` → `_fade.value = 1.0`; else
        `_fade.forward()`.
      - `_updateAt(x)`: `setState(() => _scrubX = x)`.
      - `_endScrub(disableAnims)`: if `disableAnims` → `_fade.value
        = 0.0; setState(() => _scrubX = null)`; else
        `_fade.reverse().then((_) { if (mounted) setState(() =>
        _scrubX = null); })`.
- [ ] Short-circuit when `widget.points.isEmpty`: the wrap returns
      `widget.child` directly without gesture handlers. Empty-state
      chart has no scrub.
- [ ] In `weight_sparkline.dart`'s `_ChartBody` (or wherever the
      `CustomPaint` mounts today), wrap the `CustomPaint` in
      `_ScrubGestureWrap(points: ..., unit:
      ref.watch(weightUnitProvider), child: CustomPaint(...))`.

### Out of scope
- Adding the scrub Semantics to the chart's existing
  `Semantics(value: ...)` — architect §5.1 explicitly notes that
  the scrub is a sighted-user affordance and the chart's existing
  one-statement Semantics carries the range summary. Screen-reader
  users consume the `WeightHistoryList` below.
- F5 (log weight pre-fill). Lives in UX-109; can ship in parallel.
- Any new chart package or dependency. T-19 stays — only
  `CustomPainter`.
- A pin-to-keep-tooltip-visible gesture. The tooltip fades out
  on release; "tap and hold to inspect" is not in scope.
- Expanded touch (vs hover) handling. Expanded uses
  `MouseRegion`; a touch screen on expanded falls through to the
  parent scroll. Architect §5.1 confirms.

### Acceptance criteria
- [ ] `weight_sparkline.dart` contains `_ScrubGestureWrap` and
      `_ScrubOverlayPainter` (both private to the file).
- [ ] On compact, horizontal-drag-start on the chart emits a
      vertical guideline + floating tooltip; the tooltip's two
      lines render `EEE, MMM d` date + `formatWeightWithUnit(kg,
      unit)`.
- [ ] On expanded, `MouseRegion.onHover` over the chart emits the
      same guideline + tooltip. `onExit` fades them out.
- [ ] Drag end / mouse exit fades the guideline + tooltip out over
      120 ms. `MediaQuery.disableAnimationsOf` bypasses the fade
      (the guideline appears / disappears instantly).
- [ ] Vertical drags over the chart do **not** hijack the parent
      `ListView`'s scroll. Confirmed by a widget test that fires a
      vertical drag inside the chart bounds and asserts the
      `ScrollController.offset` changes.
- [ ] Empty-state chart (zero points): scrub gesture is a no-op
      (the wrap short-circuits when `points.isEmpty`).
- [ ] Chart paint code stays in `CustomPainter` per T-19; no new
      chart package; no `package:web` SVG.
- [ ] The tooltip's weight line honours T-21 (kg / lb / st per
      user pref).
- [ ] Tenants honored: T-12 spirit, T-19, T-20, T-21.

### Tests
- `client/test/features/weight/sparkline_scrub_test.dart`:
  - `horizontal drag emits guideline + tooltip` — pump the
    `WeightSparklineCard` with seeded points; `tester.startGesture`
    at chart center; `moveBy(Offset(20, 0))`; pump; assert
    `find.byKey(const Key('scrub-tooltip'))` finds one widget.
    Release; pump 150 ms; assert the tooltip is gone.
  - `vertical drag does not block parent scroll` — mount the chart
    inside a `ListView` with extra content below.
    `tester.startGesture` at chart center; `moveBy(Offset(0,
    -100))`; release; assert the `ListView`'s
    `ScrollController.offset` changed by ~100 px.
  - `reduce-motion bypasses fade` — pump with `MediaQuery(
    disableAnimations: true, child: ...)`; drag; release; pump
    one frame (NOT the full 150 ms); assert the tooltip is already
    gone (instant disappear, no fade).
  - `empty-state chart has no scrub` — pump with `points: []`;
    drag; pump; assert no tooltip is ever rendered.

### Notes / gotchas
- The `_ScrubOverlayPainter` exposes a stable `Key(`'scrub-tooltip'`)`
  on its parent so widget tests can `find.byKey` it. The painter
  itself can't have a Key (it's not a widget), but the
  `AnimatedBuilder` it sits inside can.
- The horizontal-drag-only `GestureDetector` (vs the vertical-drag
  one) is the load-bearing choice for parent-scroll compatibility.
  Do not use `onPan*` — pan would conflict.
- `HitTestBehavior.translucent` is the other load-bearing knob. If
  the chart's background is `Color(0xFF...)`-painted (i.e., the
  CustomPaint's hit-test returns true), vertical drags get
  swallowed. The `translucent` behavior makes them pass through.
- The 120 ms fade duration is the standard motion token
  (`motion('chart.scrub.in/out')` per architect §5.1). If that
  token isn't defined yet, hard-code `const Duration(milliseconds:
  120)` and add a TODO for token alignment.
- The tooltip's `AppColors.ink`-filled background sits over the
  dashed moving-avg line cleanly; no semitransparent overlay
  needed.
- The chart caps at ~30 points; the linear hit-test scan is fast.
  Do not implement binary search.

---

## UX-109  F5 — Log Weight pre-fill from most-recent history

**Status**: pending
**Priority**: P1
**Effort**: S
**Depends on**: none
**Owns files**:
- `client/lib/features/weight/widgets/log_weight_sheet.dart` (in
  `initState`: read `weightHistoryProvider` first, then
  `meProvider`, then fall through to `Decimal.parse('70')`; seed
  the stepper from the resolved kg value)
- `client/test/features/weight/log_weight_prefill_test.dart` (new
  — three tests covering the three branches of the fall-through)

### Goal
Pre-fill the `LogWeightSheet`'s stepper with the user's most-recent
weight history entry, falling through to `user.currentWeightKg` if
history is empty, then to the existing `Decimal.parse('70')` default
if both are null. The stepper renders in the user's `weightUnit`
per T-21 (already handled by the existing `WeightStepper`); F5
changes only the initial canonical kg seed.

### Context
Architect §5.2 (F5 — the fall-through chain, the `ref.read` vs
`ref.watch` choice, T-21 handling). PM doc §2 F4/F5 (the seed
chain: `weightHistoryProvider.firstOrNull?.weightKg ??
user.currentWeightKg ?? Decimal.parse('70')`). Tenants: **T-21**
(display units — the seed is canonical kg; render is in the user's
unit), **T-17** (Decimal in, formatted out).

### Scope
- [ ] In `_LogWeightSheetState.initState`, replace the current
      seed logic with:
      ```dart
      @override
      void initState() {
        super.initState();
        final history = ref.read(weightHistoryProvider).asData?.value;
        final me = ref.read(meProvider).asData?.value;
        // F5 fall-through per `architect_ux_pack.md` §5.2:
        //   newest history entry → user's current → 70 kg default.
        final seed = history?.isNotEmpty == true
            ? history!.first.weightKg
            : (me?.currentWeightKg ?? Decimal.parse('70'));
        final rounded = seed.round(scale: 1);
        _tenths = (rounded * Decimal.fromInt(10)).toBigInt().toInt();
      }
      ```
      `ref.read` (not `ref.watch`) — the seed is a one-shot read at
      sheet open; mid-edit re-reads would silently overwrite user
      input.

### Out of scope
- The F4 scrub gesture. Lives in UX-108.
- Any change to `WeightStepper`'s render or unit handling — the
  stepper already honours `weightUnitProvider` per T-21.
- Adding a "use my last weight" affordance — the pre-fill is the
  default; the user can adjust before saving.
- Migrating the seed to a Decimal-from-the-start chain. The
  existing `_tenths` integer state stays; only its initial value
  changes.

### Acceptance criteria
- [ ] `LogWeightSheet._LogWeightSheetState.initState` reads
      `weightHistoryProvider` first, then `meProvider`, then falls
      through to `Decimal.parse('70')`. The seed is read via
      `ref.read` (one-shot), not `ref.watch`.
- [ ] When `weightHistoryProvider` is non-empty, the stepper opens
      at the most-recent entry's weight (in the user's display
      unit).
- [ ] When `weightHistoryProvider` is empty AND
      `me.currentWeightKg` is set, the stepper opens at
      `currentWeightKg`.
- [ ] When both are null, the stepper opens at 70 kg (existing
      default).
- [ ] The stepper renders in the user's `weightUnit` (e.g., a
      user with `weightUnit: lb` and a prior 79.6 kg entry sees the
      stepper at `175.5 lb`). T-21 honoured.
- [ ] Tenants honored: T-17, T-21.

### Tests
- `client/test/features/weight/log_weight_prefill_test.dart`:
  - `seed from non-empty history` — pump with seeded
    `weightHistoryProvider` of `[WeightEntry(weightKg:
    Decimal.parse('79.6'), ...)]` and `weightUnit: lb`; open the
    sheet; assert the stepper's display reads ~`"175.5 lb"`.
  - `seed from me.currentWeightKg when history is empty` — pump
    with `weightHistoryProvider: []` and `me.currentWeightKg:
    Decimal.parse('72')`, `weightUnit: kg`; open; assert the
    stepper reads `"72.0 kg"`.
  - `fall-through to 70 kg when both are null` — pump with
    `weightHistoryProvider: []` and `me.currentWeightKg: null`;
    open; assert the stepper reads `"70.0 kg"`.

### Notes / gotchas
- `ref.read` (not `ref.watch`) is load-bearing. A `watch` would
  cause the input to jitter mid-edit if `weightHistoryProvider`
  re-emits (e.g., a background refresh). The seed snapshots once.
- `weightHistoryProvider` is consumed by the weight screen body
  (the source view for the FAB that opens this sheet), so by the
  time the user taps "Log weight", the provider is warm. No async
  wait inside `initState`. The `.asData?.value` falls through to
  null only when the provider is in `loading` / `error` state —
  in which case `me?.currentWeightKg` (also typically warm) takes
  over.
- The `round(scale: 1)` step matches the stepper's resolution
  (tenths of a kg). Do not change without coordinating with
  `WeightStepper`'s internal `_tenths` math.
- This is a one-line behavior change in `initState`. The existing
  test surface for `LogWeightSheet` (save, dismiss, cancel)
  should be unaffected; only the seed test is new.

---

## UX-110  F10 — `weeklyLogDaysProvider` + `_WeekProgressPill`

**Status**: pending
**Priority**: P1
**Effort**: M
**Depends on**: UX-105
**Owns files**:
- `client/lib/repositories/log_repository.dart` (add
  `weeklyLogDayCount()` method per architect §7.2; extend the
  `@invalidates` dartdoc blocks on `create`, `update`, `delete`,
  `copyDay`, `adoptOptimistic` to list `weeklyLogDaysProvider`)
- `client/lib/providers/log_providers.dart` (add
  `weeklyLogDaysProvider` per architect §7.2 — a
  `FutureProvider<int>` that wraps `repo.weeklyLogDayCount()`)
- `client/lib/widgets/ring_summary_card.dart` (add
  `_WeekProgressPill` private widget between the existing ring
  caption and the `MacroBar` row; mount on both compact and
  expanded card paths)
- `client/lib/features/today/widgets/copy_day_sheet.dart` (UX-105
  forward-referenced this in a TODO comment; in this ticket, add
  `ref.invalidate(weeklyLogDaysProvider)` to the `_save` handler's
  invalidation block and delete the TODO)
- `client/test/widgets/ring_summary_card_streak_pill_test.dart`
  (new — four tests: hidden at 0; rendered at 3; accent at 7;
  Semantics matches rendered text)

### Goal
Land F10 — the "N/7 days logged this week" pill rendered inside
`RingSummaryCard`. The metric is days-with-any-log this week
(Monday–Sunday, local time). The pill is hidden at 0; renders
`"This week · $N/7 days logged"` for 1..7; uses accent colour at
7/7 (no animation, no celebration). The pill is read-only (no tap
routing). Data comes from a small dedicated provider
`weeklyLogDaysProvider` that wraps a repository method
`weeklyLogDayCount()`; every `LogRepository` mutator's
`@invalidates` block lists it.

### Context
Architect §7 (Feature F10 deep dive — the metric in §7.1, the
provider in §7.2, the render shape in §7.3, BE-002 in §7.4,
acceptance in §7.5). PM doc §2 F10 ("days logged this week",
Monday–Sunday local, client-side aggregation for v1, no animation
no fire emoji, pill is read-only). The architect's open question on
Mon-vs-Sun week start (architect §12.2) is resolved as Monday — see
the "Architect's open questions → resolution" section. Tenants:
**T-18** (minimal invalidation — every mutator that could change
the week-day-count lists `weeklyLogDaysProvider`), **T-20**
(single Semantics node on the pill).

### Scope
- [ ] In `log_repository.dart`, add `weeklyLogDayCount()` per
      architect §7.2:
      ```dart
      /// Count distinct dates in the current local week (Mon–Sun)
      /// that have at least one log entry. Returns 0..7.
      Future<int> weeklyLogDayCount() async {
        final now = DateTime.now();
        final weekStart = _mondayOfWeek(now);
        final weekEnd = weekStart.add(const Duration(days: 7));
        final entries = _state.where((e) =>
            !e.consumedOn.isBefore(weekStart) &&
            e.consumedOn.isBefore(weekEnd));
        final daysLogged = <int>{};
        for (final e in entries) {
          daysLogged.add(_dayKey(e.consumedOn));
        }
        return daysLogged.length;
      }

      DateTime _mondayOfWeek(DateTime now) {
        final daysSinceMonday = now.weekday - 1;
        // DateTime.weekday: Monday = 1, Sunday = 7.
        return DateTime(now.year, now.month, now.day - daysSinceMonday);
      }

      int _dayKey(DateTime d) => d.year * 1000 + d.day + d.month * 32;
      ```
- [ ] Extend the `@invalidates` dartdoc blocks on the mutators per
      architect §7.2:
      - `create`: add `weeklyLogDaysProvider` line.
      - `update`: add `weeklyLogDaysProvider` line (an update that
        changes `consumed_on` could shift the count).
      - `delete`: add the line.
      - `copyDay`: replace UX-105's forward-referenced TODO with
        the real entry.
      - `adoptOptimistic`: add the line.
- [ ] In `log_providers.dart`, add the provider:
      ```dart
      /// Days with at least one log entry this week
      /// (Mon–Sun local). F10 from architect_ux_pack.md §7.
      final weeklyLogDaysProvider = FutureProvider<int>((ref) {
        final repo = ref.watch(logRepositoryProvider);
        return repo.weeklyLogDayCount();
      });
      ```
- [ ] In `ring_summary_card.dart`, add `_WeekProgressPill` per
      architect §7.3:
      ```dart
      class _WeekProgressPill extends ConsumerWidget {
        const _WeekProgressPill();

        @override
        Widget build(BuildContext context, WidgetRef ref) {
          final countAsync = ref.watch(weeklyLogDaysProvider);
          final count = countAsync.valueOrNull ?? 0;
          if (count == 0) return const SizedBox.shrink();
          final colors = context.colors;
          final isFullWeek = count == 7;
          return Padding(
            padding: EdgeInsets.only(top: context.space.x1),
            child: Semantics(
              container: true,
              label: 'This week, $count of seven days logged',
              excludeSemantics: true,
              child: Text(
                'This week · $count/7 days logged',
                style: context.text.meta.copyWith(
                  color: isFullWeek ? colors.accent : colors.ink2,
                  fontWeight: isFullWeek ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          );
        }
      }
      ```
- [ ] Mount `_WeekProgressPill` between the existing ring caption
      ("of 2,160 today") row and the `MacroBar` row inside
      `RingSummaryCard`'s build. The mount is on both compact and
      expanded card paths (a single widget; both consumers share
      it).
- [ ] In `copy_day_sheet.dart`, add `ref.invalidate(weeklyLogDaysProvider)`
      to the `_save` handler's invalidation block. Delete the
      `// TODO(UX-110): ...` comment from UX-105.

### Out of scope
- BE-002 — the `GET /me/weekly-logging` endpoint. PM doc §9 names
  it as non-blocking; client ships against the in-memory fold for
  v1. When BE-002 lands, the repository's `weeklyLogDayCount`
  swaps to a single GET call and the provider's behavior is
  unchanged. See "Backend coordination" below.
- A "streak history" surface, a "broken streak" notification, or
  any celebratory animation. The PM doc §2 F10 explicitly
  forbids these.
- Tap-to-route on the pill. The pill is read-only.
- A US-cohort Sunday-start week. The architect §12.2 ruling is
  Monday; the swap is one line in `_mondayOfWeek` if a future PMgr
  decision flips it.
- A foreground-resume invalidation for the pill. Architect §7.2
  notes this lives in the same code path that invalidates
  `daySummaryProvider` on `AppLifecycleState.resumed`; if that
  path doesn't yet invalidate `weeklyLogDaysProvider`, add a
  follow-up v1.1 ticket — do not refactor the resume path in this
  ticket.

### Acceptance criteria
- [ ] `LogRepository.weeklyLogDayCount()` exists; returns
      `Future<int>` in 0..7. The Monday-start math matches
      architect §7.2.
- [ ] `weeklyLogDaysProvider` exists in
      `client/lib/providers/log_providers.dart`. Watches
      `logRepositoryProvider`.
- [ ] Every `LogRepository` mutator's `@invalidates` dartdoc block
      lists `weeklyLogDaysProvider`. `grep -rn 'weeklyLogDaysProvider'
      client/lib/repositories/log_repository.dart` returns ≥ 5
      hits (one per mutator: create, update, delete, copyDay,
      adoptOptimistic).
- [ ] `_WeekProgressPill` widget exists inside
      `ring_summary_card.dart` (file-private). Rendered between
      the ring caption and the macro bars on both compact and
      expanded card paths.
- [ ] The pill is hidden when count == 0 (`SizedBox.shrink`).
- [ ] Rendered text: `"This week · N/7 days logged"` for count
      1..7. When count == 7, the `AppColors.accent` colour applies;
      otherwise `colors.ink2`.
- [ ] The pill carries a single Semantics node ("This week, four of
      seven days logged"). The inner Text Semantics are excluded.
- [ ] The pill is not routable on tap (no `InkWell`, no
      `GestureDetector`).
- [ ] `CopyDaySheet._save` invalidates `weeklyLogDaysProvider`
      after `repo.copyDay` succeeds.
- [ ] Tenants honored: T-18, T-20.

### Tests
- `client/test/widgets/ring_summary_card_streak_pill_test.dart`:
  - `pill hidden at 0` — pump `RingSummaryCard` with seeded
    `weeklyLogDaysProvider: 0`; assert `find.textContaining('This
    week')` returns zero widgets.
  - `pill rendered for 3` — pump with `weeklyLogDaysProvider: 3`;
    assert one widget with text `"This week · 3/7 days logged"`.
  - `accent colour at 7` — pump with `weeklyLogDaysProvider: 7`;
    assert the rendered `Text` widget's `style.color ==
    AppColors.accent`.
  - `Semantics announcement matches rendered text` — pump at 4;
    use `tester.getSemantics(find.byType(_WeekProgressPill))`;
    assert the label is `"This week, four of seven days logged"`.

### Notes / gotchas
- The architect §7.2 implementation uses
  `repo.weeklyLogDayCount()` instead of a 7-way fold over
  `logEntriesProvider(date)` family instances. This is the
  rebuild-graph optimization — the pill re-renders only when the
  repository signals a change (via `@invalidates`), not on every
  per-day fan-out.
- The `_dayKey` function in the repository is a unique-per-date
  integer key. The exact formula doesn't matter as long as it
  distinguishes dates; the architect's `d.year * 1000 +
  d.dayOfYear` was illustrative — the impl uses
  `d.year * 1000 + d.month * 32 + d.day` for portability without
  a `dayOfYear` extension.
- The `_mondayOfWeek` math handles wrapping correctly only when
  `daysSinceMonday <= d.day`. Verify the edge: if `now =
  2026-01-01` (a Thursday in 2026), `daysSinceMonday = 3`, and
  `DateTime(2026, 1, 1 - 3) = DateTime(2026, 0, 1) = DateTime(2025,
  12, 29)` — Dart's `DateTime` handles negative day-of-month by
  rolling into the prior month. Verify in tests.
- The pill is forward-referenced by UX-105's `CopyDaySheet._save`.
  This ticket closes the TODO. If UX-105 is not yet in main, the
  TODO comment doesn't exist yet — just add the invalidation line
  directly.
- The provider is named `weeklyLogDaysProvider` (plural "Days") to
  match the metric "days logged this week". Don't rename mid-pack.

---

## UX-111  Theme C — dead-affordance sweep

**Status**: pending
**Priority**: P2
**Effort**: S
**Depends on**: none
**Owns files**:
- `client/lib/features/food/food_detail_screen.dart` (delete the
  `more_horiz` overflow `IconButton` at the named line — the one
  with `onPressed: () {}`; do not add a placeholder)
- `client/lib/features/weight/weight_screen.dart` (delete the
  calendar `IconButton` at line ~152 — the one with `onPressed:
  null`; delete the "See all" `Text` button at line ~300 — the one
  that visually reads as a button but routes nowhere)
- `client/test/features/food/food_detail_no_overflow_test.dart`
  (new — assert the overflow icon is absent from the food detail
  screen tree)
- `client/test/features/weight/weight_screen_dead_affordances_test.dart`
  (new — assert the calendar icon and "See all" text are absent
  from the weight screen tree)

### Goal
Delete the three named no-op affordances in this pack's Theme C
sweep: the `more_horiz` overflow icon on food detail
(`onPressed: () {}`), the calendar icon on weight
(`onPressed: null`), and the "See all" text-button on weight that
routes nowhere. After this ticket, no affordance in the
`features/food/` and `features/weight/` trees has a no-op
`onPressed`. The full-history "See all" route is a v1.1 ticket
(deferred — see Punt list).

### Context
Architect §8 (Theme C — Tappable affordances that do nothing —
the named sites and the grep-sweep recommendation). PM doc §2
Theme C ("delete in v1, restore when wired"). Same shape as QL-006
(bookmark) and QL-007 ("Coming soon" rows). Tenants: **T-20**
(no false affordances — every visible button has a real action).

### Scope
- [ ] In `food_detail_screen.dart:~300`, delete the `more_horiz`
      `IconButton` block. Do not add a placeholder. The action
      row's `Row` children list loses the icon; the remaining
      siblings (whatever the row contains — likely a bookmark or
      a share icon, already cut in QL-006) compact naturally.
- [ ] In `weight_screen.dart:~152`, delete the calendar
      `IconButton` block. If the icon was inside an `AppBar`
      `actions`, the actions list compacts; if it was inside a
      header `Row`, the `Row` compacts.
- [ ] In `weight_screen.dart:~300`, delete the "See all" `Text`
      button. Architect §8 confirms: the 5-row recent entries list
      stays; users with months of data are a small v1 cohort.
- [ ] Mechanical grep for further instances:
      `grep -rn 'onPressed: () {}' client/lib/features/` and
      `grep -rn 'onPressed: null' client/lib/features/` should
      return zero hits after this ticket (or only hits inside
      tests / `Coming soon` blocks already deleted in QL-106).
      If the grep surfaces additional no-op affordances, flag them
      in Notes; do not silently expand scope.

### Out of scope
- The full-history "See all" route on weight. PM doc §2 Theme C
  explicitly defers this to v1.1 alongside a "Trends" surface
  design pass.
- Restoring the `more_horiz` overflow on food detail with a real
  menu (e.g., "Share food", "Edit serving"). v1.1.
- Any change to the bookmark or "Coming soon" rows — those landed
  in QL-006 / QL-007 and are already deleted.

### Acceptance criteria
- [ ] `food_detail_screen.dart` no longer contains a `more_horiz`
      icon with `onPressed: () {}` or `onPressed: null`.
- [ ] `weight_screen.dart` no longer contains a calendar `IconButton`
      with `onPressed: null`.
- [ ] `weight_screen.dart` no longer contains a "See all" text
      affordance.
- [ ] `grep -rn 'onPressed: () {}' client/lib/features/` returns
      zero hits.
- [ ] `grep -rn 'onPressed: null' client/lib/features/` returns
      zero hits (excluding documentation strings or comments).
- [ ] Tenants honored: T-20.

### Tests
- `client/test/features/food/food_detail_no_overflow_test.dart`:
  - `food detail screen has no more_horiz overflow` — pump
    `FoodDetailScreen(foodId: ...)`; assert
    `find.byIcon(Icons.more_horiz)` returns zero widgets inside
    the screen subtree.
- `client/test/features/weight/weight_screen_dead_affordances_test.dart`:
  - `weight screen has no calendar icon` — pump `WeightScreen()`;
    assert `find.byIcon(Icons.calendar_today)` (or
    `Icons.calendar_month`, whichever was the dead icon) returns
    zero widgets.
  - `weight screen has no See all text` — assert
    `find.text('See all')` returns zero widgets.

### Notes / gotchas
- Architect §8 / PM doc §2 Theme C: deletion is the v1 disposition.
  Do not add a `// TODO: restore in v1.1` comment or a placeholder
  widget — the row simply doesn't render the affordance.
- The grep sweep is mechanical. If a third site surfaces (e.g., a
  `goals_screen.dart` no-op found by the grep), delete it in this
  ticket and document in Notes. The PR description should list
  every site deleted.
- This ticket can ship in parallel with everything else; no
  upstream deps. P2 priority — schedules behind the P0 feature
  work but can ship anytime.

---

## UX-112  Cross-cutting polish bundle — Theme D + E + a11y + Goals + (dev) tag

**Status**: pending
**Priority**: P2
**Effort**: M
**Depends on**: none
**Owns files**:
- `client/lib/widgets/snackbar_throttle.dart` (new — ~30 lines, a
  per-screen 3-second cooldown helper; opt-in)
- `client/lib/features/profile/widgets/height_stepper_sheet.dart`
  (Theme D fix: the save handler's button enabled state reads
  `_isDirty()`; track the initial seeded value in state and compare)
- `client/lib/features/profile/widgets/current_weight_sheet.dart`
  (Theme D fix: same shape as `height_stepper_sheet.dart`)
- `client/lib/widgets/top_search_field.dart` (a11y: add
  `Semantics(button: true, label: 'Search foods')` wrapping the
  field if it's not already there — PM doc §6 named the gap)
- `client/lib/widgets/ring_summary_card.dart` (a11y: wrap the
  three `MacroBar`s in a single `MergeSemantics` so the
  screen-reader announcement is one statement)
- `client/lib/widgets/pending_sync_badge.dart` (a11y: wrap the
  badge in a `LiveRegion` so the screen-reader user gets a
  "Synced" announcement on the post-flush fade)
- `client/lib/features/goals/goals_screen.dart` (Goals fix:
  "Edit current" stays `PrimaryButton`; "New goal" becomes
  `OutlinedButton`)
- `client/lib/features/profile/profile_screen.dart` (the "(dev)"
  version tag: thread the build flavour via `pubspec.yaml`'s
  `--dart-define=BUILD_FLAVOUR=...` or equivalent; hide the
  "(dev)" suffix in release builds)
- `client/test/widgets/snackbar_throttle_test.dart` (new —
  asserts stacked-same-error SnackBars within 3s are swallowed)
- `client/test/widgets/ring_summary_card_macro_merge_test.dart`
  (new — asserts the three MacroBars produce one merged
  SemanticsNode)
- `client/test/features/goals/goals_button_hierarchy_test.dart`
  (new — asserts "Edit current" is the primary button and "New
  goal" is the outlined button)

### Goal
Bundle the PM doc's six small cross-cutting items into one ticket:
Theme D narrow fix (disable save when unchanged on
`HeightStepperSheet` and `CurrentWeightSheet`), Theme E
`snackbar_throttle` helper (per-screen 3-second cooldown), three
a11y accepts (`_TopSearchField` button Semantics, `MergeSemantics`
on `MacroBar` row, `LiveRegion` on pending-sync badge), the Goals
"Edit current" / "New goal" button-hierarchy fix, and the "(dev)"
version-tag flavour-wiring. Each item is ~10–30 lines; bundled
because they share the same PR-review attention budget and have
zero shared deps.

### Context
Architect §8 (cross-cutting themes — Theme D narrow fix, Theme E
helper, the three a11y accepts), PM doc §3 (Theme D MODIFIED
mixed-response, Theme E MODIFIED defer the global debouncer ship
the local cooldown), PM doc §6 (Accessibility findings — three
accepts), PM doc §4 (Goals "Edit current" / "New goal" one-line
change), PM doc §4 (Profile "(dev)" version-tag grep). Tenants:
**T-11** (errors inline — the throttle keeps SnackBars from
stacking), **T-20** (a11y minimums), **T-22** (pending-sync visible
— the LiveRegion is the announcement surface), **T-04** (accent on
primary actions — the Goals fix honours the rule).

### Scope
- [ ] **Theme D narrow fix — `HeightStepperSheet` and
      `CurrentWeightSheet`**:
      - In each sheet's state, track the initial seeded value
        (e.g., `_initialCm`, `_initialWeightKg`) at `initState`.
      - The save button's enabled state reads `_isDirty() => _cm
        != _initialCm` (or the weight equivalent).
      - The save button's `onPressed: _isDirty() ? _save : null`.
      - Dartdoc on the save handler: "Disabled when unchanged
        (Theme D narrow fix from PM UX pack §3 Theme D). The
        broader audit + lint rule is v1.1."
- [ ] **Theme E helper — `snackbar_throttle.dart`**:
      - New file at `client/lib/widgets/snackbar_throttle.dart`.
        ~30 lines.
      - Public surface:
        ```dart
        class SnackbarThrottle {
          static const _cooldown = Duration(seconds: 3);
          static final _lastShown = <(BuildContext, String), DateTime>{};

          /// Show a SnackBar, throttling consecutive same-(context, key)
          /// calls within a 3-second window. Used by error paths to
          /// prevent stacked SnackBars on a flaky-network burst.
          static void show(
            BuildContext context,
            SnackBar snackBar, {
            required String key,
          }) {
            final now = DateTime.now();
            final pair = (context, key);
            final last = _lastShown[pair];
            if (last != null && now.difference(last) < _cooldown) {
              return;
            }
            _lastShown[pair] = now;
            ScaffoldMessenger.of(context).showSnackBar(snackBar);
          }
        }
        ```
      - The `context` key part of the throttle key is the screen
        scope; the `key` string is the error code (e.g.,
        `'log-create-failure'`).
      - Opt-in: existing `ScaffoldMessenger.of(context).showSnackBar`
        calls are unchanged. The error paths in UX-105's
        `CopyDaySheet._save` failure block and `LogWeightSheet`'s
        existing save error swap to `SnackbarThrottle.show(...)`.
- [ ] **A11y — `_TopSearchField` button Semantics**:
      - In `top_search_field.dart` (or wherever the field lives —
        likely `client/lib/widgets/top_search_field.dart`), wrap
        the entire field in `Semantics(button: true, label:
        'Search foods')` so screen readers identify it as a
        button.
- [ ] **A11y — `MergeSemantics` on `MacroBar` row**:
      - In `ring_summary_card.dart`, wrap the three `MacroBar`s in
        a single `MergeSemantics(...)`. The screen-reader
        announcement becomes one statement like "Protein 56 of 80
        grams, carbs 120 of 240 grams, fat 33 of 60 grams" instead
        of three.
- [ ] **A11y — `LiveRegion` on pending-sync badge**:
      - In `pending_sync_badge.dart` (or wherever the badge
        widget lives), wrap the badge in `Semantics(liveRegion:
        true, ...)` so the post-flush fade announces "Synced" to
        the screen-reader user.
- [ ] **Goals "Edit current" / "New goal" button hierarchy**:
      - In `goals_screen.dart`'s active-goal card, change the two
        equal-weight `PrimaryButton`s to:
        - "Edit current" stays `PrimaryButton` (accent fill —
          T-04).
        - "New goal" becomes `OutlinedButton` (or whatever
          token-equivalent the design system uses for secondary
          actions).
- [ ] **"(dev)" version tag**:
      - Grep for the "(dev)" suffix in `profile_screen.dart`'s
        version row.
      - Thread the build flavour via a constant or
        `--dart-define=BUILD_FLAVOUR=dev` (architect §8 notes the
        right place is `pubspec.yaml`'s build-runner equivalent,
        but a `const String _buildFlavour = String.fromEnvironment(
        'BUILD_FLAVOUR', defaultValue: 'release')` is the
        single-line shape).
      - Hide the "(dev)" suffix when `_buildFlavour != 'dev'`.

### Out of scope
- The broader Theme D audit (`SexPicker`, `ActivityLevelPicker`,
  any other tap-to-save sheets). PM doc §3 Theme D MODIFIED:
  v1.1.
- The global debounced SnackBar (the architect-led refactor that
  generalises `SnackbarThrottle` into a screen-spanning helper).
  PM doc §3 Theme E MODIFIED: v1.1.
- The `LogEntrySheet` nested-modal serving-select focus trap.
  PM doc §6 DEFER: v1.1.
- A test that asserts the `_TopSearchField` is in the widget tree
  — that's existing test surface. This ticket asserts the
  Semantics wrap.

### Acceptance criteria
- [ ] `HeightStepperSheet`'s save button is disabled when the
      user has not changed the initial seeded value.
- [ ] `CurrentWeightSheet`'s save button is disabled when the
      user has not changed the initial seeded value.
- [ ] `snackbar_throttle.dart` exists. `SnackbarThrottle.show(
      context, snackBar, key: ...)` throttles same-(context, key)
      calls within 3 seconds.
- [ ] `CopyDaySheet._save` failure block uses `SnackbarThrottle.show`
      (not `ScaffoldMessenger.of(context).showSnackBar`
      directly).
- [ ] `LogWeightSheet`'s existing save error path uses
      `SnackbarThrottle.show`.
- [ ] `_TopSearchField` is wrapped in `Semantics(button: true,
      label: 'Search foods')`.
- [ ] The three `MacroBar`s in `RingSummaryCard` are wrapped in a
      single `MergeSemantics`.
- [ ] The pending-sync badge is wrapped in `Semantics(liveRegion:
      true, ...)`.
- [ ] Goals — "Edit current" is `PrimaryButton`; "New goal" is
      `OutlinedButton` (or the secondary-button token).
- [ ] The "(dev)" suffix in `profile_screen.dart` is hidden in
      release builds; visible in dev builds.
- [ ] Tenants honored: T-04, T-11, T-20, T-22.

### Tests
- `client/test/widgets/snackbar_throttle_test.dart`:
  - `stacked same-key calls within 3s are swallowed` — pump a
    test scaffold; `SnackbarThrottle.show(..., key: 'X')` twice
    within 100 ms; assert only one SnackBar renders.
  - `same-key calls after 3s render` — fire once; advance time
    by 4s; fire again; assert two SnackBars rendered.
  - `different keys render independently` — fire twice with
    different keys; assert two SnackBars.
- `client/test/widgets/ring_summary_card_macro_merge_test.dart`:
  - `three MacroBars produce one merged SemanticsNode` — pump
    `RingSummaryCard`; use `tester.getSemantics(find.byType(
    _MacroRow))`; assert the SemanticsNode count under the row is
    1 (post-merge), not 3.
- `client/test/features/goals/goals_button_hierarchy_test.dart`:
  - `Edit current is PrimaryButton` — pump `GoalsScreen` with an
    active goal; assert `find.widgetWithText(PrimaryButton, 'Edit
    current')` finds one widget.
  - `New goal is OutlinedButton` — assert `find.widgetWithText(
    OutlinedButton, 'New goal')` finds one widget.

### Notes / gotchas
- `SnackbarThrottle` uses a static map keyed on `(BuildContext,
  String)`. The context-as-key works because tests pump a fresh
  `BuildContext` per test; in production, the map's `BuildContext`
  entries are GC'd along with the unmounted screens. If the agent
  is uncomfortable with the static-map approach, an alternative
  shape is a `Provider<SnackbarThrottle>` that lives in the
  widget tree — equivalent semantics, more plumbing.
- The `MergeSemantics` wrapper on the macro row is two lines (the
  wrap + the close paren). Test the combined Semantics
  announcement by inspection.
- The `(dev)` flag pattern is `const String _buildFlavour =
  String.fromEnvironment('BUILD_FLAVOUR', defaultValue: 'release')`.
  Build commands (`flutter build apk --dart-define=BUILD_FLAVOUR=
  dev` etc.) honour the override. CI release builds will
  default-to-release because `BUILD_FLAVOUR` is unset.
- Each sub-item in this ticket is small and independent. If the
  agent runs out of time, ship the Theme D + Theme E + a11y
  bundle and split the Goals / (dev) tag items into a follow-up.
  Flag in the PR description.

---

## UX-113  T-12 clarifying rider — FAB long-press menu (doc only)

**Status**: pending
**Priority**: P2
**Effort**: S
**Depends on**: UX-102
**Owns files**:
- `specs/flutter_ui_architecture.md` (§8 T-12 — append the
  one-sentence rider from architect §10.1)
- `specs/flutter_ui_architecture.md` (addendum block at the
  bottom — sibling of the QoL addendum, naming the UX pack and
  noting "T-12 clarifying rider added; no other tenant changes")

### Goal
Optional documentation-only ticket. Add the architect's proposed
one-sentence clarifying rider to T-12 so the FAB long-press menu
precedent (UX-102) is named in the tenant's wording rather than
implicit. If declined, the FAB long-press menu still ships under
the strict reading (architect §10.1 Reading 1) and the next
reader treats UX-102 as the precedent.

### Context
Architect §10.1 (the proposed rider text and the rationale).
Architect §12.5 (PMgr question — accept or decline). PM doc — no
PM ruling either way; architect's recommendation is "ship the
rider; the T-12 surface gets one more sentence and the next sheet
that wants a FAB long-press menu doesn't have to re-litigate."
Tenants: **T-12** (the rider is the tenant edit).

### Scope
- [ ] In `specs/flutter_ui_architecture.md` §8, append to the T-12
      entry the architect's rider text:
      ```
      *T-12 (clarifying rider, 2026-05-16 UX pack). A long-press
      on the FAB may surface a momentary modal menu (e.g.,
      `showMenu`'s popup-route surface) exposing secondary
      actions. The menu is a route-modal, not a floating widget;
      the rule against floating affordances applies to persistent
      ones, not momentary ones.*
      ```
- [ ] Add an addendum block at the bottom of
      `flutter_ui_architecture.md` (sibling of the existing
      2026-05-16 LU addendum + QoL addendum), naming the UX pack:
      "UX pack (2026-05-16): T-12 clarifying rider added per
      `architect_ux_pack.md` §10.1 — the FAB long-press menu in
      UX-102 stays inside T-12 under the route-modal reading. No
      other tenant changes."

### Out of scope
- Any other T-12 wording change. The rider is purely additive.
- Other tenant changes. None planned for this pack.
- Code changes. This ticket is doc-only.

### Acceptance criteria
- [ ] `specs/flutter_ui_architecture.md` §8 T-12 has the rider
      paragraph appended.
- [ ] The bottom-of-doc addendum names the UX pack and the
      rider.
- [ ] No code changes. `git diff --stat` shows only
      `flutter_ui_architecture.md`.
- [ ] Tenants honored: T-12 (the edit).

### Tests
- None. Doc-only ticket.

### Notes / gotchas
- This ticket is optional. If declined, UX-102 still ships and
  the FAB long-press menu is the precedent. The architect's
  recommendation is to ship the rider; the user / PMgr can decline
  without consequence.
- `Depends on: UX-102` because the rider names the menu's
  shipped pattern; documenting it before the pattern ships is
  premature. If UX-102 is still `pending`, this ticket waits.
- Match the format of the QL pack's addendum (2026-05-16): a
  short paragraph naming the pack and the edit, no shape change
  to the tenant numbering.

---

## Dependency graph

```mermaid
flowchart TD
  UX101[UX-101 QuickAddChips lift]
  UX102[UX-102 Avatar cut + bolt to FAB long-press]
  UX103[UX-103 DaySwipeWrap]
  UX104[UX-104 DatePill + chevron removal]
  UX105[UX-105 LogRepository.copyDay + CopyDaySheet]
  UX106[UX-106 MealSection overflow + empty-day Copy from]
  UX107[UX-107 QuickAddChips compact + Today mount]
  UX108[UX-108 Sparkline scrub]
  UX109[UX-109 LogWeightSheet pre-fill]
  UX110[UX-110 weeklyLogDaysProvider + WeekProgressPill]
  UX111[UX-111 Theme C dead-affordance sweep]
  UX112[UX-112 Theme D + E + a11y + Goals + dev-tag]
  UX113[UX-113 T-12 clarifying rider]
  BE002[BE-002 GET /me/weekly-logging endpoint]

  UX101 --> UX107
  UX103 --> UX104
  UX105 --> UX106
  UX105 --> UX110
  UX102 --> UX113

  BE002 -. v1.1 optimisation .-> UX110
```

**Wave 1 (no client deps)**: UX-101, UX-102, UX-103, UX-105,
UX-108, UX-109, UX-111, UX-112.
**Wave 2**: UX-104 (needs UX-103), UX-106 (needs UX-105),
UX-107 (needs UX-101), UX-110 (needs UX-105).
**Wave 3**: UX-113 (needs UX-102, but optional so can slip).

**Longest dependency chain (client-side)**:

```
UX-105 → UX-110
```

Two hops. UX-105 is L, UX-110 is M ≈ 5–7 hours sequential. Every
other chain is one hop (UX-101 → UX-107, UX-103 → UX-104,
UX-105 → UX-106). The pack's critical path is dominated by the
L-effort F1 ticket itself (UX-105), not by chain depth.

---

## Dispatch plan

### Wave 1 — dispatch immediately in parallel

These have no upstream client-side dependencies. Send them at
once across multiple agents:

- **UX-101** — `QuickAddChips` lift (S — pure refactor; lands first
  per architect §1 sequencing).
- **UX-102** — Avatar cut + bolt → FAB long-press menu (M — PR 2
  of the Theme A split).
- **UX-103** — `DaySwipeWrap` gesture (M — PR 3 of the Theme A
  split; independent of UX-102's edits).
- **UX-105** — `LogRepository.copyDay` + `CopyDaySheet` (L — F1
  spine; the largest ticket in the pack).
- **UX-108** — Sparkline scrub (M — F4; independent of all Today
  work).
- **UX-109** — Log weight pre-fill (S — F5; independent).
- **UX-111** — Theme C dead-affordance sweep (S — independent
  cleanup; can ship anytime).
- **UX-112** — Theme D + E + a11y + Goals + (dev) tag bundle (M —
  independent polish; can ship anytime).

UX-101, UX-102, UX-103, UX-105, UX-108, UX-109, UX-111, UX-112 are
file-disjoint across these ten tickets except UX-101 ↔ UX-107 (and
UX-107 is Wave 2). Eight parallel agents could be dispatched at
once; in practice, **4–5 parallel agents** is the realistic ceiling
based on PR-review throughput.

### Wave 2 — dispatch when Wave 1 lands

- **UX-104** — `DatePill` + chevron removal (S — needs UX-103;
  PR 4 of the Theme A split).
- **UX-106** — F1 surfaces: `MealSection` overflow +
  empty-day "Copy from another day" (M — needs UX-105).
- **UX-107** — F2: `QuickAddChips.compact` flag + Today mount (M
  — needs UX-101).
- **UX-110** — F10: `weeklyLogDaysProvider` + `_WeekProgressPill`
  (M — needs UX-105 to close the forward-referenced TODO in
  `CopyDaySheet._save`).

UX-104 / UX-106 / UX-107 / UX-110 are file-disjoint (UX-104 is
`today_internals.dart` + `day_view_compact.dart`'s `_DateBar`;
UX-106 is `meal_section.dart` + `_EmptyDayPill`; UX-107 is
`quick_add_chips.dart` + `_TodayRecentChipsRow` mount; UX-110 is
`log_repository.dart` mutators + `ring_summary_card.dart`). Four
parallel agents.

### Wave 3 — finish

- **UX-113** — T-12 clarifying rider doc (S — optional; needs
  UX-102 for the precedent reference). If user/PMgr declines the
  rider, drop the ticket.

### Strict serial constraints (sequential, NOT parallel)

- **UX-101 and UX-107** — UX-107 imports `QuickAddChips` from the
  new canonical path and extends its API with `compact`. Strict
  serial.
- **UX-103 and UX-104** — UX-104 removes the chevrons; the swipe
  must already be in place per PM doc §2 Theme A gate. Strict
  serial.
- **UX-105 and UX-106** — UX-106 calls `showCopyDaySheet` (defined
  in UX-105). Strict serial.
- **UX-105 and UX-110** — UX-110 closes the forward-referenced
  TODO in UX-105's `CopyDaySheet._save` (the
  `weeklyLogDaysProvider` invalidation). Strict serial.
- **UX-102 and UX-113** — UX-113's rider names the menu shipped in
  UX-102. Strict serial.

### Notes for the dispatcher

- The largest ticket (UX-105) is the single load-bearing piece;
  schedule it first in Wave 1 so its Wave 2 dependents (UX-106,
  UX-110) don't wait on a long-running agent.
- UX-102 / UX-103 / UX-104 are the three-part Theme A split per
  architect §6.5. They can ship in any order Wave-1-to-Wave-2 as
  long as UX-104 follows UX-103. UX-102 is independent of both.
- UX-108 / UX-109 (F4 + F5) form the "weight side" of the pack;
  they ship in parallel with everything else.

---

## Architect's 6 open questions → resolution

The architect surfaced six open questions in `architect_ux_pack.md`
§12. PMgr resolution:

### 12.1 Swipe-day vs chevron-merge ticket split

**Resolved: Option B (two distinct tickets).** Adopting the
architect's recommendation. The swipe-day gesture (UX-103) and the
chevron-merge (UX-104) ship as separate PRs; UX-104 strictly
depends on UX-103 per the PM doc §2 Theme A gate. The swipe
gesture deserves its own test surface
(`day_swipe_gesture_test.dart`) and review attention separate from
the trivial chevron removal. If the agent crew prefers fewer PRs,
the dispatcher can flag UX-103 + UX-104 to a single agent in
Wave 2 — but they ship as two commits referencing the two ticket
IDs.

### 12.2 Streak metric — Mon-vs-Sun start of week

**Resolved: Monday.** The decision is **Monday**, matching the PM
doc §2 F10 ruling ("Monday–Sunday in the user's local time") and
the architect's §7.1 read ("matching the fitness-app convention").
Implemented in `LogRepository._mondayOfWeek` per UX-110. If user
data shows a US-heavy cohort with a Sunday-start mental model, the
flip is one line in `_mondayOfWeek` (rename + adjust
`daysSinceMonday` math); no other surface depends on the choice.
Decision is Monday — no re-litigation inside any UX-1NN ticket.

### 12.3 F2 chip provider — `recentFoodsProvider` vs filtered sibling

**Resolved: `recentFoodsProvider` as-is — no filtered sibling.**
The Quick-add synthetic food is **already excluded** from
`recentFoodsProvider` via the `noteFoodLogged` guard added in
commit `a6ba4cf` ("Quick-add calories feature + stepper two-field
vertical stack"). The architect's concern in §12.3 about Quick-add
synthetic entries showing in the strip is therefore already
addressed at the provider source; UX-107 consumes
`recentFoodsProvider` directly without a filter. **No new provider
needed.** This is the cheapest possible answer: zero new code, zero
new state surface. If future user testing surfaces other unwanted
entries in the strip (e.g., barcode-scanned foods the user opened
once and never logged again), that's a separate v1.1 question with
its own provider design — not in scope for this pack.

### 12.4 The 60-day floor on `CopyDaySheet`'s source-date picker

**Resolved: 60 days, matching QL-009's TodayPill backdate range.**
Adopting the architect's pick. The 60-day floor in
`CopyDaySheet`'s source-date picker (UX-105) and `DatePill`'s date
picker (UX-104) are the same range; QL-009 already shipped the
TodayPill backdate range as 60 days. Symmetry across the three
date-pickers (TodayPill, DatePill, CopyDaySheet) is the right
design. The wire's silent-skip semantics mean an old source with
deleted foods just renders "Skipped: N entries" in the partial-skip
SnackBar — operationally OK. If user testing surfaces demand for
unbounded source-date selection (e.g., "Copy from my Christmas
2025 logs"), it's a one-line change in UX-105's date-picker
`firstDate` — v1.1.

### 12.5 T-12 clarifying rider — accept or decline

**Resolved: ACCEPT, shipped as UX-113 (small doc-only ticket).**
The architect already drafted the rider text (architect §10.1); the
PMgr ships it as UX-113 with `Status: pending`, `Priority: P2`,
`Effort: S`. The rider is purely additive — one sentence appended
to T-12 — and the cost is zero. The benefit: the next sheet that
wants a FAB long-press menu has a named precedent in the tenant's
wording instead of an implicit one in this pack's commit history.
If the user/PMgr declines, drop UX-113; UX-102 still ships under
the strict T-12 reading (architect §10.1 Reading 1) without
prejudice.

### 12.6 The `QuickAddChips` compact-mode flag

**Resolved: Option A — flag on the public widget.** Adopting the
architect's recommendation. UX-107 adds `compact: bool = false` to
`QuickAddChips` and a `_buildCompactStrip` branch in the widget's
build. The single-widget-two-consumers shape is correct per T-15
(the widget picks based on its mode prop; neither consumer screen
picks at its root). Option B (mount only on expanded, lift the
private chip primitive) would double-lift a private leaf and
double the migration cost; rejected. Single widget, two consumers,
two render modes — clean.

---

## Backend coordination

The PM doc flagged **one** backend ticket for this pack:

- **BE-002 — Weekly logging count endpoint** (`GET /me/weekly-logging`
  → `{ week_start, days_logged }`). For UX-110 / F10. **Status**:
  `pending (backend)`. **Non-blocking**: the client ships against
  the in-memory `LogRepository.weeklyLogDayCount()` fold per
  architect §7.2; when BE-002 lands, the repository's method swaps
  to a single `GET` call and the provider's behavior is unchanged.
  No client-side change is required at the swap-over.

**Other backend tickets named by the PM doc §9, NOT in this pack's
scope**:

- **BE-003 — Barcode scan history**. For the deferred scan-history
  v1.1 affordance. Out of scope.
- **BE-004 — Goal achievement status**. For the deferred goal-
  history "achieved" badges (v1.1). Out of scope.

🔗 See `backend_tickets_ledger.md`. The IDs in this section collide
with the barcode pack's BE-002 / BE-003 and the QoL pack's BE-004
lift, so the canonical ledger renumbers them: **BE-002 in this
pack is `BE-005` in the canonical ledger; BE-003 → `BE-006`;
BE-004 → `BE-007`.** Use the canonical IDs in any new work that
references these.

No wire-breaking changes are requested by this pack. The Display
Units Principle holds. The outbox stays scoped to single-entry
`POST /log` per Risk 6. The OpenAPI shape is unchanged. `POST
/log/copy` (the F1 wire) is already shipped per OpenAPI lines
668–698 + the `CopyDayBody` / `CopyDayResponse` schemas at lines
1109–1127; verified by the architect (§3.1) and by the Rust route
at `crates/loseit-core/src/service/log.rs` lines 280–372. No
backend ticket blocks F1.

---

## Definition of done for the pack

When all UX-1NN tickets ship (UX-101..UX-113 client; BE-002
deferred non-blocking), the user opens Today on day 14 and sees:

**Cheaper ritual:**

- The compact header is `[search]` only — no avatar, no bolt
  icon. The FAB exposes "Log food" on short-press, "Quick add
  calories" on long-press (UX-102).
- The date title is a single tappable `DatePill`; the chevrons are
  gone. Per-day navigation is left/right swipe on the day view
  body (UX-103) or a tap on the pill opening a date picker
  (UX-104).
- The `RingSummaryCard`'s center lands within 280 vertical px of
  the safe-area top on a Pixel 4a viewport (UX-102 + UX-104
  cumulative).
- A horizontal-scroll strip of up to 6 recent foods renders
  between the ring and the meal sections, today-only,
  recents-only, hidden when fewer than 4 recents exist (UX-101 +
  UX-107). Tap a chip → `LogEntrySheet` opens pre-seeded with the
  food + the time-of-day meal default.
- Each `MealSection` header has an overflow icon (UX-106) whose
  menu opens a `CopyDaySheet` (UX-105) with the meal pre-selected
  and yesterday pre-loaded as the source. The user reviews the
  preview, taps Save, and lands on Today with the copied entries
  rendered.
- On empty days that are today's day-view, a "Copy from another
  day" secondary affordance renders inside the empty-day pill
  (UX-106). Tap → `CopyDaySheet` opens with no meal filter
  (whole-day copy).

**Visible signal:**

- Inside the `RingSummaryCard`, immediately below the ring caption,
  a `"This week · N/7 days logged"` pill renders when `N >= 1`
  (UX-110). When `N == 7`, the pill renders in accent colour —
  no animation, no fire emoji.
- On the Weight tab, dragging horizontally on the sparkline emits
  a vertical guideline + floating tooltip with the date + weight
  at the nearest data point (UX-108). On web, hover does the same.
  Vertical drags inside the chart pass through to the parent
  scroll.
- The "Log weight" sheet opens pre-filled with the user's most
  recent weight entry, in their display unit (UX-109). The
  stepper defaults to 70 kg only when both history and
  onboarding-step-2 are empty.

**Polish:**

- The `more_horiz` overflow on food detail, the calendar icon on
  weight, and the "See all" text on weight are deleted (UX-111).
- `HeightStepperSheet` and `CurrentWeightSheet` disable their save
  button when the user hasn't changed the seeded value (UX-112
  Theme D narrow fix).
- A `snackbar_throttle.dart` helper exists; `CopyDaySheet` and
  `LogWeightSheet` failure paths use it to prevent stacked
  SnackBars on flaky-network bursts (UX-112 Theme E).
- The Goals card's "Edit current" is `PrimaryButton`; "New goal"
  is `OutlinedButton` (UX-112 Goals fix).
- The "(dev)" version-tag suffix is hidden in release builds
  (UX-112 (dev) tag fix).
- A11y: `_TopSearchField` is wrapped in `Semantics(button: true)`;
  the three `MacroBar`s in `RingSummaryCard` are wrapped in
  `MergeSemantics`; the pending-sync badge is wrapped in
  `Semantics(liveRegion: true)` (UX-112 a11y bundle).

**Tenants:**

- `flutter_ui_architecture.md` §8 T-12 has the clarifying rider
  appended (UX-113, optional). All other tenants unchanged.

**Verification commands** (run by a human or CI, not the agents):

- `flutter test test/features/today/copy_day_sheet_test.dart` —
  four widget tests pass.
- `flutter test test/features/today/recent_chips_row_compact_test.dart`
  — three widget tests pass.
- `flutter test test/features/weight/log_weight_prefill_test.dart`
  — three widget tests pass.
- `flutter test test/features/weight/sparkline_scrub_test.dart` —
  four widget tests pass.
- `flutter test test/widgets/ring_summary_card_streak_pill_test.dart`
  — four widget tests pass.
- `flutter test test/features/today/header_compression_test.dart` —
  two viewport assertions pass.
- `flutter test test/features/today/day_swipe_gesture_test.dart` —
  four swipe scenarios pass.
- `flutter test test/features/today/date_pill_test.dart` — three
  pill-tap scenarios pass.
- `flutter test test/features/today/empty_day_copy_from_test.dart`
  — three empty-day-pill scenarios pass.
- `flutter test test/widgets/meal_section_copy_overflow_test.dart`
  — three overflow scenarios pass.
- `flutter test test/repositories/log_repository_copy_day_test.dart`
  — six repository-mock scenarios pass.
- `grep -rn 'onPressed: () {}' client/lib/features/` — zero hits.
- `grep -rn 'onPressed: null' client/lib/features/weight/` — zero
  hits.
- `grep -rn '@invalidates' client/lib/repositories/log_repository.dart`
  — ≥ 5 hits (UX-110 extends every mutator's block).
- Manual: walk F1's two surfaces (per-meal overflow on a populated
  meal; empty-day "Copy from another day") and confirm the sheet
  + save + post-save SnackBar.
- Manual: open Today on a Pixel 4a; confirm the ring's top edge is
  within 280 px of the safe-area top.
- Manual: drag horizontally on the sparkline; confirm guideline
  + tooltip render and fade.
- Manual: open "Log weight"; confirm the stepper pre-fills from
  the most recent entry.

**Deploy:**

- The GitHub Pages deploy at
  `https://sdstolworthy.github.io/fulfilled/app/` stays green
  through the UX pool.
- This `dev_tickets_ux_pack.md` reflects the final state: every
  shipped ticket has `Status: done`; any partial/blocked ticket has
  the failure mode in its Notes section so morning continuation is
  obvious. BE-002 stays `pending (backend)`; UX-113 stays
  `pending` or moves to `pending-pm` if user/PMgr declines the
  rider.

---

## Per-item map — UX-1NN → PM items + architect sections

| Ticket | PM doc items covered | Architect section |
|---|---|---|
| UX-101 | F2 prerequisite (lift), T-23 enforcement | §2 (Refactor 1) |
| UX-102 | Theme A avatar cut + bolt-to-FAB | §6.1, §6.2, §6.6 PR 2 |
| UX-103 | Theme A swipe-day gesture | §6.4, §6.5, §6.6 PR 3 |
| UX-104 | Theme A chevron-merge + DatePill | §6.3, §6.5, §6.6 PR 4 |
| UX-105 | F1 spine (sheet + repository) | §3.1–§3.5 |
| UX-106 | F1 surfaces (overflow + empty-day) | §3.4 (A) + §3.4 (B) |
| UX-107 | F2 (compact strip mount) | §4.1–§4.6 |
| UX-108 | F4 (sparkline scrub) | §5.1 |
| UX-109 | F5 (log weight pre-fill) | §5.2 |
| UX-110 | F10 (streak pill) | §7.1–§7.5 |
| UX-111 | Theme C (dead-affordance sweep) | §8 |
| UX-112 | Theme D narrow fix, Theme E throttle, three a11y accepts, Goals, (dev) tag | §8 |
| UX-113 | T-12 clarifying rider (optional) | §10.1 |
| BE-002 | (pending backend) weekly-logging endpoint | §7.4 — non-blocking |

Every PM doc item in `pm_ux_pack.md` §2 (the five deep-dive items
plus Theme A) and the cross-cutting accepts/modifications in §3 +
the accessibility accepts in §6 are covered by a UX-1NN ticket or
explicitly punted to v1.1 (the deferrals in PM doc §10).

---

## Punt list — deferred to v1.1 or v2

Explicit deferrals the pack inherits from PM doc §10 + architect's
flags:

- **F3 (fits-in-your-day badge on Food detail).** v1.1 — pairs
  with a goal-day macros sibling.
- **F6 / F7 / F8 (water / photo / exercise).** v2 — non-food-entry
  category, designed as a coherent group.
- **F9 (favourites).** v1.1 — observe F1 usage first.
- **F2 recency-quantity-seed for `LogEntrySheet` open.** v1.1
  (architect §4.4 deferred — requires a new
  `recentFoodLogsProvider` or sibling).
- **F2 `canCopyMeal` predicate (the 14-day window cap).** v1.1
  (UX-106 ships without it; overflow icon always enabled).
- **Theme D broader audit + lint rule** (SexPicker /
  ActivityLevelPicker / etc.). v1.1.
- **Theme E global debounced SnackBar refactor.** v1.1 (UX-112
  ships the per-screen `SnackbarThrottle` helper).
- **Theme F medium-breakpoint design pass.** v1.1.
- **Theme G one-line tip below the ring on day 2.** v1.1 (after
  F10's pill ships and the real estate settles).
- **Full weight history route ("See all" wired).** v1.1 (UX-111
  cuts the stub).
- **Restore the `more_horiz` overflow on food detail with a real
  menu.** v1.1.
- **Search screen improvements** (loading transition signal, focus
  restoration, common-foods-on-empty-query). v1.1 — bundled.
- **Log entry sheet shape changes** (preview above fold, opt-in
  note, inline serving select). v1.1 — its own pack.
- **Custom food per-serving entry mode toggle.** v1.1.
- **Top-bar `_TopSearchField` on expanded shape fix.** v1.1.
- **Empty meal cards at half-height on expanded grid.** v1.1.
- **Onboarding niceties** (step count tag, side-by-side rate
  comparison, hide Start Over on step 1). v1.1.
- **Profile splits** (immutable identity vs measurements). v1.1.
- **Quick-add row naming.** v1.1.
- **Goal-history "achieved" badges.** v1.1 (depends on BE-004).
- **Goal rate in customer-expected units (lb/week, st/week).**
  REJECTED for v1; explicit prior PM ruling stays.
- **Scan history.** v1.1 (depends on BE-003).
- **Profile identity Edit / Export data rows.** v2 (auth, export
  design).
- **Trends tab.** v2 (PM Risk 3 stays resolved).
- **Dark mode.** v2 (PM Risk 5 stays resolved).

---

## Failure protocol

A ticket may fail mid-session. The protocol:

1. **Do not commit partial work** that puts the tree in a broken
   state. Agents don't run `flutter analyze` / `flutter test`,
   but a half-deleted file or an unresolved import is obvious on
   inspection — leave the workspace clean.
2. **Update the ticket Status** to `blocked-needs-pm` in this
   doc.
3. **Write the failure mode in the ticket's Notes / gotchas
   section**, briefly:
   - What you tried.
   - What broke (compile error, missing dependency, ambiguous
     spec, etc.).
   - What a follow-up agent or human reviewer should look at
     next.
4. **Move on** to the next available ticket in the pool. Do not
   keep retrying.
5. **Do not block other tickets** waiting for the blocked one.
   If downstream tickets can proceed without the blocked work,
   run them (the dependency graph above is the authority).

A ticket that succeeds: update Status to `done`, commit the work
with a message referencing the ticket ID (`UX-NNN: <short
title>`), and the next agent will move on.

A ticket that succeeds *but* surfaces follow-up work for v1.1:
add a new ticket at the bottom of this doc with `Status:
pending-pm` and a brief note. Do not silently expand the current
ticket's scope.
