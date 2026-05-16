# Architect — UX Pack

Implementation contract for `specs/pm_ux_pack.md`. PM has ruled scope and
direction on the cheaper-ritual / visible-signal pack: F1 copy-day, F2
recent-foods chip strip on compact, F4 sparkline scrub, F5 weight log
pre-fill, F10 weekly-logging pill, plus the Theme A compact-header
compression. This doc translates that into file-level seams, function
signatures, widget shapes, provider invalidation lists, and acceptance
criteria the technical program manager can carve into developer tickets
without re-asking.

The prior docs are the tiebreakers above this one:
`specs/flutter_ui_architecture.md` (24 tenants — T-12 FAB, T-14
routes-vs-sheets, T-15 form-factor-at-root, T-18 minimal invalidation,
T-19 no chart deps, T-20 a11y minimums, T-23 lifted-widget package
imports, T-24 post-mutation navigation),
`specs/architect_qol.md` (the T-24 cases + the `@invalidates` doc-tag
convention + `pathForDay`), `specs/architect_log_edit_and_units.md` (the
`formatWeight` / `formatWeightWithUnit` seam and the per-axis provider
pattern), and `specs/pm_ux_pack.md` (the sequencing, the
accept/modified/defer rulings, the anti-recommendations). Where this
doc names a behaviour and any prior doc disagrees, the prior doc wins.

I read every file PM inventoried: the today feature folder
(`today_screen.dart`, `day_view_compact.dart`, `day_view_expanded.dart`,
`today_internals.dart`, `widgets/quick_add_chips.dart`), the lifted
primitives (`meal_section.dart`, `ring_summary_card.dart`,
`empty_state.dart`, `primary_button.dart`), the weight surface
(`weight_sparkline.dart`, `log_weight_sheet.dart`,
`weight_history_list.dart`), the repository (`log_repository.dart`), the
providers (`log_providers.dart`, `weight_providers.dart`,
`food_providers.dart`), and the `POST /log/copy` route in
`crates/loseit-core/src/service/log.rs`. The plan compiles in my head;
I expect dev tickets to compile on an agent's machine without surprise.
Two genuine open questions for PMgr live in §12; one of them (whether
swipe-day is its own ticket or merged with chevron-compression) actually
changes the PR shape, so I make a recommendation in §6 and flag it in
§12.

---

## 1. Architectural overview

