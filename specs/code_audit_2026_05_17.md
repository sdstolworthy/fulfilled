# Codebase audit — 2026-05-17 (Fowler-school review)

## Executive summary

The Flutter client is **architecturally honest**: domain types know about their
data and behaviour, repositories are the only place that talks Dio, screens
read from typed Riverpod providers, and the recent Ask-10 reshape has left
clean seams in the right places (per-serving math on `Serving`, no per-100 g
leakage into the wire types, `Unit`/`UnitFamily` polymorphism replacing what
used to be ad-hoc conditionals). Tests pass and the analyzer is quiet. The
codebase is in the "ready to grow" state, not the "code red" state.

The drift to watch is concentrated in three places. **First**, the two
sheet flows (`LogEntrySheet`, `QuickAddSheet`) and the day-view internals
have started to *braid* — each sheet's `ConsumerStatefulWidget` carries form
state, IO, navigation, invalidation, route formatting and form-factor
branching in one body, and the two sheets have grown ~80 % isomorphic copies
of the same submit/route-to-effect machinery. **Second**, `FoodRepository`
and `LogRepository` carry a `useFixtures` switch that doubles their public
surface and pulls real domain logic (`computeLogEntry`, default-serving
selection, quick-add overlay) into the repo file — that seam is the next
refactor target before the live API lands. **Third**, the test suite leans
on inline 30-line `Food`/`LogEntry` constructors in every file with no
shared builder, which has already started costing minutes per schema change
and will keep costing them as Ask-11 lands.

The top three themes I'm recommending are: **(1)** lift a `LogSubmitController`
that owns the submit/invalidate/route triad and lets the sheets shrink to
view layer; **(2)** lift `computeLogEntry` + default-serving selection onto
the `Serving`/`Food` domain types and remove the `useFixtures` dual-path
from the repos; **(3)** introduce a single `test/fixtures.dart` with
`buildFood({...})`/`buildLogEntry({...})` named-param builders so domain
schema drift only touches one file.

## Findings

### 1. [SoC] — `LogEntrySheet` carries five responsibilities in one widget

**Location.** `lib/features/log_entry/log_entry_sheet.dart:243-600`
(`_LogEntrySheetBodyState`; the file is 1281 lines).

**What's there.** The single `State` class owns form fields
(`_meal`, `_serving`, `_date`, `_enteredUnit`, `_noteCtrl`, `_submitting`),
the `_buildLogCreate` / `_buildLogPatch` / `_isUnchanged` form-vs-seed
diffing, the create-vs-edit submit branching (`_onCreatePressed`,
`_onEditPressed`), the form-factor branching (`if (formFactor.isCompact) …
outbox; else … repo.create`), the invalidation block, the post-save route
computation (`pathForDay(_date)`), the dialog-vs-route pop ordering, and
the SnackBar error surface. The `widget.onSubmit` test seam exists but is
called *before* the real work as a fire-and-forget — every test that wants
to assert "did the right thing happen" still has to pump the world.

**Why it bites.** This is the screen most likely to grow: PM-side LU-002
already added edit mode, QL-105 added route-to-effect, QL-107 added the
date picker, FX-001 added the quick-add fork. Each new ticket has had to
re-read the entire body to find the right ordering of pop/`go`/invalidate
calls (compare lines 487-490 vs. 510-517 vs. 587-593 — the same three
operations in three subtly different orders). The next ticket that adds,
say, "auto-tag this log as 'matches your goal'" will have to re-read it
again and re-derive the order. When the day-view's `editLogEntry` helper
was extracted in LU-005 (`today_internals.dart:125-172`), it pulled four
guards out of the call site — that's the pattern the sheet itself wants.

**Proposed refactor.**

- Introduce `lib/features/log_entry/log_submit_controller.dart` — plain
  Dart, no Riverpod-notifier required. Two methods: `submitCreate(ref,
  formFactor, draft) → Future<SubmitResult>`, `submitEdit(...)`. The
  controller owns repo/outbox dispatch and returns `SubmitResult { entry,
  routeTarget }`; the widget then pops + `go`s in *one* place.
- Move `_buildLogCreate` / `_buildLogPatch` / `_isUnchanged` / `_sameDay`
  into a value-type `LogSheetForm`, or onto `LogCreate`/`LogPatch` as
  named ctors (`LogPatch.diff(original, current)`).
- Promote `_DateRow` to `widgets/` (finding 11).
- Keep the per-sheet `quantityProvider` `ProviderScope` override —
  that's orchestration earning its keep.

Files touched: `log_entry_sheet.dart` shrinks ~250 LoC; new
`log_submit_controller.dart` and `log_sheet_form.dart`; widget tests
mostly unchanged.

