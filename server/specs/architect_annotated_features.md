# Architect-Annotated Features

**Read order**: `pm_overnight_features.md` is the feature input; this doc is
the implementation contract layered on top. Where the PM doc says *what*,
this doc says *how* and *whether it fits*. Both docs defer to
`flutter_ui_architecture.md` (the 22 tenants) and `pm_decisions_flutter_ui.md`
(Display Units Principle, outbox scope, removed-from-v1 list) when there's a
genuine conflict.

**Audience**: the program manager who will fan these out into developer
tickets, and the developer agents who will pick the tickets up. Every
"Architectural guidance" line is a load-bearing instruction — if a developer
ignores it, the result will violate a tenant.

---

## A1. Shared widget lift to `lib/widgets/`

**Verdict**: 🔧 APPROVED WITH CHANGES

**Design-language fit**: The lift is the single biggest enforcement act for
T-01 (token discipline), T-09 (one source of truth for numbers), and T-15
(form-factor branches at the screen root). The PM's framing is correct;
what needs work is the *inventory*. The PM listed seven widgets, but the
architecture appendix lists ~30, and several of those are also currently
inlined as feature-private classes (`PrimaryButton`, `IconButton36`,
`EmptyState`, `Skeleton`, `NumberText` — searched, none of these exist as
canonical widgets today). The lift is the right move; the scope needs to
match the appendix, not the PM's seven.

**Architectural guidance**:

- **Canonical list to lift in A1** (matches the appendix exactly; do *not*
  invent siblings):
  - `lib/widgets/calorie_ring.dart` — from
    `features/today/widgets/calorie_ring.dart`. Already form-factor-blind;
    keep the `size` + `strokeWidth` props as-is. The `dangerOver` token
    (not `danger`) is the over-budget color — confirm with B2.
  - `lib/widgets/macro_bar.dart` — from
    `features/today/widgets/macro_bar.dart`. Single source for T-05.
  - `lib/widgets/ring_summary_card.dart` — from
    `features/today/widgets/ring_summary_card.dart`. Keep the
    `compact: bool` prop; B8 will add the `burned` parameter.
  - `lib/widgets/meal_section.dart` — from
    `features/today/widgets/meal_section.dart`. The `_AddFootRow` and
    `_EntryRow` private classes stay private to the file (lifting them
    separately is gold-plating — they have one call site).
  - `lib/widgets/quantity_stepper.dart` — see "Quantity stepper
    reconciliation" below; this is the gnarliest part of A1.
  - `lib/widgets/serving_list.dart` — see "Serving list reconciliation"
    below.
  - `lib/widgets/activity_option.dart` — see "Activity option
    reconciliation" below.
- **Lift in the same pass, low-risk, used in A5/B7**: `lib/widgets/empty_state.dart`,
  `lib/widgets/skeleton.dart`, `lib/widgets/number_text.dart`,
  `lib/widgets/primary_button.dart`, `lib/widgets/icon_button_36.dart`.
  Sources: `features/search/search_screen.dart:479` (`_EmptyState`),
  `features/search/search_screen.dart:428` (`_SkeletonRow`),
  inline `Text` + tabular-figures throughout (extract a `NumberText` per the
  PM-decisions doc's "every numeric leaf knows what unit it's rendering"
  requirement, which lands the a11y suffix in one place per T-20).
- **Re-export discipline**. After A1, every feature folder import that
  reaches into another feature folder for a widget becomes illegal.
  Concretely: a script-checked rule — `grep -rE "features/.*/widgets" lib/features` should match nothing
  after A1, except the three widgets that are intentionally feature-local
  (`features/today/widgets/mini_weight_sparkline.dart`,
  `features/today/widgets/quick_add_chips.dart`,
  `features/search/widgets/search_field.dart` — these are screen-specific
  compositions, not shared vocabulary).
- **Quantity stepper reconciliation**. The two existing implementations have
  meaningfully different APIs:
  - `features/log_entry/widgets/quantity_stepper.dart` is a
    `ConsumerStatefulWidget` that reads a *specific* top-level
    `quantityProvider` (line 7 imports it from
    `log_entry_sheet.dart`). It has no `value` prop — it owns its display
    through Riverpod.
  - `features/custom_food/widgets/quantity_stepper.dart` is a plain
    `StatefulWidget<Decimal?>` with `onChanged`, `value`, `step`, `min`,
    `max`, `unitSuffix`, `placeholder`, `hasError`, `showStepperButtons`,
    `allowDecimal`. Eight props. It does not know about Riverpod.
  - **The lifted widget MUST be the callback-shaped one** (the
    `Decimal? value` + `ValueChanged<Decimal?> onChanged` shape). It is
    strictly more general — the log-entry call site can wrap it with a
    `Consumer` to bind to `quantityProvider`. Forcing every consumer
    (custom-food serving grams, weight-log kg input) to depend on a
    sheet-scoped Riverpod provider is the wrong direction. Per T-15 the
    leaf widget should render the same regardless of who drives state.
  - The log-entry call site becomes a 6-line `Consumer` wrapper inside
    `features/log_entry/widgets/quantity_stepper_binding.dart` (or inline
    in the sheet body — the binding is small enough). The wrapper reads
    `ref.watch(quantityProvider)` and forwards `onChanged` to
    `ref.read(quantityProvider.notifier).state = next`.
  - The `QuickMultiplierChips` widget at `features/log_entry/widgets/quantity_stepper.dart:217`
    is a separate composition with its own provider binding. It is **not**
    lifted to `lib/widgets/` — it is screen-04-specific (the architecture
    appendix doesn't list it as a shared widget, and the canonical
    `QuantityStepper` in the inventory takes `quickMultipliers` as an
    optional prop but does *not* render them inline; the chips row in the
    sheet is a sibling widget). Architect ruling: keep the chips file at
    `features/log_entry/widgets/quick_multiplier_chips.dart`; rename the
    file when the quantity stepper is removed from that folder so the
    naming is clean.
  - **Default step + floor**: lifted widget takes `step` (default
    `Decimal.one` to match the custom-food expectations — log-entry passes
    `Decimal.parse('0.5')` explicitly), `min` nullable (custom-food passes
    `Decimal.zero`; log-entry passes `Decimal.parse('0.5')`). Do not bake
    a `0.5` floor in.
- **Serving list reconciliation**. The PM doc says a single `ServingList`
  with a `selectable: bool` prop. That's the right end-state, but the two
  existing implementations are structurally different — the read-only one
  (`features/food_detail/widgets/serving_list.dart`) renders kcal-per-serving
  on the right, while the editor in
  `features/custom_food/widgets/servings_section.dart` renders editable
  rows with `LabeledField` + `QuantityStepper` + remove buttons.
  Architect ruling: **do not collapse these into a single widget tonight**.
  The PM's "one widget, one prop" is the long-term shape, but unifying
  takes a per-row composition pattern (a `ServingRow` that flips between
  display-mode and edit-mode) that's larger than overnight scope. Instead:
  - Lift the read-only `ServingList` to `lib/widgets/serving_list.dart`
    with `selectable: false` baked into it (no prop yet — the prop lands
    when the editor variant moves in).
  - Add a `selectedId` + `onSelect` pair for screen 04 to use (currently
    screen 04 reuses the food-detail serving list through ad-hoc
    plumbing; verify on the lift).
  - Keep the editor at `features/custom_food/widgets/servings_section.dart`
    for v1. Add a comment at both sites pointing to the lift follow-up
    ticket.
  - **Update the PM doc's acceptance criterion** to reflect this:
    "ServingList has `selectable: bool` *prop slot reserved*; the
    editable variant is held in `custom_food/widgets/servings_section.dart`
    until a future lift collapses them. Both files share the same row
    chrome via a private `_ServingRowChrome` helper extracted in
    `lib/widgets/serving_list.dart`."
- **Activity option reconciliation**. The two files are not
  drop-in-equivalent:
  - `features/onboarding/widgets/activity_option.dart` is the
    architecture-spec shape — `title`, `subtitle`, `selected`, `onTap`.
    Lift this verbatim to `lib/widgets/activity_option.dart`.
  - `features/profile/widgets/activity_level_picker.dart` is the *sheet
    host* — it owns the picker state, the save side-effect, the error
    string, and the per-`ActivityLevel` label/subtitle mapping. Inside
    it, `_ActivityRow` (line 136) is a *visually different* row (radio
    icon on the left, accent-tinted title when selected, larger padding)
    — not the same widget at all. The PM doc framed these as duplicates;
    they are not.
  - **Architect ruling**: lift `ActivityOption` from onboarding. Then
    rewrite `_ActivityRow` in the profile picker to *use* it. The visual
    discrepancy (radio icon vs custom radio dot, label color flip when
    selected) is a design-consistency bug, not an intentional difference
    — pick the onboarding rendering as canonical and update the profile
    picker to match.