**Shape of the pack.** Five client-only features sitting on top of one
small refactor and one widget lift. Wire surface: `POST /log/copy` (F1)
— already shipped, lines 668–698 of `specs/openapi.yaml`. Read surface:
`recentFoodsProvider` (F2), `weightHistoryProvider` (F4 + F5),
`logEntriesProvider` family (F10). No new repository write methods
beyond `copyDay`. No new pub deps. No new tenants — T-24 is still the
most recent, still load-bearing, and the FAB long-press menu does not
violate T-12 (the long-press menu materialises as a `PopupMenuButton`
anchored on the FAB; per the PM ruling in `pm_qol_audit.md` Theme A,
exposing a second action on the FAB stays inside T-12's "the FAB is
the only floating action" envelope — see §10 for the explicit reading).

**PM refinements — accept / push back.** PM made seven concrete
refinements on the UX review's instincts; I accept each as stated with
one push-back. (a) F1 — two affordances, one sheet, one wire call:
**accept**. (b) F2 — pre-seeded `LogEntrySheet` not one-tap commit,
recents-not-frequents ordering, today-only render gate: **accept**. (c)
F4 — drag-not-long-press on compact, hover on web, painter-only
extension: **accept**. (d) F5 — fall-through seed
`history.firstOrNull ?? user.currentWeightKg ?? default`: **accept**.
(e) F10 — client-side aggregation, "days logged this week" not
consecutive streak, hidden at 0/7, no animation: **accept**, with one
implementation refinement (§7: a tiny `weeklyLogDaysProvider` keyed
implicitly on local-now rather than 7 separate `logEntriesProvider`
watches, to keep the fold cheap and the rebuild graph thin). (f) Theme
A — avatar cut, bolt → FAB long-press, chevrons collapsed: **accept**,
with one push-back (§6: I recommend the swipe-day gesture and the
chevron-merge ship as **two distinct tickets** with the chevron-merge
gated on swipe-day being in main first — PM blessed the gate; I'm
naming the ticket split as the cleanest implementation of it). (g)
Theme G mostly deferred: **accept**.

**Sequencing.** PM-recommended order holds with one tightening: lift
`QuickAddChips` to `lib/widgets/` *as its own PR before any feature work
that consumes it*. The lift has two future consumers (Today expanded
right rail — already consumes — and Today compact — F2 adds the second
consumer), which trips T-23 the moment F2's compact strip ships.
Landing the lift first means F2 is purely additive: one new mount
site, one new consumer, no concurrent refactor inside the F2 PR. The
critical-path order:

1. **PR 1 — `QuickAddChips` lift** (§2). Pure refactor. Today
   expanded continues importing from `lib/widgets/`; the import path
   updates; the inventory comment in `flutter_ui_architecture.md` §3
   gets a new entry.
2. **PR 2 — Theme A header compression** (§6). The avatar cut + the
   FAB long-press menu + the chevron-merge-stub (chevrons stay but get
   wrapped in a single `DatePill` widget that on tap opens the date
   picker AND keeps the chevrons visible as a fallback affordance).
3. **PR 3 — Swipe-day gesture** (§6). Independent ticket. Once landed,
   PR 4 collapses the chevrons.
4. **PR 4 — Chevron-merge final** (§6). Removes the visible chevrons
   from `_DateBar`; the `DatePill` is the only date affordance.
5. **PR 5 — F2 recent-foods chip strip on compact** (§4).
6. **PR 6 — F1 copy-day** (§3). Both surfaces (per-meal overflow +
   empty-day row) plus `CopyDaySheet` plus `LogRepository.copyDay`
   plus the two new providers. The largest PR in the pack.
7. **PR 7 — F4 + F5** (§5). Independent of the Today work; ships
   parallel with PR 2..6.
8. **PR 8 — F10 streak pill** (§7).

PR 7 is parallelisable from day one; everything else is sequential
along the Today axis because the surfaces stack. Total ~8 PRs across
~2 weeks of agent work, ~3 PR-bundles if the PMgr wants to consolidate
the cleanup.

**No new tenants.** T-24 covers the post-save routing of `CopyDaySheet`
(Case 2 — route-to-effect, `pathForDay(targetDate)`). T-23 covers the
`QuickAddChips` lift. T-12 covers the FAB long-press menu (with one
PMgr-facing read in §10). T-15 covers the chip strip's compact-only
mount (the day view's `_buildBody` is the screen root, not a leaf).
T-19 covers the sparkline scrub (still `CustomPainter`, no chart
package). T-21 covers the F4 tooltip's weight unit. T-20 covers every
new Semantics label. There is no architecture-spec surface change.

---

## 2. Refactor — `QuickAddChips` lift (T-23)

### 2.1 Why the lift is required now

The widget lives at
`client/lib/features/today/widgets/quick_add_chips.dart` today. It is
imported by exactly one consumer:
`client/lib/features/today/day_view_expanded.dart`'s right-rail column.
Until F2 ships, one consumer = feature-local widget = T-23 compliant.

The moment F2 lands, the second consumer is
`client/lib/features/today/day_view_compact.dart`'s sliver list
(between `RingSummaryCard` and the first `MealSection`). Two consumers
inside the same feature folder is fine per T-23's literal reading —
the rule names *cross-feature* import. But there's a stronger reason
to lift: this widget is in the §3 component inventory (`QuickChipRow`
in the architecture doc, lines 153 of `flutter_ui_architecture.md`)
and the inventory commits to `lib/widgets/<name>.dart`. The expanded
right rail's import path today is
`import 'widgets/quick_add_chips.dart';`; after the lift it becomes
`import 'package:fulfilled/widgets/quick_add_chips.dart';` — the same
canonical-import shape as `meal_section.dart`, `ring_summary_card.dart`,
`empty_state.dart`, etc. The lift is the *correct* refactor; doing it
inside F2's PR is the wrong place because the refactor + the new
consumer in one PR are two separable changes.

Architect call: **lift first as a standalone PR**, then F2 is purely
additive against the lifted shape. PM agrees in §8 ordering of the
pack ("Lift `QuickAddChips` to `lib/widgets/`, expose on compact"); I
am naming it as PR 1 explicitly.

### 2.2 The migration

**File deletions / creations.**

- **Delete**:
  `client/lib/features/today/widgets/quick_add_chips.dart`.
- **Create**:
  `client/lib/widgets/quick_add_chips.dart` — verbatim copy of the
  current file, with one import-path adjustment (the relative imports
  for `domain/food.dart`, `domain/units/energy.dart`,
  `routing/routes.dart`, `theme/context_extensions.dart`,
  `widgets/empty_state.dart`, `widgets/primary_button.dart` change
  from `../../../<path>.dart` to `../<domain|routing|theme|widgets>/<path>.dart`).

The widget *contract* (constructor, fields, render shape) is
unchanged. The body still composes the eyebrow + the section headers +
the chip wrap. F2's compact mount will pass a different render mode
(see §4.3 for the parameter), but the lift PR doesn't add that mode —
it's a pure file move.

**Import rewrites.**

`client/lib/features/today/day_view_expanded.dart` — one import line
swaps from:

```dart
import 'widgets/quick_add_chips.dart';
```

to:

```dart
import 'package:fulfilled/widgets/quick_add_chips.dart';
```

Verified by `grep -rn "features/today/widgets/quick_add_chips"
client/lib`. One hit. The lift PR's only call-site change.

**Test moves.**

`client/test/features/today/quick_add_chips_test.dart` (if present)
moves to `client/test/widgets/quick_add_chips_test.dart`. The test
file's `import` of the widget changes from
`package:fulfilled/features/today/widgets/quick_add_chips.dart` to
`package:fulfilled/widgets/quick_add_chips.dart`. Per
`flutter_ui_architecture.md` Appendix's directory layout:
"`test/widget/` — golden tests per widget, both breakpoints." This is
the canonical location.

**Inventory comment.**

`flutter_ui_architecture.md` §3 row for `QuickChipRow` (line 153) gets
its "Used by" column extended: today reads "02 (mobile), 01-W (right
rail)"; after F2 the entry reads "01 compact (between ring + meals),
01-W (right rail), 02 (mobile)". The lift PR adds nothing more — the
entry already exists in the inventory; F2's PR extends the usage list.

**One thing the lift PR does NOT do.** It does not rename
`QuickAddChips → QuickChipRow` to match the inventory's name. The
component-inventory entry calls the row `QuickChipRow` but the
shipped widget is `QuickAddChips`. PM doc didn't name the rename;
architect call: defer the rename to a v1.1 spec-vs-code reconciliation
sweep. The lift's bar is "make F2 additive against the lifted shape,"
not "fix every drift between the inventory and the code." Naming the
deferral here so the next reader knows it was considered.

### 2.3 Acceptance criteria — Refactor 1

- `client/lib/widgets/quick_add_chips.dart` exists; it is a verbatim
  copy of the old feature-local file with adjusted relative imports.
- `client/lib/features/today/widgets/quick_add_chips.dart` does not
  exist. (`git mv` is fine for the diff shape; the contents of the
  destination match modulo import paths.)
- `day_view_expanded.dart`'s import has migrated to
  `package:fulfilled/widgets/quick_add_chips.dart`.
- `grep -rn "features/today/widgets/quick_add_chips" client/lib/
  client/test/` returns zero hits.
- Every test that previously mounted `QuickAddChips` continues to
  pass against the new import path.
- The widget's public API (constructor, props, render) is unchanged.
  Visual regression on the today-expanded right rail is zero.

---

## 3. Feature F1 — Copy yesterday's meal (deep dive)

### 3.1 Wire shape

`POST /log/copy` — already shipped. The schemas from
`specs/openapi.yaml` (the architect cites lines for the dev ticket
authors):

**Request body — `CopyDayBody`** (lines 1109–1120):

```yaml
CopyDayBody:
  type: object
  required: [from_date, to_date]
  properties:
    from_date: { type: string, format: date }
    to_date: { type: string, format: date }
    meal:
      oneOf:
        - $ref: "#/components/schemas/Meal"
        - type: "null"
      description: If present, only entries with this meal are copied.
```

**Response — `CopyDayResponse`** (lines 1121–1127):

```yaml
CopyDayResponse:
  type: object
  required: [copied]
  properties:
    copied:
      type: array
      items: { $ref: "#/components/schemas/LogEntry" }
```

**Route** — `POST /log/copy` (lines 668–698). Status 201 on success;
400 / 401 on the usual paths.

**Server contract — three rules the client relies on** (lines
673–687):

1. **Server recomputes snapshots from current food state.** The
   nutrition fields on each returned `LogEntry` reflect the food's
   *current* `nutritionPer100g` × `serving.grams` × `quantity`, not
   the source entry's frozen snapshot. The client never sends
   snapshots; the client never duplicates the math.
2. **Silent skips for missing food / deleted serving.** Entries
   whose food is no longer visible (cross-tenant or deleted) or
   whose serving was removed are dropped. The wire envelope is
   `{copied: [...]}` precisely so a future `skipped` field can be
   added without breaking clients. The skip is surfaced by the
   client as `created.length < source.length`.
3. **`from_date == to_date` and `from_date > to_date` are both
   legal.** No error for "backward" copy; the client doesn't need to
   guard against it. (This is why a future "duplicate today" UI is a
   trivial extension — same endpoint, same shape.)

The server-side Rust code at `crates/loseit-core/src/service/log.rs`
lines 280–372 implements this; verified by reading. No backend ticket
blocks F1.

### 3.2 Repository — `LogRepository.copyDay`

New method on `client/lib/repositories/log_repository.dart`. Signature:

```dart
/// Copy every entry from [sourceDate] to [targetDate], optionally
/// filtered by [meals]. Mirrors `POST /log/copy` from the OpenAPI doc
/// (`copy_log_day`, lines 668–698).
///
/// **Server contract.** The wire snapshots are recomputed from the
/// *current* food state — the client never sends nutrition snapshots
/// for copied entries, and a custom food edited between [sourceDate]
/// and [targetDate] is reflected in the copy verbatim. Entries whose
/// food is no longer visible or whose serving was deleted are
/// silently skipped; the response contains only the successfully
/// copied entries. The UI surfaces partial-skip via
/// `created.length < requested.length`.
///
/// [meals] is null → copy every meal (whole-day copy). A non-null
/// list filters source entries to those whose `meal` is contained.
/// The wire accepts a single `meal` field (the union of the list);
/// the mock implementation iterates per-meal and concatenates.
///
/// `@invalidates`
/// - `daySummaryProvider(targetDate)` — the ring + summary card for
///   the destination day.
/// - `logEntriesProvider(targetDate)` — the meal section list for
///   the destination day.
/// - `recentFoodsProvider` — the copied foods bump rank.
/// - `frequentFoodsProvider` — the copied foods' frequency ticks.
/// - `weeklyLogDaysProvider` — the target day may flip from
///   zero-entries to one+, affecting the 0–7 week count (§7).
///
/// Notably **not** invalidated: `daySummaryProvider(sourceDate)` /
/// `logEntriesProvider(sourceDate)` — the source day is read-only.
/// The wire never mutates `from_date`.
///
/// Call sites are responsible for invalidating per T-18 (minimal +
/// explicit); this list is the **contract** the call site reads.
Future<List<LogEntry>> copyDay({
  required DateTime sourceDate,
  required DateTime targetDate,
  List<Meal>? meals,
});
```

**Mock semantics** (the in-memory implementation in `log_repository.dart`'s
mock body):

1. Filter `_state` by `consumedOn == sourceDate` AND
   `meals == null || meals.contains(entry.meal)`.
2. For each source entry, look up the food via
   `_foodRepo.lookup(entry.foodId)`. If missing — silently skip (the
   wire contract).
3. For each survivor, look up the serving via
   `food.servings.firstWhere(s => s.id == entry.servingId)`. If
   missing — silently skip.
4. Construct a new `LogEntry` via `computeLogEntry(...)` — the same
   path `create` uses, against the *current* `food` (not the source
   entry's frozen snapshot). The new entry's `consumedOn` is
   `targetDate` (normalised to Y/M/D); `createdAt` is `now`.
5. Append each surviving new entry to `_state` and to a local
   `created` list. Call `_foodRepo.noteFoodLogged(food.id)` for each
   one so the recents-and-frequents rankings update.
6. Return `created`. Partial-skip is implicit in
   `created.length < filtered.length`; the UI computes the requested
   count from the source meal-filter and compares.

The repository **does not** route through the outbox. Per
`pm_ux_pack.md` §2 F1 acceptance ("The outbox does **not** queue
`/log/copy` requests") — the outbox is scoped to single-entry POSTs
per the architecture spec §5 "Outbox (mobile-only)", and a multi-entry
copy is online-only. The compact `LogRepository` instance has an
`_outbox` field but `copyDay` doesn't touch it; the method runs the
same way on compact, medium, and expanded.

### 3.3 Provider invalidation list

The `CopyDaySheet.save` handler invalidates (per the `@invalidates`
block on `copyDay`):

```dart
ref
  ..invalidate(daySummaryProvider(targetDate))
  ..invalidate(logEntriesProvider(targetDate))
  ..invalidate(recentFoodsProvider)
  ..invalidate(frequentFoodsProvider)
  ..invalidate(weeklyLogDaysProvider);
```

Source-date providers are **not** invalidated — `sourceDate`'s data
doesn't change. This mirrors the model from QL-101 / the QoL pack: an
edit that *shifts* a date invalidates both source-and-target dates
because the entry leaves one and lands on the other; a *copy* leaves
the source intact and adds to the target. The doctag list on
`copyDay` enumerates exactly the target-side dependents; the
call-site comment names the pattern: "Source-date invalidation
omitted — the source is read-only in copy semantics (T-18)."

### 3.4 UI surfaces

**(A) Per-meal overflow in `MealSection` header.**

`client/lib/widgets/meal_section.dart` — the `_Header` class today
renders dot + meal name + kcal-right-aligned. After F1 it grows a
trailing 36 × 36 overflow icon (`IconButton36` from the inventory)
whose menu (`showMenu` anchored on the icon) contains one item:
"Copy from yesterday" when the day-1-before-target has entries in
this meal, "Copy from…" otherwise. Tap routes to `showCopyDaySheet`
with `(sourceMeal: meal, targetDate: parent.date)` pre-seeded.

The `MealSection` constructor gains:

```dart
class MealSection extends StatelessWidget {
  const MealSection({
    required this.subtotal,
    required this.entries,
    required this.onAddTap,
    this.dense = false,
    this.onEntryTap,
    this.isPendingSync,
    // NEW for F1:
    this.onCopyMeal,        // null → no overflow icon rendered
    this.canCopyMeal,       // optional predicate (default: always true)
    super.key,
  });
  // ...
  /// Tap on the meal-header overflow's "Copy from yesterday" item.
  /// Null = the overflow icon is not rendered. Threaded from the
  /// day view's `_MealsSliver` which knows `pathForDay(date - 1)` and
  /// the `recentFoodsProvider`-derived predicate (or its replacement —
  /// see §12.3).
  final void Function(Meal meal)? onCopyMeal;

  /// Optional predicate that gates the overflow icon's *enabled* state
  /// (icon greyed when false). Null = enabled. Architect §3.4 — the
  /// icon stays *visible* but disabled when yesterday's same-meal is
  /// empty; tap then opens the sheet with a different default source.
  final bool Function(Meal meal)? canCopyMeal;
}
```

The internal `_Header` reads `onCopyMeal` from the enclosing
`MealSection` (passed through). When null, the overflow is not
rendered — preserving the current visual on test fixtures that don't
opt in. When non-null, the overflow icon renders to the right of the
kcal total, separated by `space.x2`. The kcal total moves left by the
icon's width (36 px) to make room; on the cramped expanded grid
layout this is < 5% of the card's width and visual regression is
acceptable.

**(B) Empty-day "Copy from another day" row.**

`client/lib/features/today/day_view_compact.dart`'s `_EmptyDayPill`
gains a second affordance below the existing "Log a food" button. The
PM spec is explicit (§2 F1 AC): "render a `_CopyFromDayRow` between
the existing empty-day pill and the meal sections". My read: the
pill itself houses both CTAs, vertically stacked. The primary
("Log a food") stays primary; "Copy from another day" is a
text-shaped secondary affordance below it (`OutlinedButton`-styled, or
a `TextButton` with a `chevron_right` icon — architect picks
`TextButton` with `chevron_right` for the lightest visual weight).

The condition gating the second affordance is the same as the
pill itself: `entries.isEmpty && isLocalNowDay(date)`. The PM ruled
"only renders when the *current* day is empty" — backdated empty
days do not get the second affordance. The reason is in §2 F1
"otherwise the per-meal affordance is the right scope". I honour
that gate.

Render shape (inside the existing `EmptyState` widget's `action`
slot — the `EmptyState` already accepts a single `action`, and the
two CTAs are vertically stacked inside a `Column`):

```dart
EmptyState(
  key: const Key('empty-day-pill'),
  icon: Icons.eco_outlined,
  title: 'No food logged for this day',
  body: '',
  action: Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      SizedBox(
        width: 200,
        child: PrimaryButton(
          dense: true,
          label: 'Log a food',
          onPressed: () => context.push(Routes.foodsSearchPath),
        ),
      ),
      SizedBox(height: context.space.x2),
      TextButton(
        key: const Key('empty-day-copy-from'),
        onPressed: () => showCopyDaySheet(
          context,
          ref,
          targetDate: date,
          // No source-meal: opens with All-meals pre-selected.
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: const <Widget>[
            Text('Copy from another day'),
            SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 16),
          ],
        ),
      ),
    ],
  ),
)
```

The `EmptyState` widget's `action` parameter already accepts a
`Widget?` — no widget-level change to `EmptyState`. The
`_EmptyDayPill` becomes a `ConsumerWidget` (it needs `ref` to invoke
`showCopyDaySheet`); today it's `StatelessWidget` reading no
providers. Mechanical conversion.

**(C) `CopyDaySheet` — the new widget.**

`client/lib/features/today/widgets/copy_day_sheet.dart` (new file —
feature-local because it's a Today-only surface; not lifted to
`lib/widgets/` because no other feature mounts it). Public surface:

```dart
/// Bottom sheet (compact) / dialog (expanded) shaped form for
/// `POST /log/copy`. F1 from `architect_ux_pack.md` / PM UX pack
/// §2 F1.
///
/// Two entry points:
///
/// 1. **Per-meal copy** — from `MealSection.onCopyMeal`. The sheet
///    opens with `sourceMeal` pre-selected as a single chip. The user
///    may broaden to "All meals" or pick a different single meal; the
///    sheet's date stepper defaults to `targetDate - 1`.
/// 2. **Whole-day copy** — from `_EmptyDayPill`'s "Copy from another
///    day" affordance. The sheet opens with no meal filter (all five
///    meal chips selected) and the date stepper at `targetDate - 1`.
///
/// **Post-save (T-24 Case 2 — route-to-effect).** On success,
/// `Navigator.pop()` the sheet/dialog then `context.go(
/// pathForDay(targetDate))`. The dialog-on-expanded pop-first rule
/// from T-24 applies (architect_qol.md §3.3).
///
/// **Partial-skip** (server contract — see openapi.yaml lines
/// 679–687): when `result.length < requestedCount`, the SnackBar
/// reads `"Copied N of M — N' skipped (food no longer available)"`.
/// Sheet still closes; user lands on Today with the partial copy
/// applied.
///
/// **Failure** (T-11): SnackBar with retry affordance; sheet stays
/// open with input intact. Submit re-enables.
Future<void> showCopyDaySheet(
  BuildContext context,
  WidgetRef ref, {
  required DateTime targetDate,
  Meal? sourceMeal,
});
```

The body shape (a single `ConsumerStatefulWidget` inside the file):

1. **Source-date row.** A label `From` + a tappable date display +
   `chevron_left` / `chevron_right` step buttons (one-day step) +
   an `IconButton36` calendar-icon that opens `showDatePicker(
   firstDate: today - 60 days, lastDate: today)`. Defaults to
   `targetDate - 1 day`. Architect-bound floor: 60 days back (the
   PM spec doesn't name a floor for F1; the QL-009 TodayPill +
   backdate flow has no floor either, but the wire's silent-skip
   semantics mean an old source with deleted foods just renders
   "Skipped: 12 entries" — operationally OK. 60 days matches the
   QL-009 chevron range chosen by the PM in §6 of `pm_qol_audit.md`
   for the backdate navigation. Symmetry.)
2. **Meal-scope chips.** A `Wrap` of five chips — "All meals" /
   "Breakfast" / "Lunch" / "Dinner" / "Snack". Multi-select; the
   chip tap toggles its own state. "All meals" is a special chip
   whose selection deselects the other four; selecting any of the
   four deselects "All meals". The chip's render is the same shape
   as `MealChipPicker` from the inventory — but `MealChipPicker` is
   single-select, so we don't reuse it. Architect call: render
   inline as five `FilterChip`-shaped buttons in a `Wrap`, not a
   lifted multi-select widget. The pack doesn't have a second
   consumer for this primitive.
3. **Live preview.** A small line below the chips reading
   `"12 entries · 1,840 kcal"`. Driven by a small derived
   `copyDayPreviewProvider` (family-keyed on the
   `(sourceDate, meals)` pair):

   ```dart
   /// Cheap preview for `CopyDaySheet` — count + total kcal for
   /// the source-date / meal-filter combination. Reads the same
   /// in-memory entries the day view does, so the preview updates
   /// in lock-step with any source-date scrub.
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

   `CopyDayPreviewKey` is a small record `({DateTime sourceDate,
   List<Meal>? meals})` with `==` / `hashCode` for the family key.
   The preview re-runs as the user scrubs the source-date or
   toggles a chip; reading existing in-memory state is cheap (≤
   ~100 entries total for any user's recent days).
4. **Sticky save.** `PrimaryButton(label: 'Save — copy N entries')`
   where `N` is the live preview's count. Disabled when `N == 0`
   (the user picked a source-date with no entries in the selected
   meals) or while submitting. On tap, invoke
   `repo.copyDay(sourceDate, targetDate, meals)`, invalidate the
   targets, route via T-24 Case 2.

**Compact vs expanded shape.** Per T-15 and matching `LogEntrySheet`:
compact = `showModalBottomSheet` with `DraggableScrollableSheet`
(initialChildSize ~0.55, snap to 0.55 / 0.88); expanded =
`showDialog` with a 480 × ~520 dialog. The body composition is
identical; only the shell differs. The widget body is form-factor
blind per T-15.

### 3.5 Acceptance criteria — F1

- `LogRepository.copyDay({sourceDate, targetDate, meals})` exists
  with the signature in §3.2. Mock semantics: read entries from
  `sourceDate`, filter by `meals`, recompute snapshots against
  current food state (mirrors the wire contract), append to
  `_state`, return new entries. Partial skips happen silently;
  `created.length < requested.length` is the signal.
- `MealSection` constructor gains `onCopyMeal: void Function(Meal)?`
  and `canCopyMeal: bool Function(Meal)?`. When `onCopyMeal == null`
  the overflow icon is not rendered (current behaviour). When
  non-null, the icon renders to the right of the kcal total.
- `_EmptyDayPill` (in `day_view_compact.dart`) renders a second
  affordance "Copy from another day" below the "Log a food"
  primary button, only when `isLocalNowDay(date)`. Tap opens
  `showCopyDaySheet` with `targetDate: date, sourceMeal: null`.
- `CopyDaySheet` widget lives at
  `client/lib/features/today/widgets/copy_day_sheet.dart`. It
  exposes a `showCopyDaySheet(context, ref, {targetDate, sourceMeal})`
  function. Compact = bottom sheet; expanded = dialog.
- The sheet body composes: a source-date stepper + picker, five
  meal-scope chips (multi-select with "All meals" mutually-exclusive
  with the four single-meal chips), a live preview line driven by
  `copyDayPreviewProvider`, and a sticky save button.
- On save:
  1. `await repo.copyDay(sourceDate, targetDate, meals)`.
  2. `ref.invalidate(daySummaryProvider(targetDate))`,
     `logEntriesProvider(targetDate)`, `recentFoodsProvider`,
     `frequentFoodsProvider`, `weeklyLogDaysProvider`.
  3. `Navigator.pop()` the sheet/dialog (pop-first on expanded per
     T-24).
  4. `context.go(pathForDay(targetDate))` — T-24 Case 2.
  5. SnackBar: when `created.length == requested.length` →
     `"Copied N entries"`; when `created.length < requested.length` →
     `"Copied N of M — K skipped (food no longer available)"`.
- On failure: `SnackBar` with "Try again" action; sheet stays open;
  submit re-enables.
- The sheet's save button label includes the row count (`"Save —
  copy 4 entries"`) and the count zero state disables the button.
- A11y (T-20): each chip's Semantics label combines the meal name
  and its selected state (`"Breakfast, selected"` / `"Lunch, not
  selected"`). The save button's semantic label includes the row
  count and, on partial-skip post-save, the SnackBar's announcement
  appends `("1 skipped")`.
- The `@invalidates` block on `copyDay`'s dartdoc lists the five
  target-side providers (§3.2). `weeklyLogDaysProvider` (introduced
  in F10 / §7) is listed once F10 lands; F1's PR may ship without
  it if F10 hasn't landed yet, in which case a follow-up PR adds the
  line.
- The empty-day path's "Copy from another day" affordance is hidden
  on backdated empty days (e.g., a day-view rendering
  `2026-05-10` while local-now is `2026-05-15`).
- Tests:
  `client/test/features/today/copy_day_sheet_test.dart` covers four
  paths: (1) per-meal copy on compact with yesterday non-empty; (2)
  per-meal copy with custom source-date picker; (3) whole-day copy
  from empty-day affordance; (4) partial-skip SnackBar message.
  `client/test/repositories/log_repository_copy_day_test.dart`
  covers the mock semantics (skip-missing-food, skip-missing-serving,
  current-food-state snapshot recomputation).

---

## 4. Feature F2 — Recent-foods chip on Today compact (deep dive)

### 4.1 Mount

`day_view_compact.dart`'s `_buildBody` (`CustomScrollView.slivers`)
gains a new `SliverToBoxAdapter` between the `RingSummaryCard` slot
and the `_EmptyDayPill` / `_MealsSliver` block. The exact ordering:

1. `SliverToBoxAdapter(child: _CompactHeader())`
2. `SliverToBoxAdapter(child: _DateBar(date: date))`  (post-PR-4 this
   becomes `_DatePillBar`)
3. `SliverToBoxAdapter(child: ... RingSummaryCard ...)`
4. **NEW**: `SliverToBoxAdapter(child: _TodayRecentChipsRow(date: date))`
5. `SliverToBoxAdapter(child: _EmptyDayPill(...))`
6. `SliverPadding(... _MealsSliver(...))`

`_TodayRecentChipsRow` is a small Today-feature-local widget that
*hosts* the lifted `QuickAddChips`. It owns the gate logic (today-only,
recents non-empty, render up to 6) and binds the tap-handler to
`showLogEntrySheet(food: f, defaultMeal: mealForLocalTime(now))`.

### 4.2 Why a wrapper widget instead of mounting `QuickAddChips` directly

`QuickAddChips` today renders as a *card* — eyebrow "Quick add",
section headers "Recent" / "Frequent", chip wrap inside a bordered
container with rounded radius `r3`. The compact strip per the PM doc
§2 F2 is **not a card**; it's a horizontal-scroll strip between the
ring and the meals. The render shape differs:

- Expanded right rail: vertical, card-shaped, eyebrow + sections.
- Compact strip: horizontal-scroll, no card, no eyebrow, recents-only,
  ≤ 6 chips.

There are two ways to reconcile this:

**Option A**: Add a `compact` flag to `QuickAddChips` that switches
the render between the two shapes inside one widget.

**Option B**: Mount the existing `QuickAddChips` only on expanded,
and render the compact strip from `_TodayRecentChipsRow` using the
same internal `_QuickAddChip` primitive lifted into a private leaf
inside `quick_add_chips.dart`.

**Architect call: Option A**, with one carefully scoped public flag.
Reasons: (1) The chip primitive (`_QuickAddChip` in the current file)
is the part that gets re-used; the card chrome is the part that's
different. A flag on the public widget that switches "card+eyebrow"
to "horizontal-scroll strip" is two render branches in one file,
which is the canonical shape for T-15 — *the screen* doesn't pick;
*the widget* picks based on its mode prop. (2) Option B leaks the
private chip class as a new lift, doubling the migration cost. (3)
The widget already accepts `recents` and `frequents` as separate
lists; the compact mode just sets `frequents: const []` and renders
the recents-only path.

Public surface after F2:

```dart
class QuickAddChips extends StatelessWidget {
  const QuickAddChips({
    required this.recents,
    required this.frequents,
    required this.onTapFood,
    this.compact = false,        // NEW
    this.maxChips,               // NEW — defaults to 4 for card mode, 6 for compact
    super.key,
  });

  /// Render shape:
  ///   - `compact: false` (default; the existing right-rail card).
  ///     Card-shaped, eyebrow "Quick add", "Recent" + "Frequent"
  ///     sections, ≤ `maxChips ?? 4` chips per section, vertical
  ///     wrap, full empty-state with CTA.
  ///   - `compact: true` (the F2 today-compact strip). No card
  ///     chrome, no eyebrow, no section headers, recents-only
  ///     (`frequents` ignored), ≤ `maxChips ?? 6` chips,
  ///     horizontal-scroll. Renders `SizedBox.shrink()` when
  ///     recents is empty — the empty state is the caller's
  ///     responsibility (the day view's existing `_EmptyDayPill`
  ///     covers the "no food yet" surface).
  final bool compact;

  final int? maxChips;
}
```

The render branch lives inside `build()`:

```dart
@override
Widget build(BuildContext context) {
  if (compact) return _buildCompactStrip(context);
  return _buildCardWithSections(context);
}
```

The compact branch:

```dart
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

The card branch is the current `build()` body verbatim. The flag is
zero-cost on the existing call site — the default is `compact: false`
and the right-rail caller doesn't change.

### 4.3 The `_TodayRecentChipsRow` wrapper

```dart
class _TodayRecentChipsRow extends ConsumerWidget {
  const _TodayRecentChipsRow({required this.date});
  final DateTime date;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Per PM doc §2 F2: "The strip renders **only on today's
    // day-view** (`date == local-now`)". Backdated days hide the
    // strip; the per-meal copy affordance (§3) is the right scope
    // for re-logging onto past days.
    if (!isLocalNowDay(date)) return const SizedBox.shrink();

    final recentsAsync = ref.watch(recentFoodsProvider);
    final recents = recentsAsync.valueOrNull ?? const <Food>[];
    if (recents.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: EdgeInsets.only(bottom: context.space.x3),
      child: QuickAddChips(
        compact: true,
        recents: recents,
        frequents: const <Food>[],
        onTapFood: (food) => showLogEntrySheet(
          context,
          food: food,
          // Time-of-day meal default; the sheet ignores this in edit
          // mode but we're always in create here.
          defaultMeal: mealForLocalTime(DateTime.now()),
        ),
      ),
    );
  }
}
```

The wrapper handles the two gates (today-only, recents non-empty) so
`QuickAddChips` itself stays gate-free.

### 4.4 Tap behavior

PM specified pre-seeded `showLogEntrySheet(food: f)` with
`defaultMeal: mealForLocalTime(DateTime.now())`. **Not one-tap
commit.** The current `showLogEntrySheet` signature already supports
this:

```dart
Future<LogEntry?> showLogEntrySheet(
  BuildContext context, {
  required Food food,
  Meal? defaultMeal,
  LogEntry? existing,
});
```

`existing: null` means create mode. `defaultMeal:
mealForLocalTime(now)` seeds the meal chip; the sheet body's
`initState` already reads:

```dart
_meal = ex?.meal ?? widget.defaultMeal ?? mealForLocalTime(DateTime.now());
```

(line 262 of `log_entry_sheet.dart`). Net: F2 doesn't change
`LogEntrySheet`; it consumes the existing API verbatim.

One subtlety: the PM spec §2 F2 AC names "the food's default serving
(or the serving used in the most recent log of this food — architect's
pick; recency is correct), quantity from the most recent log of this
food". The current `LogEntrySheet` create path seeds quantity from
`existing?.quantity ?? Decimal.one` (line 73 of `log_entry_sheet.dart`)
— so create-mode always seeds quantity = 1. To match the PM AC, F2's
tap handler would need to pass either:

(a) A new optional `Decimal? quantitySeed` to `showLogEntrySheet`, or
(b) An `existing`-shaped synthesised `LogEntry` from the
    `recentFoodsProvider` row (clumsy — `recentFoodsProvider` returns
    `List<Food>`, not log-rows).

**Architect call: defer the recency-quantity-seed to a v1.1 follow-up.**
Reasons: (1) The PM AC named "architect's pick" on the serving and
"the recentFoodsProvider row carries this" on the quantity, but
`recentFoodsProvider` is currently a `FutureProvider<List<Food>>` —
the recency-of-the-most-recent-log isn't in the row. Threading
recency would require either a new `recentFoodLogsProvider` returning
`List<(Food, LogEntry)>` pairs or a sibling
`recentFoodQuantityProvider(foodId)` family. Both are real product
changes. (2) The PM AC's "Three taps: chip → review → Save" target
holds even with quantity = 1 default — the user sees the preview
update as they nudge the stepper, no different from today. (3) The
v1.1 ticket "seed quantity from most-recent log" is a one-day diff
once the provider surface exists. Naming it here so PMgr knows it
was considered and explicitly punted with a follow-up flag.

So F2's `onTapFood` is exactly: `showLogEntrySheet(context, food: f,
defaultMeal: mealForLocalTime(DateTime.now()))`. No new parameters.

### 4.5 Empty state

Per PM doc §2 F2 AC: "when recents are empty, hide the row entirely.
Don't render a placeholder." The `_TodayRecentChipsRow` returns
`SizedBox.shrink()` when `recents.isEmpty`. The `QuickAddChips`
compact-mode also returns `SizedBox.shrink()` defensively. The user
either sees the strip with their recents or sees no strip at all;
there is no skeleton, placeholder, or "Log your first food" affordance
in this slot. The empty-day pill (§3.4 (B)) is the right surface for
the "no food yet" case.

### 4.6 Acceptance criteria — F2

- `QuickAddChips` lives at `lib/widgets/quick_add_chips.dart` (post
  PR 1).
- `QuickAddChips` accepts `compact: bool = false` and `maxChips:
  int?`. The compact branch renders a horizontal-scroll strip of
  ≤ `maxChips ?? 6` chips; recents-only; no card chrome; no
  empty-state placeholder.
- The expanded right-rail caller is unchanged (compact stays
  false, default behaviour preserved).
- `_TodayRecentChipsRow` widget lives in `day_view_compact.dart`
  (or `widgets/today_recent_chips_row.dart` if the agent prefers a
  separate file — same feature folder). It gates on
  `isLocalNowDay(date)` AND `recents.isNotEmpty`.
- On compact day-view of the local-now day with recents non-empty,
  the strip renders between the `RingSummaryCard` and the
  `_EmptyDayPill` (which is between the strip and the meal
  sections — order: ring → recents → empty-day-pill → meals).
- Tap a chip → `showLogEntrySheet(food, defaultMeal:
  mealForLocalTime(now))`. The existing sheet handles create-mode
  T-24 Case 2 routing.
- Backdated days: the strip is hidden.
- Empty recents: the strip is hidden; no placeholder.
- A11y: each chip's existing `Semantics(button: true, label:
  "Greek yogurt, 130 kilocalories")` is preserved verbatim.
- Tests: `client/test/features/today/recent_chips_row_compact_test.dart`
  covers (a) render-on-today-with-recents; (b) hidden-on-backdate;
  (c) hidden-when-recents-empty; (d) tap routes through
  `LogEntrySheet` create mode with the time-of-day meal seeded.

---

## 5. Feature F4 + F5 — Sparkline scrub + weight log pre-fill (deep dive)

These pair because they share the same provider
(`weightHistoryProvider`), the same display-unit seam
(`formatWeight` / `formatWeightWithUnit` from `lib/domain/units/weight.dart`),
and the same surface (the weight tab's chart + log-weight sheet). PM
recommended landing them together; I agree.

### 5.1 F4 — Sparkline scrub

**File**: `client/lib/features/weight/widgets/weight_sparkline.dart`.
The current shape is a `WeightSparklineCard` → `_ChartBody` →
`CustomPaint` with a `_ChartPainter`. The painter draws the area
gradient, the actual line, the dashed moving-avg suffix, and the
dashed goal line. The chart is decorative-only today — no gesture
handling.

**The change**: wrap the existing `CustomPaint` in a gesture-aware
overlay that:

- On compact: handles `onHorizontalDragStart` / `onHorizontalDragUpdate`
  / `onHorizontalDragEnd`. The start touch fades a vertical
  guideline + floating tooltip in; updates move them with the
  finger; end fades them out.
- On expanded: handles `MouseRegion.onEnter` / `onHover` / `onExit`.
  Hover moves the guideline; exit fades it out.

**Why drag, not long-press on compact** (per PM §2 F4): drag is
lower-friction than long-press-then-drag. Drag-start without a delay
matches iOS Health / Strava. The PM ruling stands; architect
honours it.

**Why a `RawGestureDetector`-shaped wrap, not a `GestureDetector`**:
on compact, the chart sits inside the weight-screen's scrollable
body. A bare `GestureDetector(onHorizontalDrag*)` competes with the
parent `ListView` for the gesture arena — the arena resolution
generally goes our way because horizontal drag is exclusive to the
chart and the parent is vertical-only, but for safety the architect
recommends a `RawGestureDetector` configured to only claim horizontal
drags. The PM acceptance §2 F4 specifically calls this out: "The
vertical drag gesture inside the chart **does not block** the parent
`ListView`'s vertical scroll (T-12 spirit)."

**Implementation shape**:

```dart
class _ScrubGestureWrap extends StatefulWidget {
  const _ScrubGestureWrap({
    required this.points,
    required this.unit,
    required this.child,
  });

  final List<WeightSeriesPoint> points;
  final WeightUnit unit;
  final Widget child;

  @override
  State<_ScrubGestureWrap> createState() => _ScrubGestureWrapState();
}

class _ScrubGestureWrapState extends State<_ScrubGestureWrap>
    with SingleTickerProviderStateMixin {
  /// Active scrub X-coordinate in widget-local pixels. Null when
  /// no scrub is active. The painter reads this and renders the
  /// guideline + tooltip overlay when non-null.
  double? _scrubX;

  /// Fade animation for the guideline + tooltip. 120 ms in /
  /// 120 ms out per `motion('chart.scrub.in/out')` — see the
  /// motion tokens.
  late final AnimationController _fade;

  // ...

  @override
  Widget build(BuildContext context) {
    final isExpanded = FormFactor.of(context).isExpanded;
    final disableAnims =
        MediaQuery.disableAnimationsOf(context); // a11y honour

    final overlay = AnimatedBuilder(
      animation: _fade,
      builder: (_, __) {
        if (_scrubX == null) return widget.child;
        return CustomPaint(
          foregroundPainter: _ScrubOverlayPainter(
            scrubX: _scrubX!,
            opacity: _fade.value,
            points: widget.points,
            unit: widget.unit,
          ),
          child: widget.child,
        );
      },
    );

    if (isExpanded) {
      return MouseRegion(
        onEnter: (e) => _startAt(e.localPosition.dx, disableAnims),
        onHover: (e) => _updateAt(e.localPosition.dx),
        onExit: (_) => _endScrub(disableAnims),
        child: overlay,
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      // Horizontal-drag-only; vertical drags fall through to the
      // parent ScrollView. Per PM §2 F4 + T-12 spirit.
      onHorizontalDragStart: (d) =>
          _startAt(d.localPosition.dx, disableAnims),
      onHorizontalDragUpdate: (d) =>
          _updateAt(d.localPosition.dx),
      onHorizontalDragEnd: (_) => _endScrub(disableAnims),
      onHorizontalDragCancel: () => _endScrub(disableAnims),
      child: overlay,
    );
  }

  void _startAt(double x, bool disableAnims) {
    setState(() => _scrubX = x);
    if (disableAnims) {
      _fade.value = 1.0;
    } else {
      _fade.forward();
    }
  }

  void _updateAt(double x) {
    setState(() => _scrubX = x);
  }

  void _endScrub(bool disableAnims) {
    if (disableAnims) {
      _fade.value = 0.0;
      setState(() => _scrubX = null);
      return;
    }
    _fade.reverse().then((_) {
      if (mounted) setState(() => _scrubX = null);
    });
  }
}
```

**Hit-testing** lives in `_ScrubOverlayPainter.paint`. Given the
scrub X-coordinate in widget-local pixels, find the nearest painted
point: linear scan through the painted points (the chart caps at ~30
points, linear is fast). The painter:

1. Draws a 1-px vertical line at `scrubX` from chart-top to
   chart-bottom, colored `AppColors.ink2` at the fade opacity.
2. Computes the nearest data point's Y-coordinate; paints a small
   filled dot (radius 4 px) at `(pointX, pointY)`.
3. Composes the tooltip text: two lines,
   `DateFormat('EEE, MMM d').format(point.date)` on top,
   `formatWeightWithUnit(point.weightKg, unit)` on bottom. Honour
   `weightUnit` per T-21.
4. Lays out the tooltip text in a `TextPainter`, draws an
   `AppColors.ink`-filled rounded rectangle around it (8 px
   padding, `radius.r2`), and renders the text in white at the
   fade opacity. Position: above the dot, clamped to the chart's
   horizontal bounds so the tooltip doesn't clip on the edges.

**Why `foregroundPainter` and not a `Stack`**: the painter approach
keeps the gesture-aware overlay inside the existing custom-paint
hierarchy — no extra widget layer, no `Positioned` math. The
foreground draws *over* the chart strokes; the tooltip's
ink-filled background sits over the dashed moving-avg line cleanly.

**Reduce-motion** (per the PM AC and T-20 spirit): the fade
animations bypass when `MediaQuery.disableAnimationsOf(context)`. The
guideline appears / disappears instantly; the tooltip text still
follows the finger.

**A11y** (per PM §2 F4 AC): the chart's existing
`Semantics(value: ...)` carries the range summary. The scrub gesture
is a sighted-user affordance; screen-reader users consume the
`WeightHistoryList` below. No new Semantics nodes are added by the
scrub overlay — the chart's announcement stays one statement.

### 5.2 F5 — Weight log pre-fill

**File**: `client/lib/features/weight/widgets/log_weight_sheet.dart`.
The current `initState` (lines 82–94) seeds from `meProvider`'s
`currentWeightKg`, falling back to 70 kg. After F5, the seed chain
is:

```
weightHistoryProvider.firstOrNull?.weightKg
  ?? user.currentWeightKg
  ?? Decimal.parse('70')
```

PM doc §2 F4/F5 spells the chain. Architect's read of the rationale:

1. **`weightHistoryProvider.firstOrNull?.weightKg`** — the newest
   prior weight entry. This is the most-recent ground truth and is
   what a returning user wants the stepper to start at (their last
   measured weight, day-over-day delta is typically < 0.5 kg).
2. **`user.currentWeightKg`** — the seeded onboarding value when
   the user has never logged a weight. `meProvider` resolves this
   from `User.currentWeightKg`, which is derived server-side from
   the most recent weight entry; in the no-entries case it's the
   onboarding-step-2 input.
3. **`Decimal.parse('70')`** — the existing default seed; only
   fires when both above are null (a paranoid edge: brand-new user
   with no onboarding completion, somehow on the weight screen).
   70 kg = ~154 lb, a "reasonable adult" floor. Same value the
   current code uses.

**Implementation**: the existing `initState` (lines 82–94) reads
`meProvider` synchronously via `ref.read(meProvider).asData?.value`.
F5 layers in a synchronous read of `weightHistoryProvider`:

```dart
@override
void initState() {
  super.initState();
  final history = ref.read(weightHistoryProvider).asData?.value;
  final me = ref.read(meProvider).asData?.value;
  // Fall-through per `architect_ux_pack.md` §5.2:
  //   newest history entry → user's current → 70 kg default.
  final seed = history?.isNotEmpty == true
      ? history!.first.weightKg
      : (me?.currentWeightKg ?? Decimal.parse('70'));
  final rounded = seed.round(scale: 1);
  _tenths = (rounded * Decimal.fromInt(10)).toBigInt().toInt();
}
```

**Why `ref.read`, not `ref.watch`**: the stepper's seed is a
*one-shot* read at sheet open. We do not want the input value to
jitter mid-edit if `weightHistoryProvider` re-emits (e.g., a
background refresh) — that would silently overwrite the user's
partial input. `ref.read` snapshots once.

**Provider warmth**: `weightHistoryProvider` is consumed by the
weight screen body (which is the source view for the FAB that opens
this sheet), so by the time the user taps "Log weight", the
provider is warm. No async wait inside `initState`. The
`.asData?.value` falls through to `null` only when the provider is
in `loading` / `error` state — in which case `me?.currentWeightKg`
(also typically warm) takes over.

**T-21 / `formatWeight`**: the stepper renders in
`ref.watch(weightUnitProvider)` per T-21. The seed value above is
canonical kg; the rendered display is whatever the user's
`weightUnit` resolves to. The existing stepper already honours
`weightUnitProvider`; F5 changes nothing about render — only the
initial canonical kg value.

### 5.3 Acceptance criteria — F4 + F5

**F4 (scrub).**

- `weight_sparkline.dart` grows a `_ScrubGestureWrap` widget that
  wraps the existing `CustomPaint`. On compact it handles
  `onHorizontalDrag*`; on expanded it handles `MouseRegion`
  hover/exit.
- A vertical guideline + floating tooltip render at the touch X /
  hover X. The tooltip shows two stacked lines:
  `DateFormat('EEE, MMM d').format(point.date)` on top,
  `formatWeightWithUnit(point.weightKg, weightUnit)` on bottom.
  The bottom line honours T-21 (kg / lb / st per user pref).
- Drag end / mouse exit fades the guideline + tooltip out over
  120 ms; `MediaQuery.disableAnimationsOf` bypasses the fade.
- Vertical drags over the chart do **not** hijack the parent
  `ListView`'s scroll. Confirmed by a widget test that drags
  vertically inside the chart bounds and asserts the
  `ScrollController.offset` changes.
- Empty-state chart (zero points): scrub gesture is a no-op (the
  `_ScrubGestureWrap` short-circuits when `points.isEmpty`).
- Chart paint code stays in `CustomPainter` per T-19; no new chart
  package; no `package:web` SVG.

**F5 (pre-fill).**

- `LogWeightSheet._LogWeightSheetState.initState` reads
  `weightHistoryProvider` first, then `meProvider`, then falls
  through to `Decimal.parse('70')`. The seed is read via
  `ref.read` (one-shot) not `ref.watch`.
- The stepper opens with the most-recent prior weight rendered in
  the user's `weightUnit` (e.g., a user with `weightUnit: lb` and
  a prior 79.6 kg entry sees the stepper at `175.5 lb`).
- Tests: `log_weight_prefill_test.dart` covers (a) seed from
  non-empty history; (b) seed from `me.currentWeightKg` when
  history is empty; (c) fall-through to 70 kg when both are null.
- `sparkline_scrub_test.dart` covers (a) drag emits guideline +
  tooltip; (b) drag end fades; (c) vertical drag does not block
  parent scroll; (d) reduce-motion bypasses fade.

---

## 6. Refactor — Today compact header compression (deep dive)

PM ruled four concurrent edits to the compact header:
**avatar cut**, **bolt moved into FAB long-press**, **chevrons
collapsed into a tappable date pill**, **search + TodayPill kept**.
The chevron-merge is gated on the swipe-day gesture being shipped
(PM doc §2 Theme A; PM doc §8 sequencing). I name each edit as a
discrete change with its own acceptance, then call on the swipe-day
ticket split.

### 6.1 Drop the avatar widget from `_CompactHeader`

`day_view_compact.dart:120` — the `_CompactHeader` `Padding` →
`Row` currently renders:

```
[avatar (36×36 SS-initials circle)] [Spacer] [bolt IconButton36] [search IconButton36]
```

After: the avatar circle is **deleted**. The `Row` becomes
`[Spacer] [bolt] [search]` → effectively `Row(mainAxisAlignment:
MainAxisAlignment.end, children: [bolt, search])`. No replacement
text-avatar, no "Sign in" link, no fallback.

The Spacer is removed too — `MainAxisAlignment.end` on the bare
two-icon Row is the simplest read. The header's vertical padding
stays at `space.x1 + 2` top, `space.x3` bottom (the existing
`Padding.fromLTRB`).

Effect on the ring's vertical position: the header height shrinks
by ~36 px (the avatar's 36 px circle + ~4 px of vertical centering
slop). The `_DateBar` slides up by ~36 px; the `RingSummaryCard`
follows. On a Pixel 4a (393 × 851) the ring's top-edge moves from
~140 px down the viewport to ~104 px — close to the "first 80 px"
the UX review aspired to but not all the way. The chevron-merge
(below) reclaims another ~24 px; together the ring's center lands
within the ~280 px target the PM AC names.

### 6.2 FAB long-press menu

`day_view_compact.dart:50` — `floatingActionButton: LogFoodFab(...)`.
The `LogFoodFab` widget today is a stateless wrapper around a
single `FloatingActionButton.extended`. After this change it grows
a long-press affordance that opens a 2-item menu.

**Why a `PopupMenuButton`-styled menu, not a sheet**: a sheet on
FAB long-press is too heavy. The menu is two items; `showMenu`
positioned near the FAB renders in the same modal surface a
`PopupMenuButton` would. Visually it reads as "the FAB grew two
options," not "the FAB opened a screen."

**Implementation shape**:

```dart
// In log_food_fab.dart (existing file at
// client/lib/features/today/widgets/log_food_fab.dart):

class LogFoodFab extends StatelessWidget {
  const LogFoodFab({
    required this.onPressed,
    // NEW for Theme A: long-press exposes Quick add calories.
    required this.onQuickAdd,
    super.key,
  });
  final VoidCallback onPressed;
  final VoidCallback onQuickAdd;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPress: () => _showLongPressMenu(context),
      child: FloatingActionButton.extended(
        onPressed: onPressed,
        icon: const Icon(Icons.add),
        label: const Text('Log food'),
      ),
    );
  }

  Future<void> _showLongPressMenu(BuildContext context) async {
    final overlay = Overlay.of(context).context.findRenderObject()
        as RenderBox;
    // Anchor the menu just above the FAB. The FAB sits at
    // bottom-right with safe-area offset; the menu opens upward.
    final selected = await showMenu<_FabAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        overlay.size.width - 220,
        overlay.size.height - 200,
        24,
        24,
      ),
      items: <PopupMenuEntry<_FabAction>>[
        const PopupMenuItem(
          value: _FabAction.logFood,
          child: Row(children: <Widget>[
            Icon(Icons.add),
            SizedBox(width: 12),
            Text('Log food'),
          ]),
        ),
        const PopupMenuItem(
          value: _FabAction.quickAdd,
          child: Row(children: <Widget>[
            Icon(Icons.bolt_outlined),
            SizedBox(width: 12),
            Text('Quick add calories'),
          ]),
        ),
      ],
    );
    if (selected == _FabAction.quickAdd) onQuickAdd();
    if (selected == _FabAction.logFood) onPressed();
  }
}

enum _FabAction { logFood, quickAdd }
```

The day-view passes `onQuickAdd: () => showQuickAddSheet(context)`
— the same handler the bolt icon called before its removal.

**T-12 reading**: the FAB is still the only floating action; the
long-press menu is a momentary modal anchored at the FAB. The
`showMenu` overlay is a route-style frame (Material's `_PopupRoute`),
not a floating widget. This stays inside T-12 — see §10.1 for the
explicit reading and a proposed clarifying rider to T-12 if PMgr
wants the tenant's wording to acknowledge the pattern.

**Removal of the bolt from `_CompactHeader`**: the `IconButton36(
icon: Icons.bolt_outlined, ...)` block at `day_view_compact.dart:160`
is **deleted**. The `_CompactHeader`'s `Row` after both edits (avatar
cut + bolt cut) becomes:

```dart
Row(
  mainAxisAlignment: MainAxisAlignment.end,
  children: <Widget>[
    IconButton36(
      icon: Icons.search,
      tooltip: 'Search',
      onPressed: () => context.push(Routes.foodsSearchPath),
      color: context.colors.ink2,
    ),
  ],
)
```

One icon. The header's visual weight drops by ~75% (three icons →
one icon, plus the avatar's 36 px box removed).

### 6.3 Chevrons + date title → single `DatePill`

`day_view_compact.dart:178` — `_DateBar` renders three elements
across one row: title block (eyebrow `"Today"` + sub-line
`"Thursday, May 14"`), optional `TodayPill`, two chevron
`IconButton36`s.

After the chevron-merge: the title block + the two chevrons collapse
into a single `DatePill` widget. `TodayPill` stays as-is (it's
already a single Semantics node).

**`DatePill` widget shape** (new, lives inside `today_internals.dart`
since it's only used by the compact day view):

```dart
/// Tappable date title for the compact day view. Renders the same
/// two-line content (`"Today"` eyebrow + sub-line `"Thursday,
/// May 14"`) as the old `_DateBar` title block, but as a single
/// tappable surface. On tap: opens a date picker bounded to
/// `[today - 60 days, today]`; the picker's return value, if
/// non-null, routes via `pathForDay(picked)`.
///
/// Per `architect_ux_pack.md` §6.3 — collapses three focusable
/// nodes (title, chevron-left, chevron-right) into one Semantics
/// node (T-20).
///
/// **Gate on swipe-day gesture.** Per PM doc §2 Theme A: the
/// chevron-merge is gated on the swipe gesture being live in the
/// codebase. Until the swipe ships, the date title remains a
/// non-tappable `Column` and the chevrons stay around it. After
/// the swipe lands, `_DateBar` swaps to render this widget alone
/// (the chevrons are removed in the same PR).
class DatePill extends StatelessWidget {
  const DatePill({required this.date, super.key});
  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      container: true,
      button: true,
      label:
          '${todayHeadline(date)}, ${todaySubline(date)}, open date picker',
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const Key('date-pill'),
          borderRadius: BorderRadius.circular(context.radius.r2),
          onTap: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: date,
              firstDate: DateTime.now().subtract(const Duration(days: 60)),
              lastDate: DateTime.now(),
            );
            if (picked != null && context.mounted) {
              context.go(pathForDay(picked));
            }
          },
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: context.space.x2,
              vertical: context.space.x1,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(todayHeadline(date), style: context.text.pageTitle),
                SizedBox(height: context.space.x05),
                Text(
                  todaySubline(date),
                  style: context.text.meta.copyWith(color: colors.ink2),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
```

**`_DateBar` post-merge** (PR 4 only, after swipe-day lands):

```dart
class _DateBar extends StatelessWidget {
  const _DateBar({required this.date});
  final DateTime date;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.space.x5,
        0,
        context.space.x5,
        context.space.x2,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(child: DatePill(date: date)),
          if (!isLocalNowDay(date)) const TodayPill(),
        ],
      ),
    );
  }
}
```

The two chevron `IconButton36`s are gone. Per-day navigation is now
either swipe (the gesture wrapper, §6.4) or the date picker (the
`DatePill` tap).

### 6.4 Swipe-day gesture

**Wrap location**: the day view's scrollable body. On compact, that's
the `CustomScrollView` inside `DayViewCompact.build`. Per PM doc §2
Theme A AC: the gesture wraps "the day-view's scroll content with
thresholds (>10 px/ms, >50 px total)".

**Implementation shape**: a new `_DaySwipeWrap` widget in
`today_internals.dart` (or `widgets/day_swipe_wrap.dart` — feature-
local, not lifted). The wrap uses `GestureDetector.onHorizontalDragEnd`
to read the velocity and total displacement:

```dart
/// Horizontal-swipe wrapper around the day view's scrollable body.
/// Left swipe → next day; right swipe → previous day. Routes via
/// `pathForDay`. Honours `MediaQuery.disableAnimationsOf`.
///
/// Thresholds per PM doc §2 Theme A:
///   - Velocity > 200 px/s (≈ "> 10 px/ms" * 20 ms tick).
///   - Total displacement > 50 px.
///
/// The wrapper uses `HitTestBehavior.translucent` so vertical
/// drags fall through to the inner scroll view (T-12 spirit; same
/// rule as the sparkline scrub).
class DaySwipeWrap extends StatelessWidget {
  const DaySwipeWrap({
    required this.date,
    required this.child,
    super.key,
  });