**Priority.** P1. The sheet is the hottest screen for incoming work.

**Effort.** M. One day.

---

### 2. [SoC] — `QuickAddSheet` is an 85 % copy of `LogEntrySheet`'s submit machinery

**Location.** `lib/features/quick_add/quick_add_sheet.dart:389-512` (`_onCreatePressed`,
`_onEditPressed`) vs. `lib/features/log_entry/log_entry_sheet.dart:453-600`
(same methods).

**What's there.** Both files have:

- An `_isEditing` getter.
- An `_isUnchanged()` predicate over a small form-vs-seed diff.
- A `_sameDay(DateTime, DateTime)` helper inlined inside the State.
- An `_onSavePressed` that dispatches to `_onCreatePressed` / `_onEditPressed`.
- The `_onCreatePressed` body: build payload → fire `onSubmit?` test seam
  → call `repo.create` (with form-factor branching to the outbox on compact
  in `LogEntrySheet` only) → invalidate the same four families →
  pop-first/`go`-second on dialog, `go` on bottom-sheet → SnackBar on
  error.
- The `_onEditPressed` body: build patch → if `patch.isEmpty` pop +
  `go(newDate)` → call `repo.update` → invalidate (with the
  originating-date branch on date shift) → pop + `go(newDate)` → SnackBar
  on error.

The two `_DialogEnterAnimation` private classes are *byte-identical*. The
two `_DateRow` and `_SectionLabel` private classes are byte-identical
modulo key strings. Both files import `pathForDay` from `today_internals.dart`.

**Why it bites.** If you change the route-to-effect ordering (e.g. tomorrow
the PM decides save should *not* navigate when the form was opened from
the food-detail screen and the user has not yet seen Today this session),
you have to find both code sites, re-derive the dialog pop ordering, and
re-verify the SnackBar fires after the pop. The QL-105/QL-107/FX-001
ticket trail shows this has *already* happened twice — each ticket touched
both files with prose comments that explicitly cross-reference each other
("mirrors `LogEntrySheet`'s architect §6.3 carveout"). Cross-reference
comments are the smell — they're the codebase telling you the shared
behaviour wants a shared home.

**Proposed refactor.**

- Lift a `LogSheetScaffold` widget in `lib/features/log_entry/` (or
  `lib/features/_log_shared/`) that renders the form-factor split, the
  grabber, the close button, the section labels, the date row, and the
  footer. It takes the form body as a child slot.
- Lift `submitCreate(...)` / `submitEdit(...)` per finding 1; the
  quick-add sheet's variant is a trivial config (no entered-unit math, no
  outbox path).
- Pull `_dialogEnterAnimation` into `lib/widgets/motion.dart` next to the
  existing `motion()` helper.
- The Quick-add sheet's `_DateRow` becomes the same widget instance the
  `LogEntrySheet` uses.

Files touched: both sheets; new `lib/features/_log_shared/log_sheet_scaffold.dart`
(or under `widgets/`); `quick_add_sheet_test.dart` / `log_entry_sheet_test.dart`
keep their pumps and assertions because the public widget shape is
unchanged. Risk: low — the two sheets are *already* identical in behavior
where they overlap; the refactor just makes the identity structural.

**Priority.** P1.

**Effort.** M. Half a day, gated by the controller in finding 1.

---

### 3. [SoC / design-for-change] — `useFixtures` doubles repo public surface and bakes domain logic into the repository layer

**Location.** `lib/repositories/food_repository.dart:32-498`,
`lib/repositories/log_repository.dart:24-413`, `lib/repositories/_fixtures.dart`
(1337 lines).

**What's there.** Every public method on `FoodRepository` and
`LogRepository` is a two-branch `if (_useFixtures) … else … (Dio)` (12
methods × 2 branches in `FoodRepository`; 7 in `LogRepository`). The
fixture branches *invent ids*, *mutate an in-memory store*, *apply
defaulting rules* ("if no serving is marked default, the first is"),
*re-anchor sort orders*, and call out to `fx.computeLogEntry` —
which itself computes the nutrition snapshot from
`serving.kcal × quantity` plus six macro multiplications. That's *domain
logic*, not test data. The dual surface forces the public methods to
carry behavior the live path will never exercise (default-flag flipping,
sort_order renumbering), and the live path has to mirror the same
post-conditions even though the server is what enforces them.

Concretely from `food_repository.dart:205-248`:

```dart
servings.add(Serving(
  id: 'sv_${DateTime.now().microsecondsSinceEpoch}_$i',
  ...
  isDefault: s.isDefault ||
      (i == 0 && data.servings.every((x) => !x.isDefault)),
  source: ServingSource.user,
  sortOrder: i + 1,
));
```