- **Naming convention** (pin these now; the program manager should bake
  them into the ticket):
  - Files: `lib/widgets/<snake_case>.dart`, exactly matching the appendix
    table. No `widget_*` prefixes. No barrel files (`widgets.dart` →
    don't ship one; explicit per-widget imports keep the dependency graph
    legible).
  - Imports: callers use `package:fulfilled/widgets/quantity_stepper.dart`,
    not `../../widgets/quantity_stepper.dart`. The package-relative form
    survives feature-folder moves; relative imports do not.
  - One widget per file. The `_ServingRow`, `_KvRow`, etc. private
    classes stay private in the same file.
- **Hex literal sweep**. Per the PM acceptance criterion + T-01: the two
  hex literals at `features/search/widgets/search_result_row.dart:129`
  (`0xFFF5EFE6`) and `:141` (`0xFF8C6B2C`) must be lifted to
  `AppColors.userThumbBg` and `AppColors.userThumbInk` — this is also in
  B2. Bundle the rename into A1 to avoid two passes touching the same
  file. Search the lifted widgets for any other stray `Color(0xFF…)` and
  add tokens for any that survive.

**Risks / gotchas**:

- The `QuantityStepper` API change will fail to compile at the log-entry
  call site if the agent forgets the `Consumer` wrapper. That's the
  loudest possible failure mode (compile error) — which is what we want;
  silent rendering of the wrong widget would be worse.
- The `MealSection` widget reads `colors.emptyDot`, a token defined in
  `AppColors.light`. Lifting the widget out of `features/today/` doesn't
  change the token wiring, but the agent should confirm no other widget
  reads `colors.emptyDot` (T-09 spirit — one tenant for the empty meal
  affordance).
- The current `features/today/widgets/ring_summary_card.dart` uses
  `colors.dangerOver`, not `colors.danger`. The PM acceptance criterion
  for A5 / B2 refers to `AppColors.danger`. These are two distinct
  tokens (both defined in `tokens/colors.dart`). The architect ruling:
  T-05 mandates `dangerOver` for over-budget arc/bar fills (a distinct
  bright-orange-red) and `danger` for the sign-out button and error
  borders. Do not collapse them. Annotate this in T-05 in the
  architecture doc as part of A6's doc-update pass.
- `EmptyState` and `Skeleton` do not exist yet as canonical files. The
  PM A5 acceptance criterion says "from `lib/widgets/skeleton.dart`",
  which implies these are already lifted — they aren't. A1 must create
  them.
- The architect-named `KeyboardShortcuts` widget does *not* exist yet;
  B3 is the one that creates it. Don't pre-create the file in A1 — wait
  for B3 to own the API.

**Test expectations**:

- **Golden tests** for the seven canonical widgets that have visual
  contract: `CalorieRing` (default + over-budget + no-goal),
  `MacroBar` (under/at/over), `RingSummaryCard` (compact + expanded),
  `MealSection` (populated + empty + dense), `QuantityStepper`
  (default + error + no-buttons + with-unit-suffix), `ServingList`
  (with synthetic, with default + synthetic), `ActivityOption`
  (selected + unselected). One golden per case, light theme.
- **Unit tests** for the highlight-spans helper at
  `search_result_row.dart` if it moves (it shouldn't tonight, but the
  test annotation it carries — `highlightSpansForTest` — must continue
  to work).
- **No widget tests** for the lift itself if the existing screen tests
  pass. The lift is a refactor; if the screens still render the same
  data, the lift is done.
- **CI gate** (add as a `dart test` analyzer rule or a simple grep
  script in `tool/lint_no_cross_feature_imports.sh`): no
  `features/.*/widgets` import survives outside its owning feature
  folder. This catches drift the moment it happens.

---

## A2. My Foods screen at `/foods/mine`

**Verdict**: ✅ APPROVED

**Design-language fit**: This is a missing destination, not a new
surface. The screen composes existing components (`SearchResultRow`,
`EmptyState`, plus a `TextField` filter), so the design language is
already determined — the agent's job is to assemble, not to invent.
Fits T-08 (skeleton matches final layout), T-13 (no spinner on a
populated list), T-15 (form-factor branch at the screen root; this
screen has different chrome compact vs expanded — compact shows a
back button + title, expanded sits in the shell with the sidebar
highlighting "My foods").

**Architectural guidance**:

- **File layout**:
  - `lib/features/my_foods/my_foods_screen.dart` — single file is
    fine; the screen is small. Don't pre-create a `widgets/` subfolder.
  - `lib/providers/food_providers.dart` — add
    `myFoodsProvider` as an `AsyncNotifier<List<Food>>` (or a
    `FutureProvider` — match whatever pattern the existing screen
    providers use; `food_providers.dart` already exists). Reads from
    `FoodRepository.listMine()`.
  - `lib/repositories/food_repository.dart` — add `listMine()` that
    filters `_foods` by `source == FoodSource.user` and sorts by a
    `createdAt` field. **Gotcha**: the current `Food` domain type at
    `lib/domain/food.dart` does *not* expose `createdAt` — confirm
    this. If it doesn't, the lift here is small (add the field to the
    seed builder + the type) but the agent must own it as part of A2,
    not punt to a follow-up. Alternative: sort by the seed list order
    if `createdAt` is missing on `Food`; document the temporary sort
    rule in a code comment so the next ticket replaces it.
- **Route registration**: edit `lib/routing/app_router.dart` to swap
  the `PlaceholderScreen` at `Routes.myFoodsName` (line 71) for the
  real `MyFoodsScreen`. Keep the route inside the `ShellRoute` so the
  sidebar nav chrome persists. The route already exists at
  `/foods/mine` — no path changes.
- **Compact reachability**. PM acceptance says compact reaches My
  Foods from a Profile "Data" section row. The existing
  `features/profile/profile_screen.dart` has a Data section; the agent
  adds a `SettingsRow` "My foods · N" routing to `/foods/mine`. The
  count comes from `FoodRepository.customCount()` which already
  exists.
- **In-list filter**. Use a `ValueNotifier<String>` or a local
  `useState`-style hook; do **not** debounce (T-13 spirit — the list
  is fully local and the filter is instant). The filter doesn't go
  through a provider — it's local widget state per T-15 (form-factor
  branch at the root, leaf is trivial).
- **Long-press overflow on compact**. PM says "Edit" routes to
  `/foods/:foodId/edit` which 404s — fine. "Delete" shows a
  destructive `AlertDialog` per T-11 with body "Delete this custom
  food?" and a danger-coloured "Delete" action. The action does
  *nothing* (no mutation) but logs a `debugPrint` so QA can see the
  flow fires — clearly labeled in the code as a v1 stub.
- **Empty state seam**. PM says "temporarily filter the user foods to
  test empty state." Add a `_kEmptyStateDebugFlag` constant at the top
  of the screen file (default `false`) — the agent flips it locally
  to verify the EmptyState renders. Do not ship a runtime toggle.
- **List rendering**: `ListView.builder` with `SearchResultRow` per
  row. PM correctly notes "use the YOU thumb variant" — that's
  automatic if the row reads `food.source` (which is always `user`
  here).

**Risks / gotchas**:

- `Food.createdAt` may not exist (very likely — the fixture is
  hand-built and probably doesn't carry a timestamp). The agent must
  decide: add the field, or sort by seed order. Default to "add the
  field if it's a 2-line change; otherwise sort by seed order with a
  TODO."
- Sidebar nav highlighting reads from `appRouterProvider.location`.
  Confirm `/foods/mine` routes to the "My foods" sidebar item, not
  the "Foods" item. The current sidebar nav config likely uses
  prefix matching — `/foods` and `/foods/mine` would both highlight
  "Foods" with naive matching. The agent must check the highlighting
  predicate and use exact-match for `/foods/mine` (and likewise for
  `/foods/search`, which highlights "Foods" correctly).
- The screen does not need a FAB (T-12) — the empty-state CTA is the
  primary affordance. Do not add a "+ New custom food" FAB.

**Test expectations**:

- **Widget test**: empty state renders correctly with the toggle on;
  filter narrows the list; tapping a row navigates to
  `/foods/:foodId`.
- **Golden test**: the screen at compact + expanded with 3 results
  and the filter cleared.
- **Integration test (light)**: not required tonight.

---

## A3. Missing repository methods (`addServing`, `update`)

**Verdict**: 🔧 APPROVED WITH CHANGES

**Design-language fit**: Pure repository work; design-language
concerns don't apply. Fits T-18 (provider invalidation is explicit
and minimal).

**Architectural guidance**:

- **`FoodRepository.addServing(String foodId, ServingCreate input) → Future<Serving>`**:
  - Locate the food in `_foods`, append a new `Serving` to its
    `servings` list (constructed with a generated id, the input
    grams + name, `isDefault: false`, `source: ServingSource.user`,
    `sortOrder: <max+1>`).
  - **Mutate the food in-place** by reconstructing the `Food` with
    `copyWith(servings: [...old, newServing])`. The static `_foods`
    list is replaced at index. Don't try to mutate the `servings`
    list in place — `Food` is immutable per the domain model.
  - Match the existing `mockLatency()` call shape at the top.
  - Returns the new `Serving`. Throws `FoodNotFoundError` if the
    foodId doesn't resolve (matches `get()`'s shape).