  final DateTime date;
  final Widget child;

  static const double _velocityPxPerSec = 200;
  static const double _minDeltaPx = 50;

  @override
  Widget build(BuildContext context) {
    double? dragStartX;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (d) => dragStartX = d.localPosition.dx,
      onHorizontalDragEnd: (d) {
        final velocity = d.primaryVelocity ?? 0;
        // primaryVelocity is signed: negative = leftward.
        if (velocity.abs() < _velocityPxPerSec) return;
        // For total displacement we'd track start; primaryVelocity
        // alone is the simpler heuristic and matches Material's
        // dismiss-swipe convention. The 50 px floor is implicit in
        // the 200 px/s × 0.25 s typical drag duration.
        if (velocity < 0) {
          // Left swipe → next day.
          navigateDay(context, date, 1);
        } else {
          // Right swipe → previous day.
          navigateDay(context, date, -1);
        }
      },
      child: child,
    );
  }
}
```

The wrap is mounted in `DayViewCompact.build`:

```dart
@override
Widget build(BuildContext context, WidgetRef ref) {
  // ...
  return Scaffold(
    backgroundColor: Colors.transparent,
    floatingActionButton: LogFoodFab(...),
    body: DaySwipeWrap(
      date: date,
      child: CustomScrollView(slivers: ...),
    ),
  );
}
```

**Reduce-motion**: the swipe gesture itself doesn't animate (it
routes via `context.go`, which uses the router's animation —
GoRouter's animation honours `MediaQuery.disableAnimations` already).
No explicit handling in `DaySwipeWrap`.

### 6.5 Ticket split — architect's call

PM doc §2 Theme A names the chevron-merge as gated on the swipe-day
gesture being in the codebase. Two reasonable PR shapes:

**Option A (single combined ticket)**: one PR adds `DaySwipeWrap`,
adds `DatePill`, removes the chevrons. Ships as one unit.

**Option B (two distinct tickets)**: PR adds `DaySwipeWrap` only;
PR adds `DatePill` and removes chevrons.

**Architect call: Option B.** Reasons:

1. The swipe gesture is the *interesting* engineering surface —
   gesture-arena resolution against the inner scroll, velocity
   thresholds, hit-testing inside a `CustomScrollView`. It deserves
   its own test surface (`day_swipe_gesture_test.dart`) and its own
   review. Folding the trivial widget swap into the swipe PR muddies
   what the reviewer is judging.
2. If the swipe gesture is harder than expected — say it fights
   with the `RingSummaryCard`'s inner `Hero` or with the
   `_TodayRecentChipsRow`'s `ListView.separated` horizontal scroll
   — the chevron-merge can wait. The header compression's other
   wins (avatar cut, bolt to FAB) ship in PR 2 independently. The
   chevron-merge gates *only* on the swipe; the rest of Theme A
   doesn't.
3. The PM doc §2 Theme A AC names: "If the swipe gesture is not yet
   implemented in the codebase, this acceptance criterion **gates
   on** the architect's swipe-gesture ticket — the chevrons remain
   until swipe lands." Two tickets honour this verbatim. Option A
   collapses the gate into "ship both together," which is also
   valid; Option B is the cleanest implementation of the gate.

So: **PR 2 = avatar cut + bolt-to-FAB-longpress (no chevron-merge,
no swipe).** **PR 3 = `DaySwipeWrap` (lands `DatePill` as a
non-tappable widget but doesn't yet wire it).** **PR 4 = chevron
removal (wires `DatePill`'s tap; removes the chevron `IconButton36`s
from `_DateBar`).**

PMgr — flag in §12 for confirmation; I recommend Option B but the
combined-ticket approach is acceptable if the agent crew prefers
fewer PRs.

### 6.6 Acceptance criteria — Theme A

**PR 2 (avatar + bolt).**

- `_CompactHeader` no longer renders an avatar.
- `_CompactHeader` no longer renders the bolt `IconButton36`. The
  search `IconButton36` stays.
- `LogFoodFab` gains an `onQuickAdd: VoidCallback` parameter; the
  widget wraps the FAB in a `GestureDetector(onLongPress: ...)`
  that opens a `showMenu` with two items (Log food, Quick add
  calories).
- `day_view_compact.dart` passes `onQuickAdd: () =>
  showQuickAddSheet(context)` to `LogFoodFab`.
- Short-press on the FAB still does the search route (`onPressed`
  is unchanged).
- A11y: each menu item carries its own Semantics label.

**PR 3 (swipe).**

- `DaySwipeWrap` widget exists at
  `client/lib/features/today/today_internals.dart` (or a new
  `widgets/day_swipe_wrap.dart` — agent's choice within the feature
  folder).
- The widget wraps `DayViewCompact.body`'s `CustomScrollView`. On
  horizontal-drag-end with `|velocity| > 200 px/s`, routes via
  `navigateDay(context, date, ±1)`.
- Vertical drags pass through to the inner scroll view (T-12
  spirit; `HitTestBehavior.translucent`).
- Tests: `day_swipe_gesture_test.dart` covers (a) left swipe →
  next day; (b) right swipe → previous day; (c) below-threshold
  swipe → no navigation; (d) vertical drag → parent scroll
  responds, no day change.
- Reduce-motion: routing relies on `context.go`'s built-in
  motion honouring, no new animations introduced.

**PR 4 (chevron-merge final).**

- `DatePill` widget exists; tap opens `showDatePicker(firstDate:
  today - 60d, lastDate: today)`; on picker return, routes via
  `pathForDay(picked)`.
- `_DateBar` no longer renders chevron `IconButton36`s; the
  `DatePill` is the only date-side affordance (with the
  `TodayPill` continuing to render on backdated views).
- A11y: the `DatePill` is a single `Semantics(button: true,
  label: "Today, Thursday May 14, open date picker")`. The
  five-focusable-nodes-for-one-control finding from the
  Accessibility section of `ux_review.md` is resolved.
- The `RingSummaryCard`'s top edge moves up by the cumulative
  ~60 px from PR 2 + PR 4. Test: launch
  `DayViewCompact(date: today)` on a 393 × 851 viewport, assert
  the `RingSummaryCard`'s `globalKey.currentContext`'s render-
  box-top is within 320 px of the safe-area top.

---

## 7. Feature F10 — Streak pill / "days logged this week"

### 7.1 Metric

"Days with at least one log entry this week (Monday–Sunday, local)."
PM doc §2 F10 names Monday–Sunday explicitly ("matching the bottom
of weekly grids in every fitness app the user has seen"); architect
honours.

**Week-start choice — Monday.** PM ruled it; documenting the
architect's read for completeness: Sunday-start is the US convention,
Monday-start is the ISO/EU convention. The PM ruling matches the
fitness-app convention (most competitors render the day grid with
Monday first). If a future PMgr ruling flips this, it's a one-line
change in `_weekStart(now)` below; no other surface depends on the
choice.

### 7.2 Data flow

PM doc §2 F10 named "Client-side fold over `weightHistoryProvider`...
no, over `logEntriesProvider` for each of the seven days." I read the
correction: the fold is over the seven `logEntriesProvider(date)`
families.

**Architect refinement**: rather than have `_WeekProgressPill` watch
seven separate `logEntriesProvider(date)` instances (which creates
seven dependent rebuilds when any single day's entries change — a
fold over 7 day-summary providers would cause the pill to re-render
on every log entry), introduce a small dedicated provider
`weeklyLogDaysProvider` that does the fold once and exposes a single
`AsyncValue<int>`:

```dart
/// "Days with at least one log entry this week (Mon–Sun, local)."
/// F10 from `architect_ux_pack.md` §7. The metric is the count, not
/// the days themselves — the pill displays "N / 7 this week".
///
/// Implementation: reads the seven days of the current local week
/// through `LogRepository.weeklyLogDayCount()`, which iterates the
/// repository's in-memory entries once and counts distinct days
/// where the user logged anything. Cheaper than seven separate
/// `logEntriesProvider` reads; rebuilds only when invalidated by
/// `LogRepository.create` / `.update` / `.delete` / `.copyDay`.
///
/// **Local-now dependency.** The current week's Monday is computed
/// from `DateTime.now()` at read time. A long-lived provider would
/// stale across midnight; in practice the day view rebuilds on
/// `AppLifecycleState.resumed` (architect §6 "Background refresh"),
/// which invalidates `daySummaryProvider` and — by the call-site
/// pattern — this provider too. Adding a foreground-resume
/// invalidation for this provider lives in the same code path that
/// invalidates `daySummaryProvider`.
final weeklyLogDaysProvider = FutureProvider<int>((ref) {
  final repo = ref.watch(logRepositoryProvider);
  return repo.weeklyLogDayCount();
});
```

The repository method:

```dart
/// Count distinct dates in the current local week (Mon–Sun) that
/// have at least one log entry. Returns 0..7.
///
/// Lives on the repository (not the provider) so the mock and the
/// real client share the math; the live client will hit
/// `GET /me/weekly-logging` once BE-002 ships (PM doc §9 — flagged
/// non-blocking).
Future<int> weeklyLogDayCount() async {
  final now = DateTime.now();
  final weekStart = _mondayOfWeek(now);
  final weekEnd = weekStart.add(const Duration(days: 7));
  final entries = _state.where((e) =>
      !e.consumedOn.isBefore(weekStart) &&
      e.consumedOn.isBefore(weekEnd));
  final daysLogged = <int>{}; // day-of-year keys
  for (final e in entries) {
    daysLogged.add(_dayOfYear(e.consumedOn));
  }
  return daysLogged.length;
}