The "first-serving-is-default-if-none-set" rule, the `ServingSource.user`
tag, and the `sortOrder: i + 1` policy belong on `FoodCreate` (a domain
type) or on a `FoodFactory`; they should not be invented by either the
repository *or* a separate live-mode branch.

**Why it bites.** Two angles. (a) The day the live API ships, the
fixture branches are dead code by definition — but they currently carry
behavior the live path silently depends on (the cache `_byIdCache`, the
`noteFoodLogged` no-op, the `_decodePaginatedHits` synthesizing a single
serving from a hit). Deleting the fixture branches will require
re-reading every method to confirm the live branch alone is complete.
(b) The fixture file *is* the seed for half the widget tests. If the FE
wants to add a new field (Ask 11 will), `_fixtures.dart` + the
fixture-mode branches in both repos + the live-mode decoders all have to
shift in lockstep. The grep surface for "where does Serving get a
sortOrder" is currently five files.

**Proposed refactor.**

- Lift `computeLogEntry` onto the domain as
  `LogEntry.snapshotFor({serving, quantity, …})` — sibling to the
  existing `Serving.kcalFor` / `Serving.macroFor`.
- Lift default-serving promotion + sort-order numbering onto
  `FoodCreate.normalize()`. Both paths call the same normaliser.
- Replace the `useFixtures` bool with two concrete subclasses:
  `InMemoryFoodRepository implements FoodRepository`,
  `InMemoryLogRepository implements LogRepository`. Tests construct
  the in-memory variant; production wires the Dio variant.
- Drop `noteFoodLogged` and the `LogRepository._foodRepo.get` crossings
  (finding 5).

Files touched: both repository files shrink ~40 %; `_fixtures.dart`
shrinks to seed data only; new `in_memory_*` files;
`domain/log_entry.dart` snapshot helper. Repo tests call
`buildLiveFoodRepository(api)` (already the existing pattern in
`test/repositories/_harness.dart:31`).

**Priority.** P1. The live API rollout is the moment this gets expensive
to defer.

**Effort.** L. A full day if done end-to-end; can be staged (start by
extracting `LogEntry.snapshotFor`).

---

### 4. [design-for-change] — Domain types carry hand-written `==`/`hashCode`/`copyWith`/`fromJson`/`toJson` boilerplate

**Location.** `lib/domain/food.dart:85-180`, `serving.dart:92-218`,
`log_entry.dart:64-178`; same pattern in `goal.dart`, `user.dart`,
`weight.dart`, `nutrition.dart`. Each class has ~80-100 lines of
boilerplate; every field appears in five places. The `_listEq` helper is
inlined privately in two files.

**Why it bites.** Adding a field is mechanical but error-prone — the
audit caught `categoriesTags` on `Food` not being mirrored onto
`FoodSearchHit`, which may be intentional but isn't enforced. Every
drift is a latent bug.

**Proposed refactor.** No codegen (constraint respected). Lift
`domain/_eq.dart` with `listEquals<T>(...)` and a `propsEqual(List,
List)`. Each class declares a `List<Object?> get _props => [field1,
field2, ...];` and the operators read from it. Adding a field becomes
one edit to `_props` plus the typed-constructor / json sites (which the
analyzer catches).

**Priority.** P2. Smell, not load-bearing.

**Effort.** S to lift; M to sweep all classes.

---

### 5. [SoC] — `LogRepository` reaches across repos to mutate `FoodRepository` state

**Location.** `lib/repositories/log_repository.dart:107, 134, 158,
171, 248, 263, 286, 332, 383`. `LogRepository` holds `_foodRepo` and
calls `_foodRepo.get(foodId)` to resolve a `Food` for snapshot
computation, `_foodRepo.noteFoodLogged(foodId)` after every successful
create / adopt / copy (currently a documented no-op), and
`_foodRepo.lookup(foodId)` inside `_decodeEntryWithDenorm` for
display-name fallback.

**Why it bites.** Two real Demeter violations: `get(foodId)` from
inside `create` is the repo doing food fetching that the *screen*
already did (it had the `Food` in hand when it built the
`LogCreate`); `noteFoodLogged` couples "post a log" to "tell the
catalog this food got used" — the live `/foods/recent` endpoint makes
the local hook dead weight. The `lookup`-for-display-fallback is fine
— that's wire-decode denormalization, which is the repo's job.

**Proposed refactor.** Subsumed by findings 1 and 3: the
`LogSubmitController` already has the `Food`, so `LogRepository.create`
becomes a simple Dio POST. Drop `noteFoodLogged` entirely.

**Priority.** P2.