- **`GoalRepository.update(Goal goal) → Future<Goal>`**:
  - Find the goal by id in `_state`. Replace at index with the input
    (preserving `createdAt`, stamping `updatedAt = DateTime.now()`).
  - Throws `GoalNotFoundError` if the id doesn't resolve.
  - **Critical**: the existing `edit_goal_sheet.dart:181` calls
    `repo.create()` which closes out the active goal and starts a
    new one (lines 83-88 in `goal_repository.dart`). The edit flow
    is currently broken — it creates a new goal each time the user
    saves an edit, so the goal history grows by one row per edit.
    PM accurately flagged this. The fix is to swap the call from
    `create()` to `update()` at
    `edit_goal_sheet.dart:181` and pass the existing `widget.active.id`
    through.
- **Provider invalidation**:
  - `addServing` invalidates `foodDetailProvider(foodId)` *only*.
    Do not invalidate the food list providers — adding a serving
    doesn't change which foods match a search.
  - `update` invalidates `activeGoalProvider` + `goalsProvider` +
    `daySummaryProvider(startsOn)` (the day-summary ring depends on
    the kcal target, so it must re-derive — the existing edit sheet
    already invalidates this).
  - Do **not** invalidate `everythingProvider` — that's the T-18
    anti-pattern. There is no `everythingProvider` in the code; this
    is preventive guidance for the agent.
- **Wire the screen 05 "Add serving" button**: the
  `features/custom_food/widgets/servings_section.dart` editor uses
  a draft provider (`customFoodDraftProvider`) — servings are
  accumulated in the draft and POSTed during the custom-food save
  flow (`createCustom`). The `addServing` repository method PM
  describes is the *server-side* endpoint, called after a food
  exists. The current screen 05 design doesn't need it — it bundles
  the servings into the `createCustom` POST.
  - **However**: the architecture doc's screen 05 brief says: "POST
    `/foods` with the basics + nutrition; iterate POSTs to
    `/foods/{id}/servings` for each user-defined serving." That means
    the screen 05 save flow is supposed to call `addServing` per
    serving after the food is created. Today, `createCustom` takes
    a single `FoodCreate` and returns a food with only the
    auto-seeded 100 g serving — the draft's user-defined servings
    are silently dropped at the repository seam. This is a separate
    silent-correctness bug from the one PM flagged.
  - **Architect ruling**: A3 must fix *both*: (a) implement
    `addServing` per PM, and (b) update the `CustomFoodScreen` save
    flow to iterate `addServing` over `draft.userServings` after
    `createCustom` returns. This is one more wire-through than PM
    described but it's the same agent, same file, same testing
    surface — and it eliminates the data-loss bug that's the actual
    reason PM noticed the missing method.
- **Optimistic updates**: not for v1, per PM. The
  `await mockLatency()` + state mutation pattern is fine.

**Refinements**:

- The PM A3 acceptance criterion "Screen 05's 'Add serving' button
  ... wires through to `addServing`" is incorrect as stated — the
  Add serving button is the draft-side `_addServing` at
  `servings_section.dart:30`, which appends to the draft, not to the
  server. It doesn't call the repository at all. The PM's underlying
  intent (custom servings are actually persisted after save) is
  right; the wiring location is the `CustomFoodScreen` save handler,
  not the button. Reframe the criterion as: "After Save, every
  draft serving is persisted via `addServing`; the resulting food
  detail page shows the user-defined servings alongside the
  auto-seeded 100 g."

**Risks / gotchas**:

- `Goal.copyWith` may not yet accept all fields needed for `update`
  (e.g. it may not include `updatedAt`). Check at
  `lib/domain/goal.dart`.
- `Serving.copyWith` similarly — the new serving needs a `source`
  enum value that's user-source, not system-source (the auto-seeded
  100 g is `ServingSource.system`).
- The serving's `sortOrder` should be `max(existing) + 1` so the new
  serving sorts at the bottom. Don't default to 0 (would put it at
  the top above the synthetic 100 g, which violates T-10's "synthetic
  100 g is always visible" semantic — though not the letter; T-10
  says nothing about sort position).

**Test expectations**:

- **Repository unit tests**:
  - `addServing` returns a serving with a fresh id; calling twice
    appends two; food's `servings.length` grows by 1 per call.
  - `addServing` throws `FoodNotFoundError` on unknown id.
  - `update` mutates in place; goal list length does not grow.
  - `update` throws `GoalNotFoundError` on unknown id.
- **Widget test for the edit flow**: edit the rate, save, verify
  the goal history list does not gain a row.
- **Widget test for custom-food save**: create a custom food with 2
  user servings, save, navigate to the detail page, verify both
  servings render.

---

## A4. `calories_estimate.dart` lift to `lib/domain/calories/`

**Verdict**: 🔧 APPROVED WITH CHANGES

**Design-language fit**: T-17 (Decimal in, formatted out) directly
applies. The current file uses `double` internally
(`_bmr` line 144 takes `double weightKg`, `double heightCm`). PM says
"all math uses `package:decimal`" — that's an upgrade, not a copy.

**Architectural guidance**:

- **File location**: `lib/domain/calories/estimate.dart` per the
  appendix and the existing file's own lift checklist (lines 9-17 of
  the current file).
- **Public API** (lift verbatim, then refactor):
  - `class CalorieEstimate { ... }` — already a value type, lifts
    as-is.
  - `int ageInYears(DateTime birthDate, DateTime today)` — lifts as-is.
  - `CalorieEstimate? estimateCalories({...})` — lifts; refactor
    internals to use `Decimal` per PM.
  - New: `int estimateDailyTarget(Profile profile, GoalInput input)`
    or similar — PM's A4 acceptance criterion references this
    shape. **Architect ruling**: the existing `estimateCalories`
    returns a `CalorieEstimate` whose `dailyTargetKcal` is the
    daily target. A new top-level function isn't needed — the goals
    editor consumes `estimateCalories(...).dailyTargetKcal`. Add a
    convenience wrapper `int estimateDailyTarget(...)` that calls
    `estimateCalories` and returns the int (returning `int` for the
    target matches the existing wire shape).
- **Refactor: double → Decimal**:
  - `_bmr` becomes `Decimal _bmr({required Sex, required Decimal weightKg, required Decimal heightCm, required int ageYears})`.
  - Multiplier table: `Map<ActivityLevel, Decimal>` (parse from
    strings to preserve exact values — `1.375` and `1.725` round-trip
    in IEEE-754 but the principle is to keep the math entirely in
    `Decimal` for the architecture-mandated rounding behavior).
  - `_kKcalPerKgPerWeek` becomes `Decimal.parse('7700.0')`.