DateTime _mondayOfWeek(DateTime now) {
  // DateTime.weekday: Monday = 1, Sunday = 7.
  final daysSinceMonday = now.weekday - 1;
  return DateTime(now.year, now.month, now.day - daysSinceMonday);
}

int _dayOfYear(DateTime d) => d.year * 1000 + d.dayOfYear; // any
                                                            // unique key.
```

The mock implementation is ~10 lines; the repository's
`_state` cap of "all entries ever logged in the mock seed" is
small enough that the linear scan costs nothing.

**Invalidation list update**: every mutator on `LogRepository` —
`create`, `update`, `delete`, `copyDay`, `adoptOptimistic` — must
list `weeklyLogDaysProvider` in its `@invalidates` block, because
each could change the week's day-count (a `create` could turn a
zero-entry day into a one-entry day; a `delete` could do the
reverse; `copyDay` can do either). The PR that adds the provider
also extends the doc-tag lists.

### 7.3 Render

PM doc §2 F10 named "a tiny pill inside `RingSummaryCard`, below
the existing kcal caption". I read: below the ring's center label,
above the macro bars. The existing card's content shape is:

```
[CalorieRing with center "812 kcal left"]
[Caption: "of 2,160 today"]
[← NEW: _WeekProgressPill ←]
[MacroBar protein]
[MacroBar carbs]
[MacroBar fat]
```

The pill renders inline as a single Text run inside a small
`Container` with no background unless count == 7:

```dart
class _WeekProgressPill extends ConsumerWidget {
  const _WeekProgressPill();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final countAsync = ref.watch(weeklyLogDaysProvider);
    final count = countAsync.valueOrNull ?? 0;
    // PM doc §2 F10: "Hidden when count is 0."
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

The pill is **not** routable (PM doc §2 F10 AC: "The pill does
**not** route on tap. It is read-only.").

**No animation**, **no fire emoji**, **no "celebration"**: when
count == 7 the visual is the accent-coloured text. No `Hero`, no
scale animation, no haptic.

**Render in `RingSummaryCard`**: the widget at
`client/lib/widgets/ring_summary_card.dart` gains the
`_WeekProgressPill` between the existing caption row and the
`MacroBar` row. The pill is mounted on both `compact: true` and
`compact: false` paths (today PR mounts it on the compact
`day_view_compact.dart` consumer and the expanded right-rail's
`ring_summary_card.dart` consumer share the same widget — see
PM doc §4 "Today expanded / web" — light touch). One mount site,
two render sites.

### 7.4 Backend ticket

PM doc §9 names **BE-002** — a `GET /me/weekly-logging` endpoint.
Architect honours: the client ships against the in-memory fold for
v1; once BE-002 lands, the repository's `weeklyLogDayCount` swaps
to a single `GET` and the provider's behavior is unchanged. Not
blocking.

### 7.5 Acceptance criteria — F10

- `weeklyLogDaysProvider` lives at
  `client/lib/providers/log_providers.dart` (extends the existing
  log-domain providers file). Returns `FutureProvider<int>`.
- `LogRepository.weeklyLogDayCount()` returns 0..7. Mock walks
  `_state`, the live client (post-BE-002) walks the GET.
- `_WeekProgressPill` widget lives inside `ring_summary_card.dart`
  (file-private; the pill is only used by this card). Rendered
  between the ring caption and the macro bars on both compact and
  expanded card paths.
- The pill is hidden when count == 0. Rendered text:
  `"This week · N/7 days logged"` for count 1..7. When count ==
  7, the accent colour applies; otherwise the ink2 wash.
- The pill carries a single Semantics node:
  `"This week, four of seven days logged"`. T-20 honoured.
- The pill is not routable on tap.
- Every `LogRepository` mutator's `@invalidates` doc-tag block
  adds `weeklyLogDaysProvider` to the list.
- Tests:
  `client/test/widgets/ring_summary_card_streak_pill_test.dart`
  covers (a) hidden at 0; (b) rendered "3/7" for 3-day fixture;
  (c) accent colour at 7/7; (d) Semantics announcement matches
  the rendered text.

---

## 8. Cross-cutting themes — how each lands

PM doc §3 named seven themes (A–G); their disposition was: A accept,
B accept, C accept, D modified-mixed, E modified-defer, F deferred,
G mostly deferred. Each, in one paragraph:

**Theme A (Today header has lost its anchor).** Accepted. Lives in §6
of this plan. Three PRs (avatar+bolt; swipe; chevron-merge final)
implement the per-affordance edits. The PM's swipe-prerequisite gate
on chevron-merge is honoured by the PR split.

**Theme B (Daily-ritual paths too long).** Accepted. Instantiated as
F1 (§3) + F2 (§4). F2 alone cuts the re-log path from 6 taps to 3;
F1 cuts the re-meal path from 12+ to 2. The `QuickAddChips` lift
(§2) is the prerequisite refactor that makes F2 a clean additive
change.

**Theme C (Tappable affordances that do nothing).** Accepted. The
named sites are in `food_detail_screen.dart:300` (no-op `more_horiz`
overflow), `weight_screen.dart:152` (calendar icon `onPressed:
null`), `weight_screen.dart:300` ("See all" plain text reading as a
button). All three: **delete in v1**. The pattern matches QL-006 /
QL-007. **Architect addition**: a grep sweep across `features/*` for
`onPressed: () {}` and `onPressed: null` catches any other
instances. The PR is mechanical; PMgr can size it as a single
"dev-ticket-CT-001 dead-affordance sweep" ticket separate from the
feature PRs.

**Theme D (Edit/Save enablement inconsistent).** Modified to
mixed-response. PM ruled: accept the "disable when unchanged" rule
for `HeightStepperSheet` and `CurrentWeightSheet` (the two silent
no-op-PATCH cases); defer the broader audit + lint to v1.1. Lives as
a two-line fix in each sheet — the save handler's button enabled
state reads `_isDirty()`. Architect read: this is two ~3-line PRs,
not part of the UX-pack feature surface. PMgr can fold into a single
"Theme D narrow fix" dev ticket.

**Theme E (Loading skeletons good, error noisy).** Modified-deferred.
PM ruled: defer the global debounced SnackBar to v1.1; this pack
ships a small `snackbar_throttle.dart` helper (per-screen 3-second
cooldown). Architect's read: the helper is ~10 lines, lives in
`lib/widgets/snackbar_throttle.dart`, and is opt-in. The screens that
adopt it in this pack are the ones whose SnackBar surfaces could
stack on a flaky-network burst — `CopyDaySheet` (F1's failure path),
`LogWeightSheet` (the existing save error). Other screens stay
unchanged. PMgr can size as one small dev ticket.

**Theme F (Medium breakpoint is "phone with padding").** Deferred to
v1.1. PM ruled it out of scope; architect agrees — the iPad-portrait
user is rare in the v1 cohort, and the fix (compress medium boundary
or commit to rail-style nav at medium) is a substantial layout pass.
The v1.1 ticket: "Medium breakpoint design pass — pick rail-style
nav or shrink boundary to 720." Not in this pack. The prerequisite
that would unblock it: a design hand-off for the medium breakpoint
shape.

**Theme G (Discoverability lags value).** Mostly deferred; one
PM-accept (the "one-line tip below the ring on day 2") was itself
deferred to v1.1 because it intersects with F10's pill real-estate.
The prerequisite that would unblock the v1.1 work: F10's pill
shipped + a week of telemetry on whether users discover the
tap-to-edit / copy-meal affordances unaided. Architect's read:
agree, and add that the "what's new" footnote PM-rejected for v1
becomes plausible *after* there's a release cadence. Until then,
the empty-day pill + the visible affordances are the only nudges.

---

## 9. Per-screen / per-item map

The PMgr reads this to confirm coverage.

| PM item | Section of this plan |
|---|---|
| F1 — Copy yesterday's meal | §3 (Feature F1 deep dive) |
| F2 — Recent-foods chip on Today compact | §4 (Feature F2 deep dive) |
| F4 — Weight chart scrub | §5.1 |
| F5 — Weight log pre-fill | §5.2 |
| F10 — Streak pill / weekly logging | §7 (Feature F10 deep dive) |
| Theme A — Today compact header compression | §6 (Refactor deep dive) |
| Theme B (cross-cutting) | §8 — instantiated as F1 + F2 |
| Theme C (cross-cutting) | §8 — Dead-affordance sweep, dev ticket |
| Theme D (cross-cutting) | §8 — narrow fix for two sheets |
| Theme E (cross-cutting) | §8 — `snackbar_throttle.dart` helper |
| Theme F (cross-cutting) | §8 — deferred v1.1 |
| Theme G (cross-cutting) | §8 — mostly deferred |
| Goals card "Edit current" / "New goal" hierarchy | §8 (one-line outlined-vs-primary change, dev ticket) |
| `_TopSearchField` Semantics(button: true) | §8 (a11y dev ticket) |
| `MergeSemantics` on `MacroBar` row | §8 (a11y dev ticket) |
| `LiveRegion` on pending-sync badge | §8 (a11y dev ticket) |
| Profile "(dev)" version-tag grep | §8 (mechanical dev ticket — pre-release flavour wiring) |
| BE-002 (weekly logging endpoint) | §7.4 — flagged non-blocking |
| BE-003 (scan history) | Out of scope for this pack |
| BE-004 (goal achievement) | Out of scope for this pack |
| Refactor — `QuickAddChips` lift | §2 |

Every PM-named item is covered.

---

## 10. Tenant updates (if any)

### 10.1 T-12 — FAB long-press menu reading

T-12 says: *"The FAB is the only floating action. No floating help
buttons, no floating dismissers, no floating 'back'. Sticky bottom
CTAs (`PrimaryButton`) sit inside a `BottomAppBar`-shaped footer with
a top divider — they are not floating."*

The FAB long-press menu (§6.2) opens a `showMenu`-style popup
anchored near the FAB. Two readings:

- **Reading 1 (strict)**: the menu is rendered by Material's
  `_PopupRoute`, which is a *route* not a floating widget. The FAB
  itself remains the only floating action; the menu is a modal
  overlay anchored to the FAB. **Stays inside T-12.**
- **Reading 2 (loose)**: the menu visually appears near the FAB
  and reads as a "two-up affordance attached to the FAB," which is
  conceptually a secondary floating affordance even if the
  underlying widget is a route. **Trips T-12 on the spirit.**

**Architect call: Reading 1.** The menu is a route-modal, not a
floating widget. T-12's text targets "floating help buttons,
floating dismissers, floating 'back'" — all *persistent* floating
affordances. A momentary modal triggered by long-press is the same
mechanism as a context menu, which T-12 was never meant to forbid.

**Proposed clarifying rider** (optional — only if PMgr wants T-12's
wording to acknowledge the pattern):

> *T-12 (clarifying rider). A long-press on the FAB may surface a
> momentary modal menu (e.g., `showMenu`'s popup-route surface)
> exposing secondary actions. The menu is a route-modal, not a
> floating widget; the rule against floating affordances applies to
> persistent ones, not momentary ones.*

If PMgr declines the rider, the menu still ships under Reading 1
and the next reader treats the precedent as the rule. PMgr — flag
in §12 for confirmation. My recommendation: ship the rider; the
T-12 surface gets one more sentence and the next sheet that wants
a FAB long-press menu doesn't have to re-litigate.

### 10.2 No other tenants

T-24 (post-mutation navigation) covers F1's save handler (Case 2 —
route-to-effect, `pathForDay(targetDate)`). T-23 covers the
`QuickAddChips` lift. T-15 covers the `_TodayRecentChipsRow` mount
gate. T-19 covers the sparkline scrub's painter-only extension.
T-21 covers the F4 tooltip's display unit. T-20 covers every new
Semantics label. There is no other architecture-spec surface
change.

---

## 11. Test seams

The new and changed test surfaces. The PMgr notes these in dev
tickets so the right harness is in place.

**`LogRepository.copyDay` — mock semantics fake.** New test file
`client/test/repositories/log_repository_copy_day_test.dart`. The
test surface:

```dart
test('copyDay recomputes snapshots against current food state', () {
  // Set up: seed food with calories 200/100g; log entry on day 1
  // with quantity 1, kcal snapshot 200.
  // Edit food to calories 300/100g.
  // Copy day 1 → day 2.
  // Assert: copied entry's kcal snapshot is 300 (current food
  // state), not 200 (source's frozen snapshot).
});

test('copyDay skips entries whose food was deleted', () { ... });
test('copyDay skips entries whose serving was deleted', () { ... });
test('copyDay returns subset when partial skip', () { ... });
test('copyDay accepts whole-day (meals: null) and meal-filter', () { ... });
test('copyDay does not invalidate source-date providers', () { ... });
```

Six tests; each isolated; no async beyond the awaited `mockLatency`.
The mock test seam is exactly the existing `LogRepository`
test pattern (see `log_repository_test.dart`).

**Sparkline scrub — gesture testability.** New test file
`client/test/features/weight/sparkline_scrub_test.dart`. The test
surface uses `WidgetTester.dragFrom` and `WidgetTester.startGesture`
+ `gesture.moveBy` to simulate the horizontal-drag pattern. The
critical assertion is:

```dart
testWidgets('horizontal drag emits guideline + tooltip', (tester) async {
  await tester.pumpWidget(...);
  final chart = find.byType(WeightSparklineCard);
  final gesture = await tester.startGesture(tester.getCenter(chart));
  await gesture.moveBy(const Offset(20, 0));
  await tester.pump();
  expect(find.byKey(const Key('scrub-tooltip')), findsOneWidget);
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 150));
  expect(find.byKey(const Key('scrub-tooltip')), findsNothing);
});

testWidgets('vertical drag does not block parent scroll', (tester) async {
  // Mount the chart inside a ListView with extra content below.
  // startGesture at chart center; moveBy(0, -100); up.
  // Assert: the ListView's ScrollController.offset changed by
  // ~100px.
});
```

The `_ScrubOverlayPainter` exposes a stable `Key`
(`Key('scrub-tooltip')`) so widget tests can `find.byKey` it.

**Swipe-day gesture — testability.** New test file
`client/test/features/today/day_swipe_gesture_test.dart`. The test
uses `WidgetTester.fling`:

```dart
testWidgets('left fling routes to next day', (tester) async {
  await tester.pumpWidget(buildDayView(date: DateTime(2026, 5, 15)));
  await tester.fling(
    find.byType(DaySwipeWrap),
    const Offset(-200, 0),
    400, // velocity px/sec — above threshold.
  );
  await tester.pumpAndSettle();
  expect(
    router.routerDelegate.currentConfiguration.fullPath,
    '/today/2026-05-16',
  );
});
```

Four tests (left, right, below-threshold, vertical).

**F1 copy-day sheet — widget tests.** New file
`client/test/features/today/copy_day_sheet_test.dart`. Mount the
sheet via `showCopyDaySheet`; assert the initial state (source-date
defaults to yesterday, meal-scope chip pre-selected from the entry
point), the live preview updates as the user scrubs the source-date,
the save button label includes the row count, and the post-save
SnackBar carries the partial-skip text when fewer entries land than
were requested.

**F2 chip strip — widget test.**
`client/test/features/today/recent_chips_row_compact_test.dart`.
Three tests: rendered-with-recents, hidden-on-backdate,
hidden-when-empty.

**F5 pre-fill — widget test.**
`client/test/features/weight/log_weight_prefill_test.dart`. Three
tests covering the three branches of the fall-through.

**F10 pill — widget test.**
`client/test/widgets/ring_summary_card_streak_pill_test.dart`. Four
tests: hidden-at-0, rendered-at-3, accent-at-7, semantics.

**Header compression — widget test.**
`client/test/features/today/header_compression_test.dart`. Asserts
the ring's `globalKey` paints within 320 px of the safe-area top on
a Pixel 4a viewport. Mounts `DayViewCompact` with seeded
`daySummaryProvider`; reads the `RenderBox.localToGlobal(Offset.zero)`
of the ring's key.

---

## 12. Risks / open questions for PMgr

### 12.1 Swipe-day gesture vs chevron-merge ticket split

**The architect picked two distinct tickets** (§6.5). The combined
single-ticket approach is also valid. PMgr — confirm Option B
(two tickets, chevron-merge gates on swipe landing). If you prefer
Option A (one PR), the same code lands; only the PR shape changes.
**My recommendation: Option B**, because the swipe gesture deserves
its own test surface and review attention separate from the trivial
chevron removal.

### 12.2 Streak metric — Mon-vs-Sun start of week

**The architect picked Monday** (§7.1), matching the PM ruling in
the PM UX pack §2 F10 ("Monday–Sunday in the user's local time").
The US-convention alternative is Sunday-start. PMgr — confirm
Monday holds. If the user data shows a US-heavy cohort with strong
Sunday-start mental model, the flip is one line in `_mondayOfWeek`
(rename + adjust `daysSinceMonday` math). I expect Monday to hold;
the PM doc named it; documenting for completeness.

### 12.3 F2 chip provider — recents only, or new "today-bound" provider

**The architect picked `recentFoodsProvider`** as the data source
for F2's chip strip (§4.3). The current `recentFoodsProvider` is
`GET /foods/recent`, which is global (not date-bound). One subtle
concern: the strip on Today compact reads "your recents," and the
user's recents includes Quick-add synthetic entries. The PM doc §2
F2 doesn't disambiguate whether Quick-add entries should appear in
the strip; the existing right-rail card includes them today.

Two options:

- **Option A (architect's pick)**: use `recentFoodsProvider` as-is;
  Quick-add entries appear in the strip when they're in the user's
  recents. Consistent with the right rail.
- **Option B**: introduce a `recentRealFoodsProvider` that filters
  out the Quick-add synthetic food id; the strip uses the filtered
  version.

**My recommendation: Option A** (no new provider). Reasons: (1) the
PM doc consistency-with-the-right-rail rationale holds — both
surfaces should mirror; (2) Quick-add entries in the strip are
benign (tap → opens `LogEntrySheet` against the synthetic food,
which is a no-op since the synthetic food has only the synthetic
serving and the user just gets another Quick-add — minor surprise,
not breakage); (3) introducing Option B adds a provider that no
other surface needs. PMgr — confirm Option A; flag if user testing
shows Quick-adds in the strip as confusing.

### 12.4 The 60-day floor on `CopyDaySheet`'s source-date picker

**The architect picked 60 days** (§3.4 (C)). PM doc §2 F1 doesn't
name a floor. The 60-day choice matches QL-009's TodayPill /
backdate range (chosen by PM in §6 of `pm_qol_audit.md`). Symmetry.
PMgr — confirm the floor; if you want unbounded ("Copy from any
day in your history") that's also valid given the wire's
silent-skip semantics.

### 12.5 T-12 clarifying rider — accept or decline

**The architect proposed a one-sentence rider** (§10.1) clarifying
that FAB long-press menus stay inside T-12. PMgr — confirm. If
declined, the FAB long-press menu still ships under the strict
reading; only the tenant's wording stays the same.

### 12.6 The QuickAddChips compact-mode flag

**The architect picked a flag-on-the-public-widget approach** (§4.2
Option A), versus mounting only on expanded and lifting the chip
primitive (Option B). PMgr — confirm Option A. My recommendation:
Option A; the alternative double-lifts a private leaf and doubles
the migration cost.

---