**Effort.** S.

---

### 6. [LoD] — Cross-feature `import '../today/today_internals.dart' show pathForDay;` from log_entry and quick_add

**Location.** `lib/features/log_entry/log_entry_sheet.dart:21`,
`lib/features/quick_add/quick_add_sheet.dart:19` import the today
helper; `lib/features/today/{day_view_compact,day_view_expanded,today_internals}.dart`
import `log_entry/log_entry_sheet.dart` + `quick_add/quick_add_sheet.dart`
to call `showLogEntrySheet` / `showQuickAddSheet`.

**What's there.** `pathForDay(DateTime) → String` is a 10-line pure
function that maps a date to `/today` or `/today/YYYY-MM-DD`. It lives
inside `today_internals.dart` (518 lines, mostly widgets — `TodayPill`,
`DatePill`, `DaySwipeWrap`, `editLogEntry`, `TodayErrorCard`) because
it was first written for the today feature. Two other features now
import it for the same reason: post-save route-to-effect lands on a
day view.

**Why it bites.** The dependency graph is now cyclic at the feature
folder boundary: `today/` depends on `log_entry/` (it opens the sheet),
and `log_entry/` depends on `today/` (it routes to the day view).
Cycles in the feature layer mean (a) the two features can't be
extracted independently if v2 splits a feature into a package, and
(b) every test that pumps `LogEntrySheet` transitively pulls in all of
`today_internals.dart` including its riverpod imports, even though the
only thing it needs is one pure function.

**Proposed refactor.**

- Promote `pathForDay`, `Routes.todayPath` already in `routing/routes.dart`
  — move `pathForDay` next to it as `Routes.todayPathFor(DateTime)`. The
  routing layer is the natural home for path computation.
- Same for `isLocalNowDay` (used by `pathForDay` and `DatePill`) — that's
  a `DateTime` helper, `lib/domain/_dates.dart` or `lib/util/dates.dart`.
- After: `log_entry_sheet.dart` / `quick_add_sheet.dart` import
  `routing/routes.dart` (already legitimate) and no longer reach into
  `features/today/`.

Files touched: `routing/routes.dart`, `features/today/today_internals.dart`,
the two sheet files, plus any test that explicitly imports `pathForDay`
from `today_internals.dart` (a grep is one minute). Tests on the today
internals stay where they are; they keep testing the widget exports.

**Priority.** P2. Concrete cost is low today; rises when v2 lifts a
feature into a package.

**Effort.** S.

---

### 7. [SoC] — Domain logic on the literal seam: `computeLogEntry` in `_fixtures.dart`

**Location.** `lib/repositories/_fixtures.dart:1216-1261`.

**What's there.** The function takes `(food, serving, quantity, …)`
and returns a `LogEntry` whose `nutritionSnapshot` is
`serving.kcal × quantity` (and macros). It's called from three places
inside `LogRepository` (fixture branches of `create`, `update`,
`copyDay`) and indirectly from the seed-data builders inside the same
file.

**Why it bites.** A header comment two lines above the function says
"per Ask 10 the math no longer routes through per-100g — the serving
carries its own nutrition." That comment is the *Ask 10* tell:
"snapshot of a log entry from a serving + a quantity" is *the central
invariant of the data model*. Hiding it inside a file labelled
`MOCK ONLY — this entire file is deletable once the real API is wired`
(line 1 of `_fixtures.dart`) means the day the file is deleted, the
invariant has to be re-derived from the BE response shape. There's no
type that says "I am the snapshot rule."

**Proposed refactor.**

- Add `LogEntry.snapshotFor({required Serving serving, required Decimal
  quantity, required Food food, required Meal meal, required DateTime
  consumedOn, …})` as a named constructor on `LogEntry`. Body is the
  current `computeLogEntry` body, minus the Quick-add overlay (which
  belongs in the sheet's `_buildLogCreate`).
- Tests that need a snapshot for a fixture call `LogEntry.snapshotFor(…)`
  and read the result. The `_fixtures.dart` shrinks to seed-data only
  (the foods, the goals, the weights), no computed shapes.
- The repository fixture branches that called `fx.computeLogEntry`
  disappear under finding 3.

Files touched: `domain/log_entry.dart` (+30 lines), `repositories/_fixtures.dart`
(-50 lines), the fixture branches in `log_repository.dart` (deleted
under finding 3).

**Priority.** P1.

**Effort.** S. An hour standalone; trivial under finding 3.

---

### 8. [SoC] — Widget-layer `_quickAddFoodId` constant duplicated in three places

**Location.** `lib/features/quick_add/quick_add_sheet.dart:25`,
`lib/features/today/today_internals.dart:11` (imports it from `_fixtures.dart`),
`lib/widgets/meal_section.dart:483`. The string `'food_quick_add'` is
also embedded in `lib/repositories/_fixtures.dart:84` (the canonical
declaration) and three test files.

**What's there.** Each file that needs to branch on "is this entry a
quick-add row?" defines / imports its own copy of the constant. The
comment on `meal_section.dart:479` explicitly says "Kept inline here so
the widget layer doesn't import the mock-data file (which is documented
as deletable once the real API lands). When the API ships, the
synthetic food's id is stable across mock and live."