- **Rounding: half-to-even**:
  - The existing file uses `_roundHalfUp` (line 130). PM acceptance
    says **half-to-even** (banker's rounding) to match server. The
    file docstring explicitly says "half-up" today but flags the
    drift (lines 60-65). Architect ruling: PM wins. Replace
    `_roundHalfUp` with a `_roundHalfToEven` that uses
    `Decimal.round(scale: 0, rounding: RoundingMode.bankers)` — confirm
    the `decimal` package exposes this mode; if not, hand-roll: if the
    fractional part is exactly 0.5, round to even.
  - **Behavioral note**: this changes outputs at .5 boundaries. The
    existing onboarding tests (if any) that pin a specific kcal
    output may need a one-time update. Bundle the test update with
    A4.
- **Goals editor consumes the same function**: replace the inline
  helpers at `edit_goal_sheet.dart:219-271`
  (`_baselineKcalFromGoal`, `_derivedKcalTarget`, `_round10`,
  `_signedRate`, `_macroGrams`) with calls into the lifted file.
  - The current goals editor uses a *baseline-from-goal* approach
    (extracts the baseline TDEE from the current goal by reversing
    the rate adjustment), not the Mifflin-St Jeor pipeline. This is
    a fundamentally different formula than onboarding.
  - **Architect ruling**: the goals editor should fetch the user's
    `Profile` from `meProvider` and use the same `estimateCalories`
    function. The "baseline from goal" trick (line 221) is a hack
    that exists because the editor didn't have access to the
    profile.
  - This is more scope than PM described for A4. **Architect
    ruling**: ship A4 with the lift + onboarding rewire + half-to-even
    rounding tonight. The goals-editor rewire is a follow-up ticket
    — it's not strictly *missing* functionality; the editor works
    today, just with a different formula. Add a `TODO(arch)` in
    `edit_goal_sheet.dart` pointing at the lifted file with a
    one-line note.
  - **PM update**: refine A4's "No copy of the math remains in
    `features/goals/`" — that statement is aspirational, not
    achievable in one ticket without a `meProvider` rewire. Replace
    with "The lifted `estimateCalories` is the seam; the goals
    editor's `_baselineKcalFromGoal` helper carries a `TODO(arch)`
    comment pointing at it. Rewire is a follow-up."
- **Unit test file**: PM acceptance specifies four cases. Add a
  fifth: round-trip a `Profile` + `GoalInput` through
  `estimateCalories` and assert the result is a deterministic int
  (no flakiness from clock — tests pass `now: DateTime(2026, 5, 16)`).

**Refinements**:

- PM A4 says "The function signature does not change between use
  sites; both onboarding and goals pass the same shape." — true in
  spirit (both consume the same function), but the goals editor needs
  a `Profile` to do so, which it doesn't currently have. Reframe as
  "The function lives in one file; the goals editor's reuse lands in
  a follow-up ticket once it has profile access."

**Risks / gotchas**:

- The half-to-even rounding change may shift the kcal target by 1 in
  some test cases. This is the intended fix for the rounding drift
  PM described; the agent should expect to update one or two
  pinned-output tests.
- The `decimal` package's `RoundingMode.bankers` may or may not exist
  by that name — confirm in the docs. If not, the manual
  implementation is ~10 lines.
- The current implementation uses `(value.toStringAsFixed(...))` in
  the slider (`edit_goal_sheet.dart:177`) — that's unrelated to A4
  but the agent shouldn't touch it.

**Test expectations**:

- **Unit tests** at `test/domain/calories/estimate_test.dart`:
  - Male sedentary maintain @ 80 kg 180 cm 30y → known kcal
  - Female active deficit @ 60 kg 165 cm 28y rate 0.5 → known kcal
  - Edge case: rate at slider max (1.0 kg/wk) with a 1200 floor
  - Half-to-even @ .5 boundary: deliberately constructed input
    where the raw result is integer.5 (verify ends in an even
    digit).
  - Onboarding round-trip: same `Profile` + `GoalInput` two ways
    (call `estimateCalories` directly vs through the onboarding
    wiring) produces the same int.
- No widget tests needed.

---

## A5. Empty / error / loading state coherence sweep

**Verdict**: 🔧 APPROVED WITH CHANGES

**Design-language fit**: A5 is *the* tenant-enforcement ticket. It
touches T-08 (skeletons match final layout), T-11 (errors are inline,
not modal — actually, errors are SnackBar; modals are reserved for
destructive confirms), T-13 (no spinner on a populated list), T-20
(every visible state has a usable Semantics label). The PM has the
scope right; what needs work is the *order* relative to A1 and the
audit checklist.

**Architectural guidance**:

- **Dependency on A1**: hard. A5 consumes the lifted `Skeleton`,
  `EmptyState`, `NumberText`, `IconButton36`. Do not run A5 in
  parallel with A1 — the agent will end up touching the same files
  twice. Sequence: A1 lands first, then A5 picks up.
- **Audit table** the agent must produce (and the program manager
  should turn into the acceptance checklist):

  | Screen | Loading | Empty | Error | Populated refresh |
  |---|---|---|---|---|
  | 01 Day view | `TodaySkeleton` (custom; OK) | per-meal "0 kcal" header (T-10 exception, keep) | SnackBar + retry-CTA EmptyState | RefreshIndicator (mobile) / 2-px web bar |
  | 01-W Day expanded | `TodaySkeleton` (same) | n/a (always populated rhythm) | SnackBar + retry-CTA | 2-px web bar |
  | 02 Search | `_ResultsSkeleton` → lift to `Skeleton` | `_EmptyState` → lift to `EmptyState` | SnackBar + EmptyState | 2-px web bar |
  | 03 Food detail | `CircularProgressIndicator` (line 308) → **violation, fix** | n/a (route fails to resolve) | SnackBar + EmptyState | n/a |
  | 04 Log entry sheet | `CircularProgressIndicator` (line 658) → **violation, fix** | n/a | inline error per T-11 | n/a |
  | 05 Custom food | `_ButtonSkeleton` (line 428) → keep, but lift | n/a (form) | inline per-field T-11 | n/a |
  | 06 Weight log | `_Skeleton` (line 211) → lift | EmptyState with "Log your first weight" CTA | SnackBar + EmptyState | RefreshIndicator |
  | 07 Goals | (no current loading branch — verify) | EmptyState with "Set a goal" | SnackBar + EmptyState | n/a |
  | 08 Profile | `CircularProgressIndicator` (line 410) → **violation, fix** | n/a | inline | n/a |
  | 09 Onboarding | n/a (form) | n/a | inline per-field | n/a |

  The four "violation, fix" rows are the agent's primary work. The
  rest is verification + the lifts.
- **Today's empty-meal exception**: PM correctly carves out the
  deliberate exception (meal sections render their header at 0 kcal,
  not an `EmptyState`). The current code already does this
  (`meal_section.dart:67`). Add a comment to the lifted
  `MealSection` (now at `lib/widgets/meal_section.dart`) explicitly
  saying "Per architect §9 and A5 audit, an empty meal renders the
  header at 0 kcal with `emptyDot` color — it does **not** delegate
  to `EmptyState`. This is the only screen-level state widget that
  deliberately bypasses `EmptyState`." A code-archaeology paper trail
  saves the next agent from a "why doesn't this use EmptyState?" PR.
- **Error → SnackBar wiring**: every screen's `AsyncValue.when(error: ...)`
  branch currently renders something different (inline string in
  some, no branch in others). A5 standardizes: every error branch
  renders an `EmptyState` with a retry CTA *and* shows a `SnackBar`
  on transition into the error state (via a `ref.listen` in the
  consumer). Two channels, one signal — SnackBar gets attention,
  EmptyState gets persistence.
- **No raw "Loading…" / "Error" text**: PM acceptance — grep the
  codebase for these literal strings and convert.
- **Pending-sync badge (T-22)**: PM mentions verifying it works. The
  current outbox is at `lib/data/outbox/log_outbox_notifier.dart`;
  the badge is rendered in the today day-view at the entry row. The
  agent visually verifies during A5; does not redesign.

**Refinements**:

- Add to PM acceptance: "Every screen's `AsyncValue.when` has all
  three branches present (`data`, `loading`, `error`). A `null`
  branch falling through to a default `Container()` is a violation;
  rendering an empty `Sliver*` is a violation."

**Risks / gotchas**:

- The Today screen's `TodaySkeleton` is bespoke (matches the ring +
  meal cards rhythm). Don't replace it with a generic `Skeleton`
  composition — the bespoke skeleton is what T-08 mandates ("matches
  final layout"). Leave it as `TodaySkeleton` in
  `features/today/today_internals.dart` and just verify it conforms.
- The PM A5 acceptance criterion 3 says "throttle the mock provider
  to 800 ms and visually inspect each screen" — that's a manual QA
  step, not a code change. The agent shouldn't add a throttle
  toggle; they should temporarily bump `mockLatency()` for the
  visual inspection and revert.
- B9 (Quick-add empty state) is a subset of A5. The PM split it out
  because the Quick-add card has specific copy. Don't double-ship —
  A5 either covers it (preferred) or explicitly punts to B9. The
  agent should claim B9 as part of A5 if there's overnight runway.

**Test expectations**:

- **Widget tests**: for each of the four "violation, fix" screens
  (03, 04, 08, plus the search empty state lift), a widget test that
  pumps the screen with a throttled mock and asserts the correct
  skeleton type is rendered (no `CircularProgressIndicator`).
- **Golden test**: one golden per screen's empty + error state
  (compact only — empty/error rendering is form-factor-blind per
  T-15).
- **Semantic test**: every EmptyState has a `Semantics` label with
  title + body. Asserted via a `find.bySemanticsLabel`.

---

## A6. PM rulings on §10 items 2, 9, 10

**Verdict**: ✅ APPROVED

**Design-language fit**: This is a doc + rendering update; tenant
fit is direct. Items 2 (T-10), 9 (T-17 + the existing
`decimal_format.dart` + the units utilities), and 10 (T-21
adjacent) are all under-specified rules getting their final shape.

**Architectural guidance**:

- **Item 2 (synthetic visibility)** — no code change needed; the
  current `ServingList` at `food_detail/widgets/serving_list.dart`
  already renders the synthetic badge unconditionally. Action:
  delete any `// TODO: confirm synthetic visibility` comments (grep
  the codebase; none found in my pass, but the agent verifies).
  Update §10 item 2 in `flutter_ui_architecture.md` to RESOLVED.
- **Item 9 (decimal precision)** — encode in
  `lib/domain/decimal_format.dart` (or split across the
  `lib/domain/units/` files, which is the existing pattern —
  `energy.dart` for kcal, `weight.dart` for kg, etc.). The PM
  acceptance gives the full table; treat it as the contract.
  - **Architect addition to PM acceptance**:
    - `formatKcal(Decimal)` already exists in `domain/units/energy.dart`.
      Verify it rounds half-to-even (currently may not). Bundle the
      half-to-even fix with A4 (same rounding rule applies; one
      helper).
    - `formatGrams(Decimal)` per the macro rule — integer at ≥ 10,
      one decimal at < 10. This is a new helper; add it to
      `domain/units/macros.dart`.
    - `formatSodiumMg(Decimal)` already exists per the PM decisions
      doc. Verify.
    - `formatKg(Decimal)` already exists at
      `domain/units/weight.dart`. Verify one-decimal-always.
    - `formatQuantity(Decimal)` — new helper for the stepper. Up to
      two fraction digits while typing, one on commit. This is a
      *display* rule; the underlying `Decimal` keeps its full
      precision (T-17). The lifted `QuantityStepper` already
      handles trailing-zero trimming (`_format` helper); the
      commit-rounding lands in the parent's `onChanged` handler.
    - `formatRate(Decimal)` — new helper for goal editor; two
      fraction digits always.
  - **Quality score**: not displayed. See item 10.
- **Item 10 (quality score copy)** — code change at
  `food_detail/food_detail_screen.dart` (or wherever the
  `qualityScore` is rendered). The current `food_detail_hero.dart`
  is the most likely location; grep for `qualityScore` to confirm.
  Replace the format string `'OFF data · quality 0.86'` with a
  source-only label:
  - `food.source == FoodSource.off` → `'OFF data'`
  - `food.source == FoodSource.usda` → `'USDA data'`
  - `food.source == FoodSource.user` → `'Your food'`
  - Add a code comment: "Quality score hidden in v1 per PM ruling
    §10 item 10. Score remains on the DTO for future sorting /
    debug surfaces. v2 ranking ticket: TBD."

**Risks / gotchas**:

- The decimal-format helpers may already partially exist. The agent
  must inventory before adding new ones — duplicating `formatKcal`
  in two places (one in `domain/units/energy.dart`, one in
  `domain/decimal_format.dart`) is a T-09 violation in spirit
  (consistency across calls).
- The half-to-even rounding intersection with A4: same agent
  preferred. If different agents pick A4 and A6, they must
  coordinate on the rounding helper location — one canonical
  function, used by both.

**Test expectations**:

- **Unit tests** for each new formatter. Edge cases per the PM
  table: 9.4 g → "9.4 g", 10.5 g → "11 g" (half-to-even: round to
  even → 10? no, 10.5 → 10 under banker's), 10.4 g → "10 g", 99.5
  g → "100 g". Sodium: 245 mg → "245 mg". Weight: 78.4 → "78.4
  kg", 82.0 → "82.0 kg".
- **Widget test** for the food-detail source label: three foods
  (OFF / USDA / user), assert the rendered label matches.
- **Doc check**: the `flutter_ui_architecture.md` §10 has items 2,
  9, 10 moved to RESOLVED with the same format as items 1/5/6/8/11/12.

---

## B1. Inter font bundling

**Verdict**: ✅ APPROVED

**Design-language fit**: T-02 (tabular figures) is wasted as long as
the app renders in Helvetica / Roboto / Segoe — tabular figures only
exist in Inter's OpenType tables. Every typography token in §2.2
(letter-spacing, weight 600 hero, eyebrow `+0.10em`) is calibrated
for Inter. This is a no-brainer.

**Architectural guidance**:

- **Files**: `assets/fonts/Inter/Inter-Regular.ttf`,
  `Inter-Medium.ttf`, `Inter-SemiBold.ttf`, `Inter-Bold.ttf`. Source
  from rsms/inter v4.0 or later (OFL).
- **pubspec.yaml**: uncomment the existing block at lines 59-69.
  The structure is already declared correctly; the agent just
  populates and uncomments.
- **License attribution**: add `assets/fonts/Inter/OFL.txt` (ships
  with the Inter release). Update `LICENSES.md` at repo root (or
  create it if missing — single new file, fine).
- **FOUT prevention on web**: Flutter web's `FontLoader` is the
  standard pattern; CanvasKit (architecture §1) handles font
  loading at app init. Add a `preloadFonts()` call early in
  `main.dart` if FOUT manifests; otherwise the default should work.
- **Verification**: the agent runs the app on web + one mobile
  target and visually confirms Inter renders (vs the platform
  default). Tabular figures are visible on the day-view ring's
  center number — best verification spot.

**Risks / gotchas**:

- The 4 `.ttf` files add ~700 KB to the bundle. Acceptable; document
  in the commit message.
- If a future ticket adds variable-font support (Inter ships as a
  variable font too), this lift can collapse to a single file. Not
  for tonight.
- The current pubspec block is exactly the architecture-spec shape;
  do not alter the keys.

**Test expectations**:

- **Manual visual verification** on web + mobile. No automated
  test — golden tests already pin Inter (when they run on a host
  that has the file), so the lift either passes the existing
  goldens or breaks them.
- **Build verification**: `flutter build web` and `flutter build apk`
  both succeed.

---

## B2. Light theme polish pass

**Verdict**: ✅ APPROVED

**Design-language fit**: Direct T-01 enforcement. The PM has the
scope right and the acceptance criteria are concrete.

**Architectural guidance**:

- **Sequence**: depends on A1. The lifted widgets are the canonical
  enforcement targets. A B2 agent running before A1 would have to
  fix the same hex literal twice in two different files.
- **Token additions** (the agent ships the PR with these in
  `tokens/colors.dart`):
  - `userThumbBg: Color(0xFFF5EFE6)`
  - `userThumbInk: Color(0xFF8C6B2C)`
  - Source: `search_result_row.dart:129, 141` (the two known hex
    literals).
- **Audit script**: grep `lib/` for `Color(0x` outside `tokens/`.
  The agent fixes every hit. Currently expected hits: two in
  `search_result_row.dart` (lifted in A1), one in
  `custom_food/widgets/quantity_stepper.dart:158` (`Color(0xFFFFF8F3)`
  — the error background). The latter is a token candidate:
  `dangerSoftAlt` or merge with `dangerSoft` (`#FBEBE2`). Architect
  ruling: use the existing `dangerSoft` token and let the agent
  visually verify the slight pink-vs-cream difference isn't
  load-bearing.
- **Border + divider sweep**: every `Border.all` and `Divider` is
  checked. Most already conform; the audit is mechanical.
- **Hover background**: B5 owns this — don't double-implement. B2
  enforces the token; B5 enforces the *application* of the token to
  hoverable surfaces.
- **T-03 conflict on Search Frequents**: the PM acceptance criterion
  says the chip dots use `ink3`. The current
  `features/search/widgets/quick_chip_row.dart` (if it has chip
  dots) — agent verifies. Resolve any mock-side macro-color usage
  on a chip dot to `ink3`.

**Test expectations**:

- **Golden tests** for any widget whose visual changes (likely
  none — most B2 changes are imperceptible).
- **Lint check**: `tool/lint_no_hex_outside_tokens.sh` (one-line
  grep wrapped) added as a CI gate. Same script as A1's
  no-cross-feature-imports check.

---

## B3. Web keyboard shortcuts

**Verdict**: 🔧 APPROVED WITH CHANGES

**Design-language fit**: §7 commits to the keyboard model. The
shortcuts are spec'd; B3 is the wiring ticket. Fits the desktop user
story.

**Architectural guidance**:

- **File**: `lib/widgets/keyboard_shortcuts.dart` (matches
  appendix). Wraps the shell's `child` only when
  `FormFactor.of(context).isExpanded`. On compact + medium it
  returns the child unchanged.
- **Wiring location**: `app_router.dart`'s `ShellRoute` builder.
  Replace `AppScaffold(child: child)` with
  `KeyboardShortcuts(child: AppScaffold(child: child))` — but
  *only* if the form factor reads correctly inside the
  `ShellRoute` builder context. If `FormFactor.of(context)` isn't
  available there (it's an InheritedWidget — depends on where
  `AppScaffold` provides it), the agent restructures.
- **Shortcut map** (per architecture §7):
  - `/` → focus search input (or push `/foods/search` if not on
    a screen with a search field). Use `Shortcuts(...)` +
    `Actions(...)`.
  - `⌘K` / `Ctrl-K` → push `/foods/search` as a dialog overlay.
    Decision: ship as a plain push to `/foods/search` for v1 — the
    "command palette dialog overlay" is a v2 polish; ⌘K opening the
    full search route satisfies the user story. **PM refinement**:
    update B3 acceptance to say "⌘K pushes `/foods/search`; the
    centered dialog overlay variant is v2."
  - `n` → opens the log-entry dialog with the most recent food
    preselected. If no recents, push `/foods/search`. The dialog
    on expanded is the `showLogEntrySheet` shape (already exists at
    `features/log_entry/log_entry_sheet.dart`).
  - `g t/f/w/o` → two-key sequence. Use a stateful `KeyDownEvent`
    listener with a 1-second timeout. There's no built-in Flutter
    primitive for two-key sequences in `Shortcuts`; hand-roll a
    small `_TwoKeyMatcher` class.
  - `Esc` → `Navigator.maybePop`. Already works for `AlertDialog`
    by default; need explicit wiring for the bottom sheet and the
    search palette.
  - `↑` / `↓` on lists — defer to v2. The list-keyboard navigation
    is more scope than B3 should carry tonight. **PM refinement**:
    update B3 acceptance to drop the `↑` / `↓` requirement; ship the
    navigation shortcuts only.
- **`TextField` carve-out**: don't bind `/`, `n`, `g _` inside a
  focused `TextField`. Use `Shortcuts(includeSemantics: false)` and
  check `Focus.of(context).hasPrimaryFocus` — or wrap the shortcuts
  in a `CallbackShortcuts` that checks
  `FocusManager.instance.primaryFocus?.context?.widget is EditableText`.
- **Profile preferences "Keyboard" section** — defer to v2. PM
  acceptance asks for a three-column table; ship the shortcuts
  without the documentation surface tonight. **PM refinement**:
  update B3 acceptance to drop the in-app docs requirement.

**Refinements**:

- B3's "↑ / ↓ on rows" + "Keyboard" docs section in profile + ⌘K
  as a centered command palette are three pieces of scope that
  blow the overnight budget. Strip them; keep the
  global-navigation shortcuts + ⌘K-as-route-push + Esc-closes-modal.

**Risks / gotchas**:

- The two-key `g _` matcher needs a state timeout. If the agent
  uses a `Timer`, dispose it on widget unmount.
- Flutter web `Shortcuts` widget can intercept browser shortcuts;
  ⌘K is a browser-level shortcut on some browsers (Safari focuses
  the URL bar with ⌘L, not ⌘K — should be safe). Verify ⌘K
  doesn't fight the browser.
- `Esc` already closes `AlertDialog` and `Dialog` by default. Do
  not double-bind it.

**Test expectations**:

- **Widget tests**: a `keyboardShortcuts_test.dart` that sends
  `LogicalKeyboardKey.slash`, `LogicalKeyboardKey.keyN`, the `g t`
  sequence, and `LogicalKeyboardKey.escape`, asserting the
  expected route/state change.
- **No golden tests** — keyboard shortcuts have no visual surface.

---

## B4. Animations and transitions

**Verdict**: 🔧 APPROVED WITH CHANGES

**Design-language fit**: Motion is exactly the polish the PM
identifies it as. The constraints (T-02 keeps numbers stable, T-05
color flip not a hard swap, no elevation on hover per §7) are all
upheld in PM acceptance. Fits cleanly.

**Architectural guidance**:

- **Sequence**: depends on A1. The animations live inside the
  canonical widgets.
- **`CalorieRing` arc tween**: implement via
  `TweenAnimationBuilder<double>` wrapping the `progress` value.
  The painter already reads `progress`; the tween just animates the
  input. 400 ms, `Curves.easeOutCubic`. Center number does *not*
  animate (T-02).
- **Over-budget color cross-fade**: 150 ms via `AnimatedSwitcher`
  on the arc color, or simpler: `TweenAnimationBuilder<Color?>` if
  `Color.lerp` between accent and dangerOver is acceptable
  (visually it should be; the two are different hues so the
  midpoint is a brief muddy color — verify).
- **FAB press / hover**: existing widget at
  `features/today/widgets/log_food_fab.dart` (likely; verify path).
  Add `AnimatedScale` (0.95, 100 ms) on press;
  `AnimatedContainer` background tint on hover (web-only —
  use `MouseRegion` + a `bool _hovered`). No elevation change.
- **`LogEntrySheet` slide / fade**: bottom sheet's default
  Material animation is fine on compact/medium; expanded uses
  `Dialog` whose `transitionBuilder` can be overridden in
  `showDialog` to do 200 ms fade + 8-px translate. Wrap the
  `Dialog` child with a `TweenAnimationBuilder<double>` driving
  opacity + `Transform.translate`.
- **Route transitions**: slide on compact, fade on expanded.
  `go_router` exposes `pageBuilder` per route; use
  `CustomTransitionPage` with `FadeTransition` at expanded width.
  Detect form factor in the page builder via the same breakpoint
  helper (which doesn't have a context — agent will need to
  compute from `MediaQuery` directly or thread the form factor
  into the router state). Architect ruling: do this for the
  three high-traffic routes only (`/today`, `/foods`, `/me`);
  leave defaults for the others.
- **`MacroBar` fill**: same 400 ms cubic. Already a `Container` with
  a width-via-Fractionally widget — animate the width via
  `TweenAnimationBuilder<double>`.
- **Reduced-motion**: `MediaQuery.disableAnimations` — wrap every
  duration in a helper:
  ```dart
  Duration motion(BuildContext context, Duration full) =>
    MediaQuery.disableAnimationsOf(context) ? Duration.zero : full;
  ```
  Put in `lib/widgets/motion.dart` for reuse. **Architect addition**:
  if disabled, animations collapse to zero; this is a one-helper
  refactor across every animated leaf.

**Refinements**:

- Animating the over-budget color cross-fade may look muddy at the
  midpoint (accent teal #1F5F5B → dangerOver). Architect ruling: if
  the midpoint is visibly bad, ship a hard 0→1 fade via
  `AnimatedSwitcher` instead of a Color.lerp. Decision lives with
  the agent at implementation time.

**Risks / gotchas**:

- Route transitions on `go_router` interact with the `ShellRoute` —
  inner-shell transitions can flicker the chrome if the agent
  isn't careful. Test resizing while transitioning.
- The `CalorieRing` painter rebuilds on every tween tick — fine
  for 400 ms but verify no jank with throttled CPU.

**Test expectations**:

- **Widget test for reduced-motion**: pump with
  `disableAnimations: true` and assert tween durations are zero
  (or that the value snaps to the target on the first frame).
- **No golden tests** — animations don't have a single golden frame.

---

## B5. Web hover states audit

**Verdict**: ✅ APPROVED

**Design-language fit**: §7 commits to the hover rule; B5 is the
enforcement pass. Fits T-04 (accent never used for hover) and the
no-elevation rule.

**Architectural guidance**:

- **Sequence**: depends on A1 (the canonical widgets are the
  enforcement target) and overlaps with B2 (token discipline). One
  agent can do both B2 and B5 in a single sweep.
- **Helper widget**: introduce `lib/widgets/hoverable.dart` —
  wraps a child with `MouseRegion(cursor: SystemMouseCursors.click)`
  + an `AnimatedContainer` background that interpolates to
  `colors.line2` over 80 ms on hover. Every interactive surface
  uses it; the API is `Hoverable({required Widget child, BorderRadius? radius})`.
  - Touch-primary devices skip the `MouseRegion` — Flutter handles
    this automatically (`MouseRegion` is a no-op without a pointer).
- **Audit checklist** (from PM, with one addition):
  - `FoodRow`, `SearchResultRow`, `SettingsRow`, `ServingList`
    row, `GoalHistoryList` row, `WeightHistoryList` row,
    `IconButton36`, date-bar chevrons, segmented control
    segments, `QuickChipRow` chips, `MealChipPicker` cells,
    `ActivityOption`, `GoalOption`.
  - Architect addition: `_AddFootRow` inside `MealSection` ("Add
    food" footer) is a hoverable surface that PM's list omits.
- **Cursor**: `SystemMouseCursors.click` on rows;
  `SystemMouseCursors.text` on `TextField`s; default elsewhere. The
  `Hoverable` helper sets click; `TextField`s already manage their
  cursor.

**Risks / gotchas**:

- The hover background interpolates to `line2` (`#EFEEE9`) which
  is barely visible on `surface` (`#FFFFFF`). Confirm the
  contrast is intentional — it's subtle by design; B5 is not the
  ticket to question it.
- On touchscreen-only Chrome (iPad Safari w/ trackpad), the hover
  behavior is desirable. Don't disable hover on web-mobile based
  on viewport size; rely on pointer kind only.

**Test expectations**:

- **Widget tests**: pump with `gestures: TestPointerType.mouse`,
  hover over a row, assert the rendered background color is the
  hover color (or that the `Hoverable._isHovered` state is true).
- **Manual visual verification** on a desktop browser.

---

## B6. Sign-out wiring with auth-token notifier

**Verdict**: ✅ APPROVED

**Design-language fit**: T-11 (modals reserved for destructive
confirmation) directly applies. T-18 (provider invalidation is
explicit and minimal — but here we deliberately invalidate
*everything user-scoped* because the user is changing).

**Architectural guidance**:

- **Sequence**: depends on A5 (signed-out state lands on empty
  screens; those need to be coherent first).
- **Notifier shape**:
  ```dart
  class AuthTokenNotifier extends Notifier<String?> {
    @override
    String? build() => _readSeed();

    Future<void> signOut() async { ... }
    void setToken(String token) { state = token; ... }
  }

  final authTokenProvider = NotifierProvider<AuthTokenNotifier, String?>(...);
  ```
- **`signOut()` behavior**:
  1. Clear `state = null`.
  2. Clear the Hive boxes: `outbox_log`, `recent_foods`,
     `frequent_foods`, `food_detail`, `active_goal`, `weights`,
     `profile`. The agent confirms each box exists (some may be
     stubs; clear what exists, skip what doesn't).
  3. Invalidate the provider tree by reading the providers that
     touch user data and calling `ref.invalidate` on each. List
     them explicitly — don't loop over a `families` map.
  4. Push `/onboarding/1` via the router (not `pop` to it —
     `pushReplacement` so back-button doesn't return to a
     signed-in screen).
- **Sign-out row**: at
  `features/profile/profile_screen.dart` (the existing button
  currently calls a TODO at line 226). Wire to `signOut()` after
  the destructive `AlertDialog` confirmation per T-11. Dialog
  shape: title "Sign out?", body "You'll need to set up again to
  use Fulfilled.", primary "Sign out" in `colors.danger`, cancel
  as secondary.
- **Token persistence**: store the dev token in a Hive box
  `auth_token` keyed by string. On app start, `AuthTokenNotifier`
  reads from the box before falling back to the dart-define seed.
- **`DEV_AUTH_BYPASS` interaction**: the dev server bypasses auth
  unconditionally — so the user can sign out, hit onboarding,
  complete it, and arrive back at Today. On onboarding completion,
  `setToken(_kDevBypassToken)` is called.

**Risks / gotchas**:

- Hive box names — the architecture §5 cache table lists the
  domains; the actual box names in `lib/data/outbox/` and
  `lib/repositories/` may differ. The agent inventories before
  clearing.
- The `Notifier` migration changes the type from `Provider<String?>`
  to `NotifierProvider<AuthTokenNotifier, String?>`. Every call site
  that reads `ref.read(authTokenProvider)` continues to work
  (returns `String?`); call sites that try to write the provider
  (none today) would break.
- The `ApiClient` reads the token via `ref.read(authTokenProvider)`
  in an interceptor — confirm the interceptor re-reads on every
  request, not just at construction time. If it caches, the agent
  must add a re-read or a `ref.listen` shim.

**Test expectations**:

- **Widget test**: tap Sign out → dialog → confirm → assert the
  router is at `/onboarding/1` and the Hive boxes are empty.
- **Unit test for the notifier**: `signOut()` clears state and
  returns `null` on next read.

---

## B7. Accessibility audit (Semantics + T-20)

**Verdict**: ✅ APPROVED

**Design-language fit**: T-20 is the tenant; B7 is the
enforcement pass. PM acceptance covers the rules well.

**Architectural guidance**:

- **Sequence**: depends on A1 + A5. The semantics labels live on
  the canonical widgets; A5's empty/error states need their
  Semantics labels too.
- **`NumberText` enforcement**: the lifted `NumberText`
  (created in A1) takes a `unit` prop. Every numeric `Text` in
  the codebase migrates to it. Grep:
  `grep -rE "Text\(formatKcal|formatGrams|formatKg|formatSodiumMg"`
  — every hit is a `NumberText` candidate.
- **`IconButton36` tooltips**: every instance carries a
  non-null `tooltip` after this pass. The widget can take it as
  a required prop in the lift (A1) — if so, B7 just fixes the
  call sites the compiler flags.
- **Composed row labels**: every row widget has a single
  composed Semantics label. The pattern:
  ```dart
  Semantics(
    label: '${food.name}, ${serving.name}, ${formatKcal(kcal)} kilocalories',
    child: ...,
  )
  ```
  — at the row root, *not* on every leaf. Excludes children from
  semantics tree so screen readers read one composed phrase per
  row.
- **Over-budget suffix**: `MacroBar` adds " (over by N g)" to
  its Semantics label when `value > target`. T-20 enforcement.
- **Tab order check**: spot-check log-entry dialog (screen 04) and
  custom-food form (screen 05) — both have multiple inputs. Tab
  order should follow visual order (left-to-right, top-to-bottom).
  Flutter default is usually correct; if not, the agent uses
  `FocusTraversalOrder` widgets.

**Risks / gotchas**:

- Composed Semantics labels and per-leaf labels conflict — the
  parent's label is read, but the leaves are still children. Use
  `Semantics(container: true, label: ..., child: ExcludeSemantics(child: ...))`
  to suppress children where appropriate.
- The `ink3` color is a tertiary-text color; verify no body text
  is rendered in it. The placeholder text in `QuantityStepper`
  (`features/custom_food/widgets/quantity_stepper.dart:194`) uses
  `ink3` — that's a placeholder, which is acceptable per PM.
- Color-contrast verification is *manual* — the agent uses a
  Chrome DevTools or similar tool, not an automated test.

**Test expectations**:

- **Widget tests with `find.bySemanticsLabel`**: one per row
  widget, asserting the composed label includes the rendered
  number + unit.
- **No golden tests** — semantics don't show.
- **Manual screen-reader spot-check**: not required to ship; flag
  for QA.

---

## B8. Activity / calories-burned provider (Today "Burned" row)

**Verdict**: ✅ APPROVED

**Design-language fit**: Fits T-09 (one source of truth — the
`burned` value is derived from profile + active goal, not a
separate fetch). Fits T-21 (kcal display unit).

**Architectural guidance**:

- **Sequence**: depends on A4 (the TDEE math lives there).
- **Provider location**: `lib/providers/log_providers.dart`
  (alongside `daySummaryProvider`) or a new
  `lib/providers/activity_providers.dart`. Architect ruling: new
  file is cleaner — the "burned" derivation isn't a log concern.
- **Provider shape**:
  ```dart
  final caloriesBurnedProvider =
    Provider.family<AsyncValue<Decimal>, DateTime>((ref, date) {
      // Read meProvider + activeGoalProvider
      // Compute TDEE - BMR via estimateCalories
      // Add ±5% per-day variance seeded by date.day
      // Return as Decimal
    });
  ```
- **Variance seeding**: `Random(date.year * 10000 + date.month * 100 + date.day)`
  for deterministic same-day output. The variance is multiplicative
  on `tdee - bmr`.
- **Consumer**: the ring summary card (`ring_summary_card.dart`
  `_KvRow(label: 'Burned', value: '—')` at line 151) reads the
  provider and replaces `'—'` with `formatKcal(burned)`. On compact
  the row is added too (currently the compact view doesn't show
  Burned — verify; if not, add it).
- **Net / Remaining**: the calculation in the day-view already
  uses `goal - consumed`. After B8, the "Net" derivation (if it
  exists; verify) becomes `goal - consumed + burned`. The PM
  framing is correct.

**Risks / gotchas**:

- Without an active goal or profile, the provider returns
  `AsyncValue.loading()` or `AsyncValue.error()` (depending on
  upstream). The consumer must handle both — fall back to `'—'`
  rendering on error/loading. T-08 (skeleton when loading) doesn't
  apply to a single number row; a `'—'` placeholder is acceptable.
- The "burned" value never goes negative; clamp at zero in the
  provider in case TDEE somehow drops below BMR (shouldn't, but
  belt-and-braces).

**Test expectations**:

- **Unit test** for the provider: given a fixed profile + goal +
  date, returns a deterministic value within the ±5% band of
  `tdee - bmr`.
- **Widget test**: the ring summary card's "Burned" row renders a
  number when the provider resolves, `'—'` when loading.

---

## B9. Quick-add empty state on Today expanded right rail

**Verdict**: ✅ APPROVED

**Design-language fit**: This is one of A5's missing screens (the
empty quick-add card on a brand-new user). PM correctly split it
out for the specific copy + CTA. Fits T-08.

**Architectural guidance**:

- **Sequence**: depends on A5 (consumes the lifted `EmptyState`).
  If A5 covers this case, B9 collapses into A5. Otherwise:
- **Location**: `features/today/widgets/quick_add_chips.dart`
  (the existing widget; verify). The widget reads
  `recentFoodsProvider` and `frequentFoodsProvider`; the empty
  branch renders `EmptyState`.
- **Empty-state shape**: icon (search-shaped, ideally
  `Icons.search`), title "No recents yet", body "Log your first
  food and it'll show up here.", action `PrimaryButton('Find a food')`
  routing to `/foods`.
- **Partial empty**: if recents present but frequents not (or
  vice versa), render only the section that has data — don't
  show a section header above a blank row.
- **Card height consistency**: the right rail's three cards
  should share a min-height to preserve vertical rhythm. The
  ring summary card sets the rhythm; the empty quick-add card
  should match or exceed it. Use
  `ConstrainedBox(constraints: BoxConstraints(minHeight: ringHeight))`
  in the card wrapper.

**Risks / gotchas**:

- The card-height min-constraint can produce ugly visual padding
  when the empty state is shorter than the ring card. Center the
  empty state in the available space.
- If A5 covers B9, the program manager should not assign B9 as a
  separate ticket — flag for combination.

**Test expectations**:

- **Widget test**: both providers empty → EmptyState renders.
  Recents empty, frequents populated → only frequents section
  renders.
- **Golden test**: the expanded right rail with the empty
  quick-add card.

---

## B10. Desktop "paste a barcode" affordance

**Verdict**: ✅ APPROVED

**Design-language fit**: Resolves §10 item 3. Fits T-06 (touch
target — the affordance row is a tappable surface) and the desktop
keyboard-first user story.

**Architectural guidance**:

- **Sequence**: independent of other features. Can run in parallel
  with anything.
- **Placeholder copy**: `features/search/widgets/search_field.dart`
  (likely path; verify). Branch on `FormFactor.isExpanded` and
  swap "Search foods or scan barcode…" for "Search foods or paste
  a barcode…". On compact, the original placeholder stays.
- **Affordance rendering**: below the search input, on
  `FormFactor.isExpanded` only, render a single row when input
  matches `^\d{8,14}$`:
  - Layout: small row, `ink2` text "Look up barcode {value} →",
    accent-tinted on hover (B5).
  - Tap or Enter → `context.push('/foods/barcode/$value')`.
- **Regex**: `RegExp(r'^\d{8,14}$')` — exact constraint per PM.
  Watch for leading-zero barcode validity (EAN-8 starts with 0
  often; the regex accepts).
- **Existing barcode route**: `/foods/barcode/:barcode` is
  registered as a `PlaceholderScreen` at
  `app_router.dart:121`. The agent replaces with a real
  resolver that calls `FoodRepository.byBarcode(barcode)` and
  pushes `/foods/:foodId` on success or `/foods/new?barcode=...`
  on 404 (which is the architecture §6 flow). The
  `byBarcode` method already exists at
  `food_repository.dart:135`.
- **Routes** add: `/foods/new?barcode=:barcode` query parameter
  consumed by `CustomFoodScreen` to prefill the barcode field.
  Check if the existing screen accepts the query param — if not,
  small addition.

**Risks / gotchas**:

- The regex `^\d{8,14}$` includes 9, 11, 13-digit barcodes (most
  UPC-A is 12, EAN-13 is 13, EAN-8 is 8). The actual barcode
  resolution happens server-side; the regex is a UI gate to
  surface the affordance, not a validation. Looser is fine.
- On the barcode-resolve route's 404 path, the
  `/foods/new?barcode=...` redirect should *replace* in history
  (not push), so the user's back button returns to wherever they
  typed.
- The current `BarcodeScanButton` at
  `features/search/widgets/barcode_scan_button.dart` returns
  `SizedBox.shrink` on web (per architecture §7). Verify B10
  doesn't accidentally show the button on web.

**Test expectations**:

- **Widget tests**: type 8 digits → affordance visible; type 7
  digits → affordance hidden; type 9 letters → affordance hidden;
  type 12 digits + Enter → router navigates to
  `/foods/barcode/{value}`.
- **Barcode-resolve route widget test**: mock the repository,
  assert the success path pushes `/foods/:foodId` and the 404
  path replaces with `/foods/new?barcode=...`.

---

## Cross-cutting concerns

### 1. Lift sequencing

A1 is the load-bearing predecessor for almost everything. Run A1 in
its own isolated pass before any other Tier-A or Tier-B feature
that touches a lifted widget. The strict dependencies are:

- A1 blocks: A2 (uses `EmptyState`, `SearchResultRow`),
  A5 (uses `Skeleton`, `EmptyState`, `NumberText`),
  B2 (canonical token enforcement), B4 (animation hooks live in
  lifted widgets), B5 (hover targets are canonical widgets), B7
  (`NumberText` + `IconButton36` are the audit's main subjects),
  B9 (consumes `EmptyState`).
- A3 + A4 + A6 + B1 + B3 + B10 do **not** depend on A1. They can
  run in parallel with the lift.

### 2. Naming conventions for lifted widgets

Pin these now in the A1 ticket:

- Files: `lib/widgets/<snake_case>.dart`. One widget per file
  (private helpers in the same file are fine).
- Imports across features: `package:fulfilled/widgets/X.dart`,
  never relative.
- No barrel file (`widgets.dart`). Explicit per-widget imports.
- The seven names from the A1 inventory match the architecture
  appendix exactly: `calorie_ring.dart`, `macro_bar.dart`,
  `ring_summary_card.dart`, `meal_section.dart`,
  `quantity_stepper.dart`, `serving_list.dart`,
  `activity_option.dart`.
- The five additional widgets created in A1: `empty_state.dart`,
  `skeleton.dart`, `number_text.dart`, `primary_button.dart`,
  `icon_button_36.dart`.

### 3. Tenant refinements surfaced by the review

- **T-05 clarification**: the over-budget arc/bar uses
  `colors.dangerOver` (a brighter orange-red), not `colors.danger`
  (the muted red used for sign-out + error borders). The current
  PM doc text uses `AppColors.danger` ambiguously; the
  architecture doc should be amended in A5/A6 to disambiguate.
- **T-22 clarification**: the pending-sync badge wording in §6
  uses both `AppColors.ink3` and `colors.ink3` interchangeably;
  the lifted widget uses `colors.ink3`. Cosmetic; no change.
- **Proposed T-23**: see "Tenant updates" below.

### 4. Bundling small features

The PM should bundle as follows for ticket efficiency:

- **"Polish" batch ticket** (single agent, one PR): A6 (§10
  rulings) + B1 (Inter fonts) + B6 (sign-out wiring). All small,
  none depend on each other after A5 lands.
- **"Hover + theme" batch ticket** (single agent, single sweep):
  B2 + B5. Same files, same audit pattern.
- **"Day view burned + B9"** if A5 doesn't cover B9: one agent
  takes B8 + B9 since both touch the day-view right rail.
- **Keep separate**: A1 (size + risk), A5 (size + breadth), B3
  (specialized keyboard knowledge), B4 (motion polish — separate
  reviewer interest), A2 (the only new screen — different review
  surface).

### 5. Audit / lint scripts to add tonight

The lift gets cheaper to maintain if we ship lint scripts with it:

- `tool/lint_no_hex_outside_tokens.sh`: grep for `Color(0x` in
  `lib/` excluding `lib/theme/tokens/`. Should return zero hits
  after A1 + B2.
- `tool/lint_no_cross_feature_widget_import.sh`: grep
  `features/.*/widgets/` imports in files outside their owning
  feature. Should return zero hits after A1.

Both are 2-line bash scripts; the program manager can fold them
into the A1 ticket as an acceptance addendum.

---

## Sequencing recommendation

Total: 16 features, ~3 large, ~10 small/medium. Generous overnight.

**Wave 0** (in parallel, no dependencies — start immediately):
- A1 (LARGE, the lift)
- A3 (SMALL, repository methods)
- A4 (SMALL, calories lift)
- A6 (SMALL, §10 rulings)
- B1 (SMALL, Inter fonts)
- B3 (MEDIUM, keyboard shortcuts)
- B10 (MEDIUM, paste-a-barcode)

**Wave 1** (start when A1 merges):
- A2 (MEDIUM, My Foods screen)
- A5 (LARGE, state coherence sweep)
- B2 + B5 bundled (MEDIUM, theme + hover audit)
- B4 (MEDIUM, animations)
- B8 (SMALL, burned provider — A4 must also be in)
- B9 (SMALL, quick-add empty — may collapse into A5)

**Wave 2** (start when A5 merges):
- B6 (MEDIUM, sign-out wiring)
- B7 (MEDIUM, accessibility audit)

**Critical-path estimate**: A1 → A5 → B6 / B7. If A1 takes ~3 hours
and A5 takes ~3 hours, the critical path is ~7 hours plus parallel
wave 0 + wave 1 features. Comfortable overnight budget.

**Parallelism risk**: A5 and B7 both want to touch every screen.
Run them serially — A5 first (functional correctness), B7 second
(accessibility annotation). Don't race two agents on the same
screen files.

---

## Tenant updates

Proposing **T-23** as a new tenant for the architecture doc, based
on review of the existing screen code:

> **T-23 Shared widgets are package-imported.** Every widget that
> appears in the §3 component inventory lives at
> `lib/widgets/<name>.dart` and is imported by call sites via
> `package:fulfilled/widgets/<name>.dart`. Feature folders may not
> import widgets from sibling feature folders. A feature-private
> widget that the inventory does not list stays inside that
> feature's `widgets/` directory and is private to the feature.

Rationale: the duplicates the PM flagged (`quantity_stepper`,
`activity_option`, `serving_list` shapes) happened because no rule
forbade cross-feature imports. T-23 turns the convention into a
reviewable rule. The lint script in cross-cutting concern §5
enforces it.

Also propose a one-line **refinement to T-05**:

> **T-05 (refined)**: Over-budget macro fill uses
> `colors.dangerOver`. Sign-out + per-field error borders use
> `colors.danger`. The two tokens are distinct and not
> interchangeable.

No other tenant changes. The 22-tenant system is otherwise
well-formed and the PM doc's framing fits within it.

---

## Closing note

The PM's overnight scope is well-chosen — it's the right balance
of "consistency floor" (A1, A5, A6, B2, B5, B7) and "missing
destinations" (A2, B6) and "polish" (B1, B4, B10) and "real bugs"
(A3, A4, B8). The refinements above are mostly about *implementation
shape*, not about *what to ship*. The two places where I pushed
back hardest — the quantity-stepper API direction (callback shape,
not Riverpod shape) and the serving-list lift scope (keep the
editor in custom_food for v1) — are both about not letting the lift
become an architectural change masquerading as a refactor.

Ship A1 carefully. Everything else flows from it.