**Why it bites.** The intent is right ("don't depend on a mock file
from a widget") but the implementation is wrong (three string copies
that have to agree forever). When the API lands and the mock file is
deleted, the *canonical* declaration disappears too — the widget-layer
copies become the only declarations, and they're scattered. The
"deletable once" comment is misleading.

**Proposed refactor.** Promote the constant to a real domain home —
`lib/domain/quick_add.dart` with:

```dart
/// Stable id of the synthetic Quick-add food across mock + live.
const String quickAddFoodId = 'food_quick_add';
const String quickAddServingId = 'sv_kcal';
```

Every site (widgets, sheet, today, fixture, tests) imports from there.
`_fixtures.dart` reads from the same constant.

**Priority.** P2. Cosmetic until the mock-file deletion is scheduled,
then becomes a P1 blocker for that deletion.

**Effort.** S.

---

### 9. [design-for-change] — `Unit`'s five property accessors are five parallel switches

**Location.** `lib/domain/unit.dart:42-149`. `wire`, `shortLabel`,
`longLabel`, `family`, `ratioToCanonical` are each a complete `switch`
over the 12-value enum. Plus `fromWire` and `_parseUnitToken` (another
50-line alias switch).

**Why it bites.** Adding a unit (`floz_imp`, `gallon`) means amending
five typed switches plus the parser. The Fowler *Replace Conditional
with Polymorphism* shape would be a sealed-class hierarchy, but that
breaks `Unit.values` / `Unit.g` sugar that hundreds of call sites use.

**Proposed refactor.** Stay an enum; use Dart's enhanced enums to
declare all five properties in the constructor next to each value:

```dart
enum Unit {
  g(wire: 'g', shortLabel: 'g', longLabel: 'gram',
    family: UnitFamily.mass, ratioToCanonical: '1'),
  kg(wire: 'kg', ...), ...;
  const Unit({required this.wire, ..., required String ratioToCanonical})
    : _ratio = ratioToCanonical;
  ...
  Decimal get ratioToCanonical => Decimal.parse(_ratio);
}
```

Adding a unit becomes a one-line edit. `_parseUnitToken` (alias parser)
stays a switch — that's its nature. No call sites change.

**Priority.** P2.

**Effort.** S.

---

### 10. [flex-tests] — Every test file declares its own multi-line `Food` / `LogEntry` literal

**Location.** `test/features/log_entry/log_entry_sheet_test.dart:36-62`,
`test/features/today/edit_log_entry_tap_test.dart:56-103`,
`test/features/quick_add/quick_add_sheet_test.dart`, `test/features/today/empty_day_pill_test.dart`,
plus ~10 others. ~75 hand-written `Food(...)` constructor calls across
the test tree, plus parallel `LogEntry(...)` / `Serving(...)` literals.

**What's there.** Every test that needs a deterministic `Food` writes
its own — usually a 26-line block declaring `id`, `name`, `brand`,
`barcode`, `source`, `isCustom`, `qualityScore`, `nutriscore`,
`servings: <Serving>[ … 14 fields … ]`. When Ask 10 added required
`amount` + `unit` to `Serving`, the migration touched dozens of these
literals.

**Why it bites.** Every domain schema change costs time linear in the
number of test files. The migration cost is also the *expressivity*
cost: a test reading
```dart
Food(id: 'f_test', name: 'Test food', brand: 'TestBrand', barcode: null,
     source: FoodSource.off, isCustom: false, qualityScore: null,
     nutriscore: null, servings: <Serving>[Serving(id: 'sv_100g', label: '100 g',
     amount: Decimal.fromInt(100), unit: Unit.g, kcal: Decimal.fromInt(100), …)])
```
buries the *intent* of the test ("a single-serving deterministic food
at 100 kcal/100 g") under 20 lines of incidental fields. A maintainer
reading the test can't tell which fields matter for the assertion
and which are filler.

The task statement explicitly forbids codegen, which is right. The
solution is a **builder file** — pure Dart, no annotations.

**Proposed refactor.**

- Create `test/_fixtures.dart` with intent-named builders:

```dart
Food buildFood({
  String id = 'f_test',
  String name = 'Test food',
  FoodSource source = FoodSource.off,
  List<Serving>? servings,
}) => Food(
  id: id, name: name, brand: null, barcode: null,
  source: source, isCustom: source == FoodSource.user,
  servings: servings ?? <Serving>[buildServing()],
);

Serving buildServing({
  String id = 'sv_default', Decimal? kcal, Unit unit = Unit.g,
  Decimal? amount, ...
}) => Serving(...);

LogEntry buildLogEntry({Food? food, Serving? serving, Decimal? quantity, …});
```

- Tests then read: `final food = buildFood(servings: [buildServing(kcal: 200)]);`
  — the *deviation from default* is the test's intent.
- Schema migrations now touch *one* file (the builders); the test
  bodies inherit defaults.

Files touched: new `test/_fixtures.dart` (~200 lines), then incrementally
the live (non-quarantined) test files. Quarantined files stay as-is
for now per scope.

**Priority.** P0. Real velocity is being lost here today — every Ask
takes a multi-hour mechanical sweep.

**Effort.** M for the initial builder, then incremental S per test
file. The first non-quarantined test that uses the builders pays the
overhead; subsequent ones are free.

---

### 11. [flex-tests] — Three sheet-leaf widgets duplicated across files with diverged keys

**Location.** `_DialogEnterAnimation` byte-identical in
`log_entry_sheet.dart:165` and `quick_add_sheet.dart:140`. `_SectionLabel`
ditto. `_DateRow` exists three times across `log_entry_sheet.dart:1052`,
`quick_add_sheet.dart:711`, and `weight/log_weight_sheet.dart` with
different test-key strings for what's structurally the same widget.

**Why it bites.** A test asserting on date-row behaviour has to update
three find-by-key strings instead of one; a contract change touches
three files. Widget-level cost is finding 2 — same root cause.

**Proposed refactor.** Lift to `widgets/sheet_section_label.dart`,
`widgets/sheet_date_row.dart`, and add `SheetDialogEnter` to existing
`widgets/motion.dart`. Generic test key `Key('sheet_date_row')`.

**Priority.** P2.

**Effort.** S, subsumed by finding 2.

---

### 12. [flex-tests] — Test assertions on substring kcal values pinned to a specific food

**Location.** `test/features/log_entry/log_entry_sheet_test.dart:85-159`
(quarantined — but the pattern lives on in non-quarantined tests too,
e.g. `test/features/today/empty_day_pill_test.dart`).

**What's there.** Tests assert `find.textContaining('100')`,
`find.textContaining('250')` against a `LogPreviewBlock` rendering. The
intent is "the preview re-renders when quantity changes"; the *test*
asserts on a specific kcal value derived from the in-test `Food` fixture's
specific `kcal: 100`.

**Why it bites.** Two costs:

- If the food's kcal changes (e.g. test fixture builder defaults shift),
  every "the preview shows the right value" test breaks. The assertion
  pins the test to the fixture's specific kcal, not to the *relationship*
  it intends to verify (preview = serving.kcal × quantity).
- A `find.textContaining('100')` matches *any* text containing the
  substring "100" — including timestamps, route paths, semantic
  labels. Real failures get muddied by accidental matches.

**Proposed refactor.** Re-aim tests at *invariants*, not values:

- "Preview re-renders on quantity change" should expect the LogPreviewBlock
  to receive a *different* `quantity` prop (assert via the widget's
  props directly, or via a test-only callback the preview fires).
- Where a value assertion is intrinsic (a parser / formatter test),
  pin it to a named fixture constant: `expect(find.text(formatKcal(testFoodKcal * Decimal.fromInt(2))), findsOneWidget);`
  — the *formula* travels with the assertion.

This is incremental and doesn't require unblocking the quarantined
suite first; new tests written today should follow it.

**Priority.** P2.

**Effort.** S incremental. Establish the pattern in the next sheet test
that gets touched.

---

### 13. [SoC] — `editLogEntry` orchestration in `today_internals.dart`

**Location.** `lib/features/today/today_internals.dart:125-172`. A
free-floating async function (`WidgetRef, BuildContext, LogEntry`)
implementing four gates (pending-sync, quick-add fork, food fetch,
sheet open). Called from both day views.

**Why it bites.** Correct but the *home* is wrong. `today_internals.dart`
is a kitchen drawer (widgets, format helpers, skeleton, and now a
4-gate orchestrator). The next gate ("confirm before editing entries
older than 7 days") gets dropped into the same drawer.

**Proposed refactor.** Move to
`lib/features/log_entry/edit_log_entry_action.dart` — same pattern as
the existing `showLogEntrySheet` / `showQuickAddSheet` /
`showCopyDaySheet` entry points. Tightens the import graph: pairs with
finding 6.

**Priority.** P2.

**Effort.** S.

---

### 14. [flex-tests] — Sheets' `onSubmit` / `onPatch` test seams are "peek at private state" callbacks

**Location.** `log_entry_sheet.dart:222`, `quick_add_sheet.dart:213-219`,
plus `@visibleForTesting initialDate` on `LogEntrySheetBody`
(`log_entry_sheet.dart:206-237` — a 31-line dartdoc on a test-only
field is the codebase telling you it shouldn't exist).

**Why it bites.** Both sheets fire a `ValueChanged<LogCreate>?` *before*
the real submit so tests can capture the payload without booting the
world. That's the canonical "I want a callback so I can peek at
private state" smell — only necessary because the sheet *itself* owns
orchestration (finding 1). Test assertions become "did the right
payload shape get built?" instead of "did the right thing happen?"

**Proposed refactor.** Subsumed by finding 1. After the controller
lift, `onSubmit` / `onPatch` / `initialDate` all disappear; the
controller is testable directly; widget tests assert on rendered
output.

**Priority.** P1. (Pairs with finding 1.)

**Effort.** Subsumed.

---

### 15. [SoC] — `MealSection` is becoming a registration surface for everything the day view wants

**Location.** `lib/widgets/meal_section.dart` (649 LoC). Carries header,
overflow menu (`_CopyMealOverflow`, 80 LoC), entry row (`_EntryRow` +
`_PendingSyncBadge` + `_KcalCell`, 250 LoC), and the add-food footer.

**Why it bites.** The file's dartdoc enumerates ticket-by-ticket API
expansions: LU-005 added `onEntryTap`, QL-108 added `isPendingSync`,
UX-106 added `onCopyMeal` + `canCopyMeal`. Each ticket added a callback
slot to the same constructor. The next will add another. The class is
becoming a callback bag, not a widget.

**Proposed refactor.** Pull `_EntryRow` + `_PendingSyncBadge` +
`_KcalCell` to `widgets/meal_section/log_entry_row.dart` (the
pulse-on-rejected-tap state belongs with the row). Pull
`_CopyMealOverflow` to `widgets/meal_section/copy_meal_overflow.dart`.
`MealSection` shrinks to ~120 LoC and remains the composition root.

Steppers (`weight_stepper.dart` 701, `height_stepper.dart` 662) are
self-contained — defer.

**Priority.** P2. **Effort.** M (steppers deferred).

---

### 16. [LoD / design-for-change] — `formFactorOverrideProvider` reads `defaultTargetPlatform` at construction time

**Location.** `lib/providers/repository_providers.dart:53-64`. A
Riverpod provider that returns `FormFactor.compact` for Android/iOS,
`medium` otherwise; `logRepositoryProvider` reads it to decide whether
to attach the outbox. The 60-line docstring explains "`FormFactor.of(context)`
reads `MediaQuery`, which providers don't have."

**Why it bites.** Wrong on Chromebook/foldables (Android tablet →
"compact" → outbox attached) and on multi-window iPad. More
structurally: "is this entry allowed to queue?" is a property of the
screen (which has `MediaQuery`), not of the platform — pushing it into
a provider that runs at repo-construction time forces re-creation of
the repo to flip the answer, which tears down the in-memory store and
outbox subscription.

**Proposed refactor.** Subsumed by finding 1: the
`LogSubmitController` reads `FormFactor.of(context)` at the call site
and dispatches to outbox-vs-direct itself. `LogRepository` loses its
`outbox` ctor param. `isPendingSync` moves onto the outbox notifier.

**Priority.** P2.

**Effort.** S, subsumed by finding 1.

---

## Cross-cutting themes

### Theme A: Sheet flows want a controller, not bigger State classes

Findings **1, 2, 14, 16** all converge on the same shape. The two
log-entry sheets carry a five-responsibility blob — form state +
form-vs-seed diffing + form-factor branching + outbox/repo dispatch
+ post-save navigation — inside a `ConsumerStatefulWidget.State`.
Every new ticket has added a sixth thing (date picker, edit mode,
quick-add fork). The cost shows up in three places: the size of the
file (1281 LoC for `log_entry_sheet.dart`); the duplication into
`quick_add_sheet.dart`; and the friction of testing the orchestration
(the `onSubmit` / `onPatch` / `@visibleForTesting initialDate`
callbacks are *all* artifacts of "the orchestration lives in a State
class that's hard to peek into").

The lift is **one Dart class per sheet, in `features/<sheet>/`, that
owns submit + invalidate + route**. It does not need to be a Riverpod
notifier; a plain class with `Ref` injected at construction works
fine. The State class shrinks to "form bookkeeping + render."

This is the single highest-leverage change in the audit. Three other
findings (2, 14, 16) are subsumed by it.

### Theme B: The mock-vs-live dual-path in the repos is borrowed time

Findings **3, 5, 7, 8** all trace to the same root: `useFixtures` is
not a *seam*, it's a *fork*. Every repo public method has two bodies;
domain logic (snapshot computation, default-flag promotion, sort-order
renumbering) leaked into the fixture branches because nothing else was
typed strongly enough to hold it; cross-repo coupling
(`LogRepository._foodRepo.get(...)`) was tolerable when both sides
were in-memory but reads as a code smell once the live path is the
real one. The `'food_quick_add'` string lives in five files because
the *canonical* declaration is in a file marked "deletable when API
lands" — deleting it would orphan the four other copies.

The work is mechanical but cross-cutting: move snapshot math to
`LogEntry`, move default-serving rules to `FoodCreate`, lift the
quick-add id to a domain constant, and replace the bool flag with
two concrete subclasses (`InMemoryFoodRepository`,
`InMemoryLogRepository`). The day this lands, deleting `_fixtures.dart`
becomes a `git rm`.

### Theme C: Tests are pinned to constructors instead of intents

Findings **10, 12** name the same problem from two angles. Every test
hand-rolls its own `Food(...)` literal; every test asserts on a
substring of a specific kcal value. The intent of the test
("renders a food row with name + kcal") is not visible from the
assertion; the *fixture* is. This is the Fowler "test the behaviour,
not the implementation" diagnosis exactly. The fix is a
`test/_fixtures.dart` with `buildFood` / `buildServing` / `buildLogEntry`
named-param builders, and a habit of asserting on *invariants*
(`food.servings.first.kcal × quantity`) rather than on values
(`'250'`).

This finding is `P0` because the cost is paid every Ask. Ask 10's
fixture migration cost dozens of mechanical edits across test files
that would have been one file under the builder pattern.

### Theme D: The feature-folder boundary is mostly intact — guard it

Finding **6** is the one cross-feature cycle today (`today/` ↔
`log_entry/`/`quick_add/`). Finding **13** is a minor scope drift
(`editLogEntry` orchestration in `today_internals.dart`). Beyond
those two, the boundaries are honoured: no widget imports a Dio,
no feature reaches across siblings except for the `pathForDay`
import. Lifting `pathForDay` to `routing/routes.dart` and moving
`editLogEntry` to `features/log_entry/` is two small PRs that
makes the cycle and the scope drift both vanish.

The cost of letting it slide is real-but-deferred: the moment
someone tries to extract a feature into a sub-package (or even a
sub-`pubspec.yaml` for desktop-only / mobile-only variants), the
cycle is a blocker.

---

## Out of scope / deferred

- **`@Skip('Quarantined post Ask 10')` test suite (62 files).** The
  audit task explicitly excludes these. They contain real assertion
  patterns worth restoring (the `_RouterCapturingRepository` shape
  in `log_entry_sheet_test.dart:281` is a useful test seam), but the
  un-quarantine itself is a product call, not a code-quality call.
- **`widgets/weight_stepper.dart` / `widgets/height_stepper.dart`
  size (700/660 LoC).** Mentioned in finding 15. They're self-
  contained and not on the hot path for incoming features. The size
  traces to the keyboard-handling + chip-strip + long-press repeater
  combo each owns; pulling those into reusable sub-widgets would be
  a cosmetic improvement but doesn't move velocity.
- **`features/onboarding/`.** 311-line `onboarding_screen.dart` plus
  `step_2_about_you.dart` (345), `step_3_goal.dart` (333). The
  steps are concrete State classes; the flow is linear; the screens
  don't share dependencies with the rest of the app beyond the
  profile-providers. Stable surface — not on the change-frequency
  curve.
- **`features/goals/`, `features/weight/`, `features/profile/`.**
  Each is a normal feature folder with one screen and a few
  widgets. They follow the patterns above and don't show the
  drift signs the log-entry / quick-add sheets do. Re-audit when
  the next major reshape (Ask 11?) lands on one of them.
- **`lib/data/api_client.dart` + auth flow.** Not in scope — the
  audit was framed around domain / repositories / features. The
  auth code is internally consistent (the `LoginController`'s
  five-phase submit is well-segmented) and would benefit from its
  own focused review if/when it changes.
- **`LogPostFn` typedef on `LogOutboxNotifier`** — good design,
  calling it out as a positive: it's the seam pattern the controller
  in finding 1 should mirror.
