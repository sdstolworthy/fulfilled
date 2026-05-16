# Architect — QoL Audit Pack

Implementation contract for `specs/pm_qol_audit.md`. The PM has ruled
scope, direction, and user stories on the 18 QL items and named three
cross-cutting patterns (A: post-mutation navigation; B: unit-preference
seam generalization; C: invalidation declarations) plus a fourth they
explicitly punted (D: `SheetScaffold`). This doc translates that into
file-level seams, function signatures, provider shapes, tenant
candidates, and acceptance criteria the technical program manager can
carve into developer tickets without re-asking.

The three prior contracts win where they disagree with this one:
`specs/flutter_ui_architecture.md` (the 23 tenants, especially T-15
form-factor-at-root, T-18 minimal invalidation, T-21 customer-expected
units, T-23 lifted-widget package imports),
`specs/architect_log_edit_and_units.md` (the just-shipped weight-unit
seam — Feature B there is the template Feature 1 here mirrors), and
`specs/pm_qol_audit.md` (the QL-001–QL-018 prioritisation and the
"refactors before patches" mandate). Where this doc names a behaviour
and any prior doc disagrees, the prior doc wins.

I read every file PM inventoried across §2.1 (QL-001), §2.2 (QL-002),
§3 (QL-003–QL-018), and §4 (the cross-cutting patterns), plus the
weight-unit code that shipped from `architect_log_edit_and_units.md` —
specifically `client/lib/domain/units/weight.dart`,
`client/lib/domain/locale_defaults.dart`,
`client/lib/providers/profile_providers.dart`,
`client/lib/widgets/weight_stepper.dart`, and the
`weight_unit_chooser.dart` profile feature widget. The plan compiles
in my head; I expect the dev tickets that come out of this to compile
on an agent's machine without surprise. Two open questions for the
PMgr live in §10; one of them (whether `userPreferencesProvider`
should be a single record or per-axis providers) is the only call
that *meaningfully* changes the file diff for the height work, so I
make it directly in §3 and flag it for confirmation in §10.

---

## 1. Architectural overview

**Pattern A — unified post-mutation navigation.** **Accepted.**
Codified as a tenant candidate T-24 (see §8) with exactly three cases:
*pop-to-source*, *route-to-effect*, and *pop-with-payload*. The rule is
documentation + a per-sheet code comment, **not** a `SaveFlowRouter`
class — the architect's call. Every existing sheet already implements
one of the three cases correctly except `LogEntrySheet` (which today
pops when it should route-to-effect for `consumed_on`'s day-view). The
PM correctly named QL-002 as the only behavioural change; QL-003 is
the documentation pass that surrounds it. The rule prevents the next
sheet (a hypothetical "log from photo" or "import meal plan") from
re-litigating the question. T-24 is enforced by review, not lint —
the cases overlap with PM-blessed UX intuition more than they map to
a grep-able pattern.

**Pattern B — unit-preference seam generalization.** **Accepted, with
a directional call: stay per-axis.** PM is opinionated for unification
(`userPreferencesProvider` returns a `UserPreferences` record); I rule
**against** it for this pack, with a single-paragraph justification in
§2.1. The short version: the existing `weightUnitProvider` already
reads from `meProvider` and falls back to a locale default through
`localeDefaultWeightUnitProvider`. That shape is a recipe — adding a
`heightUnitProvider` sibling **costs ~12 lines of identical code** and
keeps the test seam ergonomics (per-axis overrides) we already have.
The actual duplication PM warned about lives in
`defaultWeightUnitForLocale` → `defaultHeightUnitForLocale`, not in the
provider shape. I generalize *that* (one function returning a record)
and leave the providers as thin per-axis derivations. The PM doc said
"the architect can choose" and named the unification preference as
opinion; this is the architect choosing the choose-able way.

**Pattern C — declarative provider-invalidation docs.** **Accepted as
a documentation pass.** Each repository mutator (`LogRepository.create`,
`.update`, `WeightRepository.create`, `ProfileRepository.update`,
`GoalRepository.create`, `.update`, `.markActive`, `FoodRepository
.create`, `.update`, `.addServing`) gets a dartdoc `///` block listing
the dependent providers under an `@invalidates` doc-tag convention
(§4). No code change, no provider registry, no event bus. Call sites
continue to invalidate explicitly per T-18 — the comment is the
contract; the call site is the implementation. One PR, mechanical,
zero behavioural risk.

**Pattern D — `SheetScaffold` refactor.** **Punted to v1.1, with one
exception cherry-picked forward.** PM said "architect's discretion;
this is the kind of refactor that pays off after the fifth sheet, not
before." We have six sheets but they are not yet diverging in chrome
in a way that pays back the refactor cost; the QL-012 close-button
audit is real but localised (one `SheetCloseButton` in `lib/widgets/`
solves it) and ships in the QL-012 ticket without dragging in the rest
of the chrome. The cherry-pick is `SheetCloseButton` only. The rest of
the `SheetScaffold` body — header eyebrow + footer skeleton + grabber
— waits for v1.1, when (a) edit-mode and create-mode footers diverge
further, or (b) a seventh sheet lands. Either trigger justifies the
lift; today neither does.

**Sequencing.** PM recommended QL-003 + QL-004 before QL-001 client
work doubles the duplication, with QL-002 bundled into QL-003. I
**confirm that sequencing** with a small tightening: QL-002 lands
*with* QL-003 (it's the only QL-002-behaviour change the audit names
and T-24's first instantiation), and QL-004 lands as the
`defaultUnitsForLocale` refactor + the new `heightUnitProvider` sibling
*before* QL-001's widget sweep. QL-001 backend is independent —
agent can ship the migration in parallel with QL-002/003/004 since the
client tolerates a missing field by defaulting to `cm` (same shape as
the weight-unit pre-backend window — §4.2 of the prior architect doc).
The PM's order of operations is:

1. PR 1 — QL-002 + QL-003 (LogEntrySheet `context.go` swap, T-24 added,
   per-screen brief comments).
2. PR 2 — QL-004 (`defaultUnitsForLocale`, `heightUnitProvider`,
   Pattern C documentation pass).
3. PR 3 — QL-001 backend Rust migration (architect doesn't write this;
   noted for the user).
4. PR 4 — QL-001 client (length seam, `HeightStepper`,
   `HeightUnitChooser`, sweep of the inventoried sites).
5. PR 5..N — QL-005 through QL-018, pulled in priority order; many are
   single-line.

Total ~5 PRs (the QL-005..018 group will split across two or three
agent passes but the architecture is fixed up-front).

---

## 2. Refactor 1 — Unit-preference seam generalization (QL-004)

### 2.1 The unification question — answered

**Decision: keep per-axis providers (`weightUnitProvider`,
`heightUnitProvider`, future `energyUnitProvider`). Do NOT introduce a
unified `userPreferencesProvider` returning a `UserPreferences`
record.**

Three reasons, ranked:

1. **The cost PM was worried about doesn't materialise.** PM said "the
   third time (kJ for energy, or a hypothetical "force date format")
   this pattern repeats, the seam is the bug." Looking at the actual
   shape that shipped — `localeDefaultWeightUnitProvider` (3 lines) +
   `weightUnitProvider` (7 lines, watches `meProvider` and falls back
   to the locale default) — adding height is two more providers of
   the same 3 + 7 line shape, with one shared `localeDefaultsProvider`
   (see §2.3) feeding both. Total marginal duplication: ~10 lines per
   axis, all of which are the *good* kind of duplication — the
   per-axis shape is the test seam (a unit test that overrides only
   `heightUnitProvider` without also stubbing out
   `weightUnitProvider`).
2. **A record breaks the existing rebuild granularity.** Today the
   weight sparkline rebuilds when `weightUnitProvider` changes; the
   profile screen rebuilds when `weightUnitProvider` changes. If both
   read from one `userPreferencesProvider.select((p) =>
   p.weightUnit)`, the same surface holds — but only if every reader
   threads `.select(...)` carefully. A junior dev writing
   `ref.watch(userPreferencesProvider)` will rebuild on every
   preference change. Per-axis providers make the right thing the
   easy thing; the unified shape makes the wrong thing the easy
   thing.
3. **The migration from "weight-only" to "weight + height" is
   additive against the per-axis shape.** No existing
   `ref.watch(weightUnitProvider)` site moves. The PM's "if you pick
   unification: lay out the migration (…thin derived
   `Provider<WeightUnit>` reading from the record, no caller
   changes)" is do-able but the *thin derived* layer is the only
   thing the call sites benefit from — i.e., the per-axis shape is
   what the call sites already want, and unifying-then-re-deriving is
   ceremony without payoff.

**What I *am* unifying.** The locale default chain. Today's
`defaultWeightUnitForLocale({String? countryCodeOverride})` becomes
the public function `defaultUnitsForLocale({String? countryCodeOverride})`
returning a `UnitDefaults` record:

```dart
typedef UnitDefaults = ({WeightUnit weight, HeightUnit height});

/// All locale-derived display defaults in one pass. Replaces the
/// per-axis `defaultWeightUnitForLocale` (which becomes a thin
/// wrapper for one release, then deleted in a follow-up).
///
/// One country-code chain, one switch statement, two outputs. The
/// per-axis wrappers exist so existing call sites compile during the
/// migration; new call sites read the record directly.
///
/// Fallback chain (PM doc §2.1 + the existing weight chain):
///   - US, LR, MM         → (weight: lb, height: ftIn)
///   - GB + IM/JE/GG      → (weight: st, height: ftIn)
///   - else / null / ''   → (weight: kg, height: cm)
UnitDefaults defaultUnitsForLocale({String? countryCodeOverride});
```

Two existing per-axis wrappers stay for one release, both deprecated:

```dart
@Deprecated('Use defaultUnitsForLocale().weight.')
WeightUnit defaultWeightUnitForLocale({String? countryCodeOverride}) =>
    defaultUnitsForLocale(countryCodeOverride: countryCodeOverride).weight;

WeightUnit _legacyWeightDefault({String? countryCodeOverride}) =>
    defaultUnitsForLocale(countryCodeOverride: countryCodeOverride).weight;
```

The wrapper is `@Deprecated` so the compiler nudges sites toward the
record. The sweep in PR 2 migrates the two existing call sites
(`profile_providers.dart`'s `localeDefaultWeightUnitProvider` and
`draft_providers.dart`'s `onboardingWeightUnitProvider`) to read
through the record. After PR 2 lands, the wrapper has zero live call
sites and a follow-up PR deletes it.

A `HeightUnit` enum gets its own short-form fallback function for
symmetry — but it's wired through the record, not duplicated:

```dart
@Deprecated('Use defaultUnitsForLocale().height.')
HeightUnit defaultHeightUnitForLocale({String? countryCodeOverride}) =>
    defaultUnitsForLocale(countryCodeOverride: countryCodeOverride).height;
```

The `@Deprecated` annotation discourages new use; the wrapper exists
so the height-feature ticket can be written without the migration
landing first. Same pattern, one release of overlap, then deleted.

### 2.2 The country-code carve-out — height vs weight

PM ruled the height chain explicitly in §2.1: US/LR/MM/GB → `ft_in`,
else `cm`. The weight chain has US/LR/MM → `lb`, GB+IM/JE/GG → `st`,
else `kg`. The two chains agree on the metric-edge countries but
diverge on:

- **GB**: weight is `st` (PM-blessed, conversational stones), height
  is `ft_in` (PM §2.1, conversational five-nine).
- **IM/JE/GG**: weight is `st`. Height: PM doc only names `GB` for
  the imperial-height bias. The Crown Dependencies aren't explicitly
  called out for height. **Architect call: include them in the
  `ft_in` bucket** for symmetry with the weight chain. UK Crown
  Dependencies share UK conventions on this; the carve-out is
  consistent across the two axes. If a Jersey user wants `cm` they
  flip the chooser (same as the GB user who wants `cm`).

So the joined chain:

```
countryCode in {US, LR, MM}           → (weight: lb, height: ftIn)
countryCode in {GB, IM, JE, GG}       → (weight: st, height: ftIn)
else (incl. null / empty)             → (weight: kg, height: cm)
```

### 2.3 The shared locale defaults provider

`lib/providers/profile_providers.dart` gains a single
`localeDefaultsProvider` that wraps the record, and the two per-axis
providers derive from it:

```dart
/// Locale-derived defaults for **all** display-unit axes in one
/// place. Wraps [defaultUnitsForLocale] so tests can override the
/// fallback for both axes without spinning up a Flutter binding.
///
/// Override this in [ProviderContainer] tests to assert the
/// loading / error fallback path of [weightUnitProvider] /
/// [heightUnitProvider] / `onboardingWeightUnitProvider` /
/// `onboardingHeightUnitProvider`.
final localeDefaultsProvider = Provider<UnitDefaults>((ref) {
  return defaultUnitsForLocale();
});

/// Deprecated alias kept for one release of source-compat. Existing
/// call sites that `ref.watch(localeDefaultWeightUnitProvider)`
/// migrate to `ref.watch(localeDefaultsProvider).weight`.
@Deprecated('Read localeDefaultsProvider.weight.')
final localeDefaultWeightUnitProvider = Provider<WeightUnit>(
  (ref) => ref.watch(localeDefaultsProvider).weight,
);

/// Active weight unit. Reads from cached `me.weightUnit`; falls back
/// to the locale default while `meProvider` loads or errors.
final weightUnitProvider = Provider<WeightUnit>((ref) {
  return ref.watch(meProvider).maybeWhen(
        data: (u) => u.weightUnit,
        orElse: () => ref.watch(localeDefaultsProvider).weight,
      );
});

/// Active height unit. Mirror of [weightUnitProvider].
final heightUnitProvider = Provider<HeightUnit>((ref) {
  return ref.watch(meProvider).maybeWhen(
        data: (u) => u.heightUnit,
        orElse: () => ref.watch(localeDefaultsProvider).height,
      );
});
```

Onboarding gains a sibling in `lib/providers/draft_providers.dart`:

```dart
/// Active **height** unit during onboarding. Mirror of
/// [onboardingWeightUnitProvider]. Reads the draft's chosen unit if
/// set, else the locale default. The chosen value lands on
/// `UserPatch.heightUnit` at final submit.
final onboardingHeightUnitProvider = Provider<HeightUnit>((ref) {
  final draft = ref.watch(onboardingDraftProvider);
  return draft.heightUnit ?? ref.watch(localeDefaultsProvider).height;
});
```

The onboarding draft (`lib/domain/drafts.dart`) gains a
`HeightUnit? heightUnit` field next to the existing
`WeightUnit? weightUnit` and a `setHeightUnit(HeightUnit v)` notifier
method (sibling of `setWeightUnit`). Mechanical mirror.

### 2.4 Files Refactor 1 touches

```
client/lib/domain/enums.dart                              (+ HeightUnit enum)
client/lib/domain/locale_defaults.dart                    (+ UnitDefaults, defaultUnitsForLocale; @Deprecated wrappers)
client/lib/domain/user.dart                               (+ heightUnit field, fromJson tolerant, toJson always emits)
client/lib/domain/drafts.dart                             (+ heightUnit field on the onboarding draft)
client/lib/providers/profile_providers.dart               (+ localeDefaultsProvider, + heightUnitProvider; @Deprecated localeDefaultWeightUnitProvider)
client/lib/providers/draft_providers.dart                 (+ setHeightUnit, + onboardingHeightUnitProvider)
client/lib/repositories/profile_repository.dart           (UserPatch.heightUnit passes through)
```

7 files. Pure scaffolding for QL-001's later widget sweep — no widget
changes in this PR. The PM correctly identified that this is the
"shipped seam that QL-001 consumes from day one."

### 2.5 Acceptance criteria — Refactor 1

- `UnitDefaults` record exists with `({WeightUnit weight, HeightUnit
  height})` fields.
- `defaultUnitsForLocale({String? countryCodeOverride})` exists in
  `client/lib/domain/locale_defaults.dart` and returns the
  `UnitDefaults` record per the chain in §2.2.
- `defaultWeightUnitForLocale` is annotated `@Deprecated` and reads
  through `defaultUnitsForLocale(...).weight`. Behaviour identical to
  today.
- `defaultHeightUnitForLocale` exists, is annotated `@Deprecated`,
  reads through `defaultUnitsForLocale(...).height`. The deprecation
  is so the height-feature ticket (QL-001 client) migrates straight
  to the record reader without leaving a third caller behind.
- `localeDefaultsProvider` is a `Provider<UnitDefaults>`.
- `localeDefaultWeightUnitProvider` is annotated `@Deprecated` and
  reads `ref.watch(localeDefaultsProvider).weight`.
- `heightUnitProvider` exists, mirrors `weightUnitProvider`, reads
  `meProvider`'s `heightUnit` with fallback to
  `localeDefaultsProvider.height`.
- `User.heightUnit` field exists; `User.fromJson` tolerates missing
  `height_unit` (defaults to `HeightUnit.cm`); `User.toJson` always
  emits.
- `UserPatch.heightUnit` exists; `toJson` emits only when set.
- `OnboardingDraft.heightUnit` field exists; `setHeightUnit` setter
  exists; `onboardingHeightUnitProvider` reads draft + locale
  fallback.
- `ProfileRepository.update` passes `UserPatch.heightUnit` through
  the same way it passes `weightUnit`.
- Tests cover: locale defaults for all carve-outs (US/LR/MM/GB/IM/JE/GG/null/'X');
  `heightUnitProvider` fallback when `meProvider` is loading;
  `heightUnitProvider` reading from `meProvider` when ready;
  `onboardingHeightUnitProvider` reading from draft when set;
  `User.fromJson` defaults to `cm` when `height_unit` is absent.

---

## 3. Refactor 2 — Post-mutation navigation rule (QL-003)

### 3.1 The three cases — codified

After mutation, the user lands where they expect to consume the
mutation's effect. Concretely, every sheet/dialog/screen save handler
follows **exactly one** of these three patterns:

#### Case 1 — Pop-to-source (`Navigator.pop`)

The sheet/dialog exists *only* to collect input and return a result.
The caller decides what to do with it. The mutator has no "natural
home" the user wants to see — the user wants to return to where they
launched the editor from.

**Example screens.**
- `HeightStepperSheet` (Profile → Height). User launched from `/me`;
  return to `/me`. The repo write happens inside the sheet; the user
  sees the updated `Height` row on the screen they were already on.
- `CurrentWeightSheet` (Profile → Current weight). Same shape.
- `SexPicker`, `BirthDatePicker`, `ActivityLevelPicker` (Profile editors).
- `WeightUnitChooser` (Profile → Preferences → Units). Same shape.
- `LogWeightSheet` (Weight tab → Log weight FAB). The sheet pops; the
  chart updates beneath. PM explicitly named this as correct today
  (QL-002 § "Scope of the rule").

**Implementation rule.** `Navigator.of(context).pop(result)` —
the result is the new value (or `null` on dismiss). The caller may
`ref.invalidate(meProvider)` etc. *inside* the save handler before
popping; the navigation itself is unconditional.

#### Case 2 — Route-to-effect (`context.go`)

The mutation has a "natural home" — a route the user wants to see
the *effect* of the mutation rendered on. Pop is wrong because the
source view isn't where the user wants to look at the result.

**Example screens.**
- `LogEntrySheet` save (create and edit) → `/today` or
  `/today/:date`. The user logged food; they want to see it in the
  ring on Today, not stare at the food-detail page they tapped from.
  This is QL-002.
- Future: a hypothetical "import meal from photo" flow → same target
  (`/today/:date`). The mutation's natural home is the day view.
- Future: a hypothetical "duplicate yesterday's log to today" bulk
  action → same target.

**Implementation rule.** `context.go(targetPath)` — not `push`.
`push` stacks frames and the system-back walks the user backwards
through their own log flow; `go` replaces the stack to the natural
home. The sheet's own route disappears as a side effect of `go`'s
stack replacement on compact, and on expanded (where the sheet is a
`showDialog`-not-route) the sheet body must call
`Navigator.of(context).pop()` **before** `context.go(...)` so the
dialog frame doesn't orphan against the new page. Order matters; see
§4.2 in Feature 2 for the exact sequence.

#### Case 3 — Pop-with-payload (`Navigator.pop(value)`)

The mutator is a screen, not a sheet, and the source view (the
screen one frame back in the stack) wants the result to drive its
next render. The natural home is *the screen that opened the
editor*, but it needs to know what changed.

**Example screens.**
- `CustomFoodScreen(existing: food)` → pop with the updated food.
  The food-detail page that opened the editor re-renders against the
  new data. (`CustomFoodScreen` is the edit path; the create path is
  Case 1 — pop with the new food's id so the search-empty-state
  caller can route to the food's detail page if it chooses.)
- A hypothetical "rename a custom serving" sub-editor → pop with the
  renamed serving record.
- A hypothetical "edit a goal target" sub-editor that doesn't write
  through itself → pop with the new target, parent saves.

**Implementation rule.** `Navigator.of(context).pop<Result>(value)`.
The caller awaits the pop result and acts on it. Distinct from
Case 1 only in that the caller *consumes* the payload — Case 1
callers ignore the pop's result because the side effect (the repo
write) is what they cared about.

### 3.2 The decision tree

A reviewer checking a new sheet against T-24 walks this tree:

```
Does the save have a route the user wants to see the effect on,
that isn't the screen the editor launched from?
├── YES → Case 2: context.go(thatRoute).
└── NO  ↓
        Does the caller need the result value to render its next frame?
        ├── YES → Case 3: pop(value).
        └── NO  → Case 1: pop().
```

Three questions, three cases, zero ambiguity for the next reviewer.

### 3.3 Whether to formalise as T-24 — yes

**Architect call: add T-24 to the tenants list in
`flutter_ui_architecture.md` §8.** Exact wording in §8 below. The
existing 23 tenants cover *what to render* but they do not cover
*where to land after a mutation* — a real gap PM correctly named.
The rule is enforceable by review (a reviewer reading a new sheet's
save handler asks "which of the three cases?" and the answer must be
explicit). It is not enforceable by grep — `Navigator.pop` shows up
in every sheet for Cancel as well as Save, and `context.go` shows up
in the day-view chevrons, so a regex check would mostly false-positive.
T-24 is a review-time tenant, sized to fit the existing tenant tone.

### 3.4 Per-screen brief deltas

Each `specs/flutter_ui_architecture.md` §9 screen brief gets a
one-line addition naming the applicable case. Mechanical:

| Screen / Sheet | Case | Target / payload |
|---|---|---|
| 01 day view (no save handler at the screen level — entry rows route to LogEntrySheet) | — | — |
| 02 search (no save handler) | — | — |
| 03 food detail (no save — read-only) | — | — |
| 04 `LogEntrySheet` create | **2** | `/today/:consumedOn` |
| 04 `LogEntrySheet` edit | **2** | `/today/:consumedOn` (entry's date, possibly different from source) |
| 05 `CustomFoodScreen` create | **1** | pop (the search caller doesn't need the food back) |
| 05 `CustomFoodScreen` edit | **3** | pop with updated `Food` (`/foods/:id` re-renders) |
| 06 `LogWeightSheet` | **1** | pop; `/weight` already underneath |
| 07 goals — new / edit | **1** | pop; `/goals` already underneath |
| 08 profile editors (height, current weight, sex, birth-date, activity, units chooser) | **1** | pop; `/me` already underneath |
| 09 onboarding step 3 finish | **2** | `context.go(Routes.todayPath)` — this *is* the "natural home" of the just-saved profile + goal |

Onboarding step 3 is the existing precedent for Case 2; QL-002 is the
*second* instance, which is exactly what makes T-24 worth naming.

### 3.5 Files Refactor 2 touches

Refactor 2 is mostly documentation; the only behavioural change is
QL-002 itself (Feature 2 below). Documentation pass:

```
client/lib/features/log_entry/log_entry_sheet.dart        (+ doc comment on save handlers naming the case)
client/lib/features/profile/widgets/height_stepper_sheet.dart (+ doc comment naming Case 1)
client/lib/features/profile/widgets/current_weight_sheet.dart (+ doc comment naming Case 1)
client/lib/features/profile/widgets/sex_picker.dart            (+ doc comment naming Case 1)
client/lib/features/profile/widgets/birth_date_picker.dart    (+ doc comment naming Case 1)
client/lib/features/profile/widgets/activity_level_picker.dart (+ doc comment naming Case 1)
client/lib/features/profile/widgets/weight_unit_chooser.dart   (+ doc comment naming Case 1)
client/lib/features/weight/widgets/log_weight_sheet.dart       (+ doc comment naming Case 1)
client/lib/features/goals/widgets/new_goal_dialog.dart         (+ doc comment naming Case 1)
client/lib/features/goals/widgets/edit_goal_sheet.dart         (+ doc comment naming Case 1)
client/lib/features/custom_food/custom_food_screen.dart        (+ doc comment naming Case 1 (create) / Case 3 (edit))
client/lib/features/onboarding/onboarding_screen.dart          (+ doc comment naming Case 2 at the finish handler)
specs/flutter_ui_architecture.md                              (+ T-24 wording, + per-screen brief deltas)
```

13 files. All comment-block additions plus one tenant in the spec.
Zero behavioural change in these files; the QL-002 behavioural change
lives in Feature 2 below.

### 3.6 Acceptance criteria — Refactor 2

- `specs/flutter_ui_architecture.md` §8 grows a T-24 tenant whose
  wording matches §8 of this doc.
- §9's per-screen briefs each gain a one-line "Post-save: Case N"
  annotation (the table in §3.4).
- Every save handler in the 12 sheet/screen files above gets a
  dartdoc comment naming the case (`/// T-24 Case 1: pop-to-source.`
  etc.).
- The QL-002 behavioural change is the only code change in this PR;
  it is Feature 2 below.

---

## 4. Refactor 3 — Declarative provider-invalidation docs (Pattern C)

### 4.1 The convention

PM proposed "each repository mutator gets a dartdoc comment listing
which providers depend on its data." I rule on the exact shape:

**An `@invalidates` doc-tag block in the mutator's dartdoc.** Not a
separate annotation, not a registry, not a comment block — a
structured dartdoc section the way the rest of the codebase already
uses `**Pre-conditions**`, `**Fallback chain**` etc. (see
`locale_defaults.dart`'s docstring). The shape:

```dart
/// Patch an existing log entry. Mirrors `PATCH /log/{id}`.
///
/// `@invalidates`
/// - `daySummaryProvider(newDate)` — the ring + summary card.
/// - `logEntriesProvider(newDate)` — the meal section list.
/// - `daySummaryProvider(oldDate)` IF `consumed_on` changed.
/// - `logEntriesProvider(oldDate)` IF `consumed_on` changed.
/// - `recentFoodsProvider` — the row's food may shift rank.
/// - `frequentFoodsProvider` — same.
///
/// Call sites are responsible for invalidating per T-18 (minimal +
/// explicit); this list is the **contract** the call site reads. A
/// new dependent provider is added by editing this list and the call
/// sites in the same PR.
```

Why doc-tag-shape and not an annotation:

- An annotation (`@Invalidates(['daySummaryProvider'])`) is unfindable
  by Dart's analyzer in a useful way — it's a runtime metadata string,
  not a type. We'd need a custom lint to enforce it. The cost-benefit
  is wrong for v1.
- A separate `lib/data/invalidations.dart` registry would be the
  centralised "after-save bus" PM explicitly punted in §4 Pattern C.
- The doc-tag is greppable (`grep -rn '@invalidates' lib/`), readable
  by a dev at the call site (the IDE hover shows the dartdoc), and
  costs zero new code.

### 4.2 Files in scope

Every repository mutator. The complete list:

```
client/lib/repositories/log_repository.dart
  - create(LogCreate)         → @invalidates: daySummary, logEntries, recentFoods, frequentFoods
  - update(id, LogPatch)      → @invalidates: ditto + old-date variants when consumed_on shifts
  - delete(id) [if present]   → @invalidates: daySummary, logEntries, recentFoods, frequentFoods
client/lib/repositories/weight_repository.dart
  - create(WeightCreate)      → @invalidates: weightSeries (5 ranges), weightHistory, me (currentWeightKg derived)
  - delete(id) [if present]   → @invalidates: ditto
client/lib/repositories/profile_repository.dart
  - update(UserPatch)         → @invalidates: me; heightUnitProvider / weightUnitProvider re-derive automatically
client/lib/repositories/goal_repository.dart
  - create(GoalCreate)        → @invalidates: activeGoal, goals
  - update(id, GoalPatch)     → @invalidates: activeGoal, goals
  - markActive(id)            → @invalidates: activeGoal, goals
  - end(id)                   → @invalidates: activeGoal, goals
client/lib/repositories/food_repository.dart
  - create(FoodCreate)        → @invalidates: foodDetail(id), myFoods, customFoodCount, me (count derived)
  - update(id, FoodPatch)     → @invalidates: foodDetail(id), myFoods
  - addServing(id, …)         → @invalidates: foodDetail(id)
  - removeServing(id, sid)    → @invalidates: foodDetail(id)
```

8 repository files, ~14 mutator dartdocs. The audit confirms each
listed provider matches what the existing call sites already
invalidate today — Pattern C is documenting current truth, not
re-imagining it.

### 4.3 Is this code or docs?

**Documentation only.** Zero behavioural change. The contract is
prose; the call sites continue to do the right thing because they
already do today (T-18 was honoured by the original developers). The
value of this pass is the *next* time a dev adds a dependent
provider — they edit the `@invalidates` list, find every call site
via a single grep, and update consistently.

A small `tool/lint_invalidations_documented.sh` script that asserts
every public mutator on a `Repository` class has an `@invalidates`
block is *nice-to-have* but **out of scope** for QL. Punt to v1.1 if
ever needed; the doc pass alone is the QL deliverable.

### 4.4 Files Refactor 3 touches

```
client/lib/repositories/log_repository.dart       (+ @invalidates on create, update, delete)
client/lib/repositories/weight_repository.dart    (+ @invalidates on create, delete)
client/lib/repositories/profile_repository.dart   (+ @invalidates on update)
client/lib/repositories/goal_repository.dart      (+ @invalidates on create, update, markActive, end)
client/lib/repositories/food_repository.dart      (+ @invalidates on create, update, addServing, removeServing)
```

5 files, doc-only.

### 4.5 Acceptance criteria — Refactor 3

- Every public mutator on each of the 5 repositories above has an
  `@invalidates` block in its dartdoc.
- The list of providers in each block matches the providers the
  existing call sites invalidate today (verification by reading the
  call site + the doc side-by-side).
- A `grep -rn '@invalidates' lib/repositories/` returns ≥ 14 hits.
- No call-site behaviour changes in this PR.

---

## 5. Feature 1 — Height units (QL-001 deep dive)

Structurally a mirror of `architect_log_edit_and_units.md` §3 (the
weight-unit feature). The seams, file shape, and acceptance criteria
all rhyme; deltas from the weight feature are called out inline.

### 5.1 Wire shape

**`User.height_unit: HeightUnit` — new field, additive.** OpenAPI
shape the backend ticket needs to land (the PM has flagged the
migration; this section names the wire so the client can mock
pre-backend, same pattern as the weight migration):

```yaml
User:
  type: object
  required: [id, issuer, external_id, created_at, updated_at, weight_unit, height_unit]
  properties:
    # ... existing ...
    height_unit:
      $ref: "#/components/schemas/HeightUnit"

UserPatch:
  properties:
    # ... existing ...
    height_unit: { $ref: "#/components/schemas/HeightUnit" }

HeightUnit:
  type: string
  enum: [cm, ft_in]
```

**Server default `cm`** for existing users (the migration is a
one-column add, same shape as `weight_unit`). The client tolerates
the field being missing on the wire during the pre-backend window —
`User.fromJson` reads `json['height_unit']` and defaults to
`HeightUnit.cm`. The PM ruled "the client tolerates absence by
defaulting to `cm`" in §2.1 of the audit; this section honours that.

### 5.2 Client domain — the enum

New `HeightUnit { cm, ftIn }` in `client/lib/domain/enums.dart`,
sibling to `WeightUnit`. Note the wire deviation from `name` —
`HeightUnit.ftIn → 'ft_in'`, not `'ftIn'` (same precedent as
`ActivityLevel.veryActive → 'very_active'`). Members:
- `wire` — `'cm'` / `'ft_in'`.
- `shortLabel` — `'cm'` / `'ft·in'` (middot composite for the chooser
  trailing summary; the height row itself renders `5 ft 9 in`).
- `longLabel` — `'centimeters'` / `'feet and inches'` for `Semantics`
  labels (T-20).
- `fromWire(String)` — strict, throws on unknown.

### 5.3 `User` model + `UserPatch`

`client/lib/domain/user.dart` additions, identical shape to the
existing `weightUnit` addition: `heightUnit` field defaulting to
`HeightUnit.cm`, `copyWith`/`operator==`/`hashCode` updates,
`fromJson` tolerant of missing (`json['height_unit'] == null ?
HeightUnit.cm : HeightUnit.fromWire(...)`), `toJson` always emits.
`UserPatch` gains a nullable `heightUnit` field; `toJson` emits only
when set. `ProfileRepository.update` accumulates the field with one
`if (data.heightUnit != null)` block; no new repository method.

### 5.4 The `formatHeight` seam

New file `client/lib/domain/units/length.dart`. Public surface — four
functions + two `Decimal` constants, deliberately mirror of
`weight.dart` so a dev who's read the weight seam reads length in 30
seconds:

```dart
/// Exact inch in centimeters — 1 in = 2.54 cm (international).
final Decimal _cmPerIn = Decimal.parse('2.54');

/// Reciprocal — 1 cm = 0.393700787 in. Nine digits cover the
/// half-to-even-at-integer-inches resolution; deeper digits don't
/// change any rounded display.
final Decimal _inPerCm = Decimal.parse('0.393700787');

/// Format a height stored canonically in `cm` for display in `unit`.
/// - `cm`   → `"175"` (integer; caller appends suffix).
/// - `ftIn` → composite `"5 ft 9 in"` (units inline; `"6 ft"` when
///   the inch remainder is zero).
String formatHeight(Decimal cm, HeightUnit unit, {String? locale});

/// `formatHeight` + the appropriate visible suffix, in one string.
/// - cm:   `"175 cm"`
/// - ftIn: `"5 ft 9 in"` (composite already inlines its units).
String formatHeightWithUnit(Decimal cm, HeightUnit unit, {String? locale});

/// Parse a raw text input into canonical cm. Inverse of [formatHeight].
/// Accepts cm decimals (locale-separator tolerant), and ftIn shapes
/// `"5"` / `"5 9"` / `"5 ft 9 in"`. Throws `FormatException` on
/// unparseable input.
Decimal parseHeightToCm(String input, HeightUnit unit);

/// Typed overload — convert an integer (feet, inches) pair to cm.
/// `HeightStepper` calls this directly so the widget never has to
/// build a composite string. Negative inputs throw.
Decimal parseFeetInchesToCm(int feet, int inches);
```

Private internals mirror the weight seam: `_formatCm` uses
`NumberFormat.decimalPatternDigits(decimalDigits: 0)` over a
`roundHalfToEvenScaled(cm, 0)` value; `_formatFtIn` runs the same
algorithm as `_formatStone` in `weight.dart` — round
`in_total = cm × _inPerCm` to integer inches via `roundHalfToEven`,
then `~/ 12` and remainder to render `"$feet ft $remainder in"` (drop
the ` 0 in` suffix when remainder is zero). The carry rule from
stones applies verbatim: round to integer inches first, then divmod;
`5 ft 11.6 in → 72 in → 6 ft`, not `5 ft 12 in`.

Float safety per T-17: every multiplication is `Decimal`-typed; only
`.toDouble()` fires inside `NumberFormat.format` at the leaf, after
rounding. The ftIn branch is integer-only — no float appears.

### 5.5 Test cases the PMgr should put on the ticket

Stone has a carry edge that PM named explicitly; ftIn has the same.
The table:

| cm input | Expected ftIn output | Notes |
|---|---|---|
| `0` | `0 ft` | Edge: zero |
| `30.48` | `1 ft` | 12 inches exact |
| `152.4` | `5 ft` | 60 inches exact |
| `175` | `5 ft 9 in` | Standard adult male |
| `182.88` | `6 ft` | Carry edge: 72.0 in rounds to 72 → `6 ft 0 in` → `6 ft` |
| `182` | `5 ft 12 in`? **No.** | 182 cm × 0.393700787 = 71.65… → rounds to 72 → carries: `6 ft` |
| `181` | `5 ft 11 in` | Just below carry — 71.26… → 71 → `5 ft 11 in` |
| `200` | `6 ft 7 in` | Standard tall |
| `250` | `8 ft 2 in` | Upper bound from PM's input range |

The carry edge at 182cm is the analog of `13 st 13.6 lb → 14 st`.
Test it.

### 5.6 `HeightStepper` widget

Lifted T-23-compliant primitive at
`client/lib/widgets/height_stepper.dart`. Sibling of `WeightStepper`,
same internal model — a canonical `Decimal cm` value that the widget
converts to / from the active display unit on every commit. Public
shape:

```dart
class HeightStepper extends ConsumerStatefulWidget {
  const HeightStepper({
    required this.value,                  // canonical Decimal cm
    required this.onChanged,
    this.unitOverride,                    // null → ref.watch(heightUnitProvider)
    this.minCm,
    this.maxCm,
    this.hasError = false,
    this.semanticsLabel,
    super.key,
  });
  // ... fields mirror the constructor.
}
```

Implementation:
- **cm mode** → one `_TapStepper` with `'$cmInt cm'` label, integer
  step, clamps to `[minCm, maxCm]`. **Architect call: integer-step
  (1 cm), not PM's "0.5 cm".** The half-step doesn't render at
  integer resolution and produces non-intuitive behaviour (two taps
  sometimes move the displayed value by 1, sometimes by 2). Integer
  step is the right shape for a stepper rendering integer values.
  Bounds: 80–250 cm (PM-ruled).
- **ftIn mode** → a `Row` with two `_TapStepper`s. Feet `'$feet ft'`
  (soft clamp 3..8 — buttons disable at edges, no error), inches
  `'$inches in'` (0..11). Inches `+` **carries** to feet at 12;
  inches `-` **borrows** from feet at 0. Mirror of
  `WeightStepper`'s stone carry/borrow in
  `weight_stepper.dart:_incrementPounds`. `onChanged(parseFeetInchesToCm(feet,
  inches))` fires on every commit.

`_TapStepper` is the private 48-px stepper-row primitive that
`WeightStepper` defined inline (see `weight_stepper.dart:310–408`).
`HeightStepper` **re-inlines** a sibling — same shape, same colors,
same Semantics. A v1.1 ticket "lift `_TapStepper` to
`lib/widgets/tap_stepper.dart`" converges the two. The current weight
file deliberately deferred this lift ("a future ticket can converge
the two private types into one shared primitive"); the QL pack
honours that convention rather than creating a new one.

### 5.7 `HeightUnitChooser`

Feature-private widget at
`client/lib/features/profile/widgets/height_unit_chooser.dart`.
Mirror of `weight_unit_chooser.dart` in every meaningful way:

```dart
/// Profile → Preferences → Units chooser, height axis (QL-001).
///
/// Tapping the Units row opens **two** choosers stacked: weight and
/// height. The PM ruled (§2.1) that "editing one preference doesn't
/// dismiss the other" — see §5.8 for the joined-chooser shape.
///
/// On `compact`, a [showModalBottomSheet] with two
/// [ActivityOption]-shaped rows — Centimeters, Feet & Inches.
/// On `medium` / `expanded`, an anchored popup menu.
///
/// On selection PATCHes `height_unit` through
/// [ProfileRepository.update], invalidates [meProvider], and closes
/// the chooser. The downstream [heightUnitProvider] flips on the
/// next frame, so every height-rendering widget refreshes (T-18).
Future<void> showHeightUnitChooser(
  BuildContext context,
  WidgetRef ref, {
  required HeightUnit initial,
});
```

The labels:

```dart
String _title(HeightUnit unit) {
  switch (unit) {
    case HeightUnit.cm: return 'Centimeters (cm)';
    case HeightUnit.ftIn: return 'Feet & inches (ft, in)';
  }
}

String _subtitle(HeightUnit unit) {
  switch (unit) {
    case HeightUnit.cm: return 'Common worldwide';
    case HeightUnit.ftIn: return 'Common in the US and UK';
  }
}
```

### 5.8 Joined chooser layout — the PM acceptance criterion

PM acceptance §2.1 names: "Tapping it opens a chooser that now offers
both units in a stacked layout (sheet on compact, popup menu on
expanded). Editing one preference doesn't dismiss the other."

**Architect call: implement as a single `UnitsChooserSheet` /
`showUnitsChooser`** in
`client/lib/features/profile/widgets/units_chooser.dart`, which
renders both axes inside one sheet/popup. The existing
`weight_unit_chooser.dart` and the new `height_unit_chooser.dart` are
kept as the primitive per-axis renderers (each is one `SegmentedSelect`
or `ActivityOption` column), and the joined sheet composes the two.
The Profile screen's Units row tap now opens the joined sheet, not
the per-axis chooser.

Shape:

```dart
/// Profile → Preferences → Units. Joined chooser for all
/// display-unit axes.
///
/// Compact: a [showModalBottomSheet] with two stacked sections —
///   Weight (three [ActivityOption]s) above Height (two
///   [ActivityOption]s). The user can tap any row in either section
///   without dismissing the sheet — selection PATCHes the
///   corresponding `weight_unit` or `height_unit` field individually
///   and updates the local section's selected state in place. The
///   sheet only dismisses on swipe-down, tap-outside, or an explicit
///   "Done" footer button.
///
/// Medium / expanded: an anchored popup with the two sections
///   side-by-side or stacked (the popup max-width is 360 px so we
///   stack vertically). Same multi-select-in-place behaviour as the
///   compact sheet.
Future<void> showUnitsChooser(
  BuildContext context,
  WidgetRef ref, {
  required WeightUnit initialWeight,
  required HeightUnit initialHeight,
});
```

The single sheet PATCHes each preference separately as the user
taps; if the network fails, only the just-tapped row's `selected`
state rolls back and a SnackBar surfaces the error. The other
section is unaffected — which is what PM's "editing one preference
doesn't dismiss the other" rule encodes.

The Profile screen's Units row tap migrates:

```dart
SettingsRow(
  key: const Key('row-units'),
  icon: Icons.public,
  label: 'Units',
  value: '${user.weightUnit.shortLabel}, '
         '${user.heightUnit.shortLabel}, kcal, g',
  semanticsLabel:
      'Weight ${user.weightUnit.longLabel}, '
      'height ${user.heightUnit.longLabel}. Tap to change.',
  onTap: () => showUnitsChooser(
    context,
    ref,
    initialWeight: user.weightUnit,
    initialHeight: user.heightUnit,
  ),
),
```

The existing `showWeightUnitChooser` is **kept** as a primitive
(internal use only — `showUnitsChooser` composes it); existing tests
that mount it directly continue to pass. The migration in
`profile_screen.dart` swaps the row's `onTap` from
`showWeightUnitChooser` to `showUnitsChooser`. One callsite change.

### 5.9 Onboarding step 2

`step_2_about_you.dart` changes:

- The height column's `_NumberStepper` (lines 93–104 today, with the
  inline `_formatHeightCm` helper at lines 359–365) **is deleted**.
  In its place: a `HeightStepper` widget reading
  `unitOverride: ref.watch(onboardingHeightUnitProvider)`. PM
  acceptance §2.1: "The `_formatHeightCm` flag in
  `step_2_about_you.dart` is removed along with the inline
  `_NumberStepper`, replaced by `HeightStepper`."
- Above the joint Height / Weight row, the existing `_FieldLabel('Weight
  unit')` becomes `_FieldLabel('Units')` with a **stacked pair of
  segmented controls** below — one for weight (the existing
  `SegmentedSelect<WeightUnit>` at lines 70–82) and a new one for
  height. PM acceptance §2.1: "A small unit chooser (segmented, two
  options) sits next to the unit chooser for weight — single 'units'
  row, two segmented controls below it, one labeled 'Height' and one
  'Weight'."

Layout shape (rough):

```dart
_FieldLabel('Units'),
SizedBox(height: context.space.x2),
Column(
  crossAxisAlignment: CrossAxisAlignment.stretch,
  children: <Widget>[
    _SubLabel('Weight'),
    SizedBox(height: context.space.x1),
    SegmentedSelect<WeightUnit>(...),
    SizedBox(height: context.space.x2),
    _SubLabel('Height'),
    SizedBox(height: context.space.x1),
    SegmentedSelect<HeightUnit>(
      key: const Key('onboarding-height-unit-chooser'),
      options: const <HeightUnit>[HeightUnit.cm, HeightUnit.ftIn],
      labelBuilder: _heightUnitLabel,
      selected: activeHeightUnit,
      onChanged: notifier.setHeightUnit,
    ),
  ],
),
```

`_SubLabel` is a smaller-text variant of `_FieldLabel` (12 px ink2,
not 11 px ink3 eyebrow) — feature-private, inline. The widget tree
isn't sprouting a new lifted primitive for this.

The onboarding `_heightUnitLabel`:

```dart
String _heightUnitLabel(HeightUnit unit) {
  switch (unit) {
    case HeightUnit.cm: return 'Centimeters (cm)';
    case HeightUnit.ftIn: return 'Feet & inches';
  }
}
```

### 5.10 Profile editor — `HeightStepperSheet`

`client/lib/features/profile/widgets/height_stepper_sheet.dart`
shrinks: today it's a `_NumberStepper` + a `TextField` + range
validation, all hand-rolled (lines 1–199). After QL-001 it composes
`HeightStepper` and drops the hand-rolled stepper / field / clamp
logic — the `HeightStepper` widget owns clamp, parsing, and
rendering. The sheet's responsibilities reduce to:

1. Seed the widget's `value` from `widget.initial`.
2. Track local edit state.
3. On save, `await repo.update(UserPatch(heightCm: _cm))`,
   `ref.invalidate(meProvider)`, `Navigator.pop()` (T-24 Case 1).

The whole file drops from ~200 lines to ~80. PM acceptance §2.1
implicitly requires this — "the height row in Profile → Body renders
via `formatHeight`" means the editor must respect the unit, which
means the inline `_NumberStepper` (which assumes cm) is wrong for an
ft_in user.

### 5.11 Profile screen — Body section render

`profile_screen.dart:159–161` today:

```dart
value: user.heightCm == null
    ? 'Set'
    : '${user.heightCm!.toBigInt()} cm',
```

After QL-001:

```dart
value: user.heightCm == null
    ? 'Set'
    : formatHeightWithUnit(user.heightCm!, user.heightUnit),
```

One-line swap. The whole row's behaviour follows: the value reads
`5 ft 9 in` for an ftIn user, `175 cm` for a cm user.

### 5.12 Inventoried height surfaces

Complete table — every site that today renders a height in cm or
takes a cm input:

| File | Today | After |
|---|---|---|
| `client/lib/domain/units/length.dart` | n/a (new file) | `formatHeight`, `formatHeightWithUnit`, `parseHeightToCm`, `parseFeetInchesToCm`, internal `_formatCm` / `_formatFtIn` |
| `client/lib/domain/enums.dart` | no `HeightUnit` | add `HeightUnit { cm, ftIn }` |
| `client/lib/domain/user.dart` | `heightCm` only; no unit field | + `heightUnit` field, copyWith, fromJson tolerant of missing, toJson always emits |
| `client/lib/domain/drafts.dart` | onboarding draft has `heightCm` but no unit | + `heightUnit` field |
| `client/lib/domain/locale_defaults.dart` | `defaultWeightUnitForLocale` only | + `defaultUnitsForLocale` returning record, + `@Deprecated` `defaultHeightUnitForLocale` wrapper |
| `client/lib/providers/profile_providers.dart` | `meProvider`, `weightUnitProvider`, `localeDefaultWeightUnitProvider` | + `localeDefaultsProvider`, + `heightUnitProvider`; `localeDefaultWeightUnitProvider` annotated `@Deprecated` |
| `client/lib/providers/draft_providers.dart` | `setWeightUnit`, `onboardingWeightUnitProvider` | + `setHeightUnit`, + `onboardingHeightUnitProvider` |
| `client/lib/repositories/profile_repository.dart` | `update(UserPatch)` writes `weight_unit` | + writes `height_unit` |
| `client/lib/widgets/height_stepper.dart` | n/a (new file) | `HeightStepper(value, onChanged, unitOverride, minCm, maxCm, hasError, semanticsLabel)` |
| `client/lib/features/profile/widgets/height_stepper_sheet.dart` | hand-rolled cm stepper + TextField + clamp logic | swap body to `HeightStepper(unitOverride: ref.watch(heightUnitProvider))`; drop the inline stepper / field / clamp |
| `client/lib/features/profile/widgets/height_unit_chooser.dart` | n/a (new file) | per-axis chooser primitive (Case 1) |
| `client/lib/features/profile/widgets/units_chooser.dart` | n/a (new file) | joined chooser sheet/popup composing weight + height per-axis choosers |
| `client/lib/features/profile/profile_screen.dart` line 159–161 (Height row) | `'${user.heightCm!.toBigInt()} cm'` | `formatHeightWithUnit(user.heightCm!, user.heightUnit)` |
| `client/lib/features/profile/profile_screen.dart` lines 203–216 (Units row) | tap opens `showWeightUnitChooser` | tap opens `showUnitsChooser`; value reads `<weight>, <height>, kcal, g` |
| `client/lib/features/onboarding/widgets/step_2_about_you.dart` | inline `_NumberStepper` + `_formatHeightCm` for height | `HeightStepper(unitOverride: ref.watch(onboardingHeightUnitProvider))`; delete `_NumberStepper` private + `_formatHeightCm` helper; add a `SegmentedSelect<HeightUnit>` next to the weight one |
| `client/lib/features/onboarding/onboarding_screen.dart` | PATCHes profile with `weightUnit` | + PATCHes `heightUnit: draft.heightUnit ?? defaultUnitsForLocale().height` |
| `client/lib/features/today/widgets/...` | none (no Today widget renders height) | — |

15 distinct files. The bulk is mechanical mirror-of-weight; new
seams: `length.dart`, `HeightStepper`, `HeightUnitChooser`,
`UnitsChooser`. The widget-level migration is 5 sites
(profile_screen Height row, profile_screen Units row,
height_stepper_sheet body, step_2_about_you height column,
onboarding_screen finish PATCH).

**Files I'm explicitly NOT touching** from the PM inventory:

- `client/lib/features/profile/widgets/settings_card.dart`,
  `settings_row.dart` — the chrome doesn't change; row content does
  (in `profile_screen.dart` consumer). Same call as the weight
  feature.
- `client/lib/widgets/quantity_stepper.dart` — unit-agnostic.
  `HeightStepper` doesn't wrap it (the `_TapStepper` shape is the
  right primitive for the height stepper's integer-only display).

### 5.13 Acceptance criteria — Feature 1

- `User.height_unit` round-trips through OpenAPI (backend ticket
  pending), `User.fromJson`, `User.toJson`, `UserPatch.toJson`. The
  field is tolerated as missing during the pre-backend window —
  `User.fromJson` defaults to `HeightUnit.cm`.
- `HeightUnit` is an enum with two values (`cm | ftIn`). The wire
  string is lowercase `cm` / `ft_in`.
- `formatHeight(Decimal cm, HeightUnit unit) → String` exists in
  `client/lib/domain/units/length.dart`. The cm branch renders
  integer cm; the ftIn branch renders the composite.
- `formatHeightWithUnit` and `parseHeightToCm` are public; the ftIn
  case has its own typed `parseFeetInchesToCm(int feet, int inches)`.
- Locale default applies only at first onboarding submit when the
  draft's `heightUnit` is null. The locale read is overridable by
  test (`defaultUnitsForLocale(countryCodeOverride: 'US')`).
- The Profile → Preferences → Units row is interactive and opens
  `showUnitsChooser`. Tapping any of the two height options PATCHes
  `height_unit`, invalidates `meProvider`, and the change reflects
  across the app on the next frame via `heightUnitProvider`. Editing
  the weight section in the same sheet does not dismiss the height
  selection.
- Onboarding step 2 shows two stacked segmented controls under a
  single "Units" label — one for weight, one for height — followed
  by the height + weight stepper row. The default selection is
  `defaultUnitsForLocale()` for each axis. PATCH at finish writes
  both picked units.
- Every height-rendering surface in §5.12 goes through `formatHeight`
  / `formatHeightWithUnit`. No widget multiplies by `2.54` or
  divides by `12`. The lint check is a `grep` for those literals in
  `client/lib/features/` and `client/lib/widgets/`.
- The ftIn composite renders correctly across the test cases in
  §5.5. The carry edge (`182 cm → "6 ft"`) is covered by a unit test
  on `_formatFtIn`.
- The ftIn input renders two side-by-side `_TapStepper`s (feet
  integer 3–8, inches integer 0–11). Inches `+` carries to feet at
  12; inches `-` borrows from feet at 0.
- `Semantics` labels include the rendered value with its long-form
  unit (`"Height 5 ft 9 in, feet and inches"` for ftIn; `"Height 175
  centimeters"` for cm). Per T-20.
- The Profile → Body Height row reads `5 ft 9 in` for an ftIn user
  and `175 cm` for a cm user.
- The inline `_NumberStepper` private widget and `_formatHeightCm`
  helper in `step_2_about_you.dart` are deleted in the same PR as
  `HeightStepper` lands.

---

## 6. Feature 2 — Log-save returns home (QL-002 deep dive)

### 6.1 The exact change

`client/lib/features/log_entry/log_entry_sheet.dart` today (line ~386
for compact create; ~407 for medium/expanded create; ~456 for edit)
calls `Navigator.of(context).pop<LogEntry?>(...)` after a successful
save. QL-002 changes this to **`context.go(targetPath)`** for the
entry's `consumedOn` date, with one nuance for the dialog (expanded)
case where the sheet is a route-less `showDialog` overlay.

The target path helper lives in `today_internals.dart` (already there
in spirit — see `navigateDay` lines 47–64 — but the helper has been
internal-to-chevrons until now). Extract a `pathForDay(DateTime
date)` helper alongside `navigateDay` so both callers (the chevrons
and the new log-save handler) share the date→path math. PM
acceptance §2.2 explicitly requires "The route helper that
constructs the path is **shared** with `navigateDay` in
`today_internals.dart`. Don't duplicate the date-to-path math."

```dart
/// The canonical day-view path for [date]. `/today` for the local-now
/// day; `/today/$y-$m-$d` otherwise. Pairs with [navigateDay].
String pathForDay(DateTime date) {
  final now = DateTime.now();
  final isToday = date.year == now.year &&
      date.month == now.month &&
      date.day == now.day;
  if (isToday) return Routes.todayPath;
  final y = date.year.toString().padLeft(4, '0');
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return '${Routes.todayPath}/$y-$m-$d';
}
```

`navigateDay` becomes a thin wrapper:

```dart
void navigateDay(BuildContext context, DateTime current, int delta) {
  final target = DateTime(current.year, current.month, current.day + delta);
  context.go(pathForDay(target));
}
```

### 6.2 Create-mode — compact (outbox) path

`_onCreatePressed` (around line 356), compact branch (line 366–395
today). The current shape:

```dart
await ref.read(logOutboxProvider.notifier).enqueue(payload: logCreate.toJson());
messenger?.showSnackBar(const SnackBar(content: Text('Logged — syncing')));
ref
  ..invalidate(daySummaryProvider(_date))
  ..invalidate(logEntriesProvider(_date))
  ..invalidate(recentFoodsProvider)
  ..invalidate(frequentFoodsProvider);
Navigator.of(context).pop<LogEntry?>(_optimisticEntry(logCreate));
```

After QL-002:

```dart
await ref.read(logOutboxProvider.notifier).enqueue(payload: logCreate.toJson());
messenger?.showSnackBar(const SnackBar(content: Text('Logged — syncing')));
ref
  ..invalidate(daySummaryProvider(_date))
  ..invalidate(logEntriesProvider(_date))
  ..invalidate(recentFoodsProvider)
  ..invalidate(frequentFoodsProvider);
if (!mounted) return;
// T-24 Case 2: route-to-effect. `go` replaces the stack to the
// day-view; the sheet's own route disappears as a side effect on
// compact (DraggableScrollableSheet is in the same route stack).
context.go(pathForDay(_date));
```

PM acceptance §2.2: "The outbox/optimistic-insert path (compact,
create-mode) also routes after the optimistic pop. The SnackBar
'Logged — syncing' still fires; the user lands on Today with the
optimistic row already visible."

Note we drop the `_optimisticEntry` return-value path because the
caller's `await showLogEntrySheet(...)` future no longer matters —
the user is on a different route. The optimistic row appears on Today
via `daySummaryProvider`'s invalidation + the outbox provider's
own optimistic merge (already in place).

**Open detail.** The current return-value contract of `showLogEntrySheet`
is `Future<LogEntry?>`. Callers that today `await showLogEntrySheet`
and *use* the result need to be re-audited. A grep confirms: the day
view's `editLogEntry` discards the result (`today_internals.dart:129`
"Discard the return — the sheet itself invalidates"); the food-detail
page's "Add to log" button (line ~ in `food_detail_screen.dart`)
discards it too. So in practice the return value is unused — we can
keep it for source-compat but every code path now does `context.go`
and the future resolves to `null` (or to the optimistic entry, doesn't
matter since no caller reads it). **PMgr — note this in the ticket
pack so a dev agent doesn't try to repurpose the return.**

### 6.3 Create-mode — medium/expanded (dialog) path

`_onCreatePressed` non-compact branch (lines 397–415 today). The
current shape:

```dart
final entry = await ref.read(logRepositoryProvider).create(logCreate);
if (!mounted) return;
ref
  ..invalidate(daySummaryProvider(_date))
  ..invalidate(logEntriesProvider(_date))
  ..invalidate(recentFoodsProvider)
  ..invalidate(frequentFoodsProvider);
Navigator.of(context).pop<LogEntry?>(entry);
```

After QL-002 — **two-step dismissal** because the dialog isn't a
route in the navigator stack the same way the bottom sheet is:

```dart
final entry = await ref.read(logRepositoryProvider).create(logCreate);
if (!mounted) return;
ref
  ..invalidate(daySummaryProvider(_date))
  ..invalidate(logEntriesProvider(_date))
  ..invalidate(recentFoodsProvider)
  ..invalidate(frequentFoodsProvider);
// T-24 Case 2 with dialog correction: pop the dialog first, then
// `go` to the day view. PM acceptance §2.2: "Order matters: dialog
// must close before the route change so the dialog frame doesn't
// orphan against the new page."
Navigator.of(context).pop<LogEntry?>(entry);
if (!context.mounted) return;
context.go(pathForDay(_date));
```

The `pop` returns the entry to the (rarely-reading) caller, the
`context.go` replaces the under-dialog route to the day view. T-24's
"Dialog-on-expanded sheets that use `context.go` must `pop()` the
dialog first" clause is what this is. The check
`if (!context.mounted)` between pop and go is defence — if the
caller's BuildContext gets disposed during pop, the go is a no-op.

### 6.4 Edit-mode

`_onEditPressed` (line 422). Three sub-cases today:

1. No-op (no fields changed) — line 432–435.
2. Successful PATCH — line 444–456.
3. Failure — line 457–460.

PM ruled in §2.2: "In **edit mode**, route the same way — go to the
entry's (possibly-changed) date. The user editing a backdated entry
expects to land on that date's day view, not on today's." All three
sub-cases share the same routing rule after success — including the
no-op:

```dart
// No-op branch:
if (patch.isEmpty) {
  if (!mounted) return;
  // T-24 Case 2: same rule even when nothing changed. PM acceptance
  // §2.2: "The edit-mode no-op-PATCH branch routes too — the user
  // pressed save and expects to land at Today even if nothing
  // changed."
  Navigator.of(context).pop<LogEntry?>(widget.existing);
  if (!context.mounted) return;
  context.go(pathForDay(_date));
  return;
}

// Successful PATCH branch:
final updated = await repo.update(widget.existing!.id, patch);
if (!mounted) return;
ref
  ..invalidate(daySummaryProvider(newDate))
  ..invalidate(logEntriesProvider(newDate))
  ..invalidate(recentFoodsProvider)
  ..invalidate(frequentFoodsProvider);
if (!_sameDay(originalDate, newDate)) {
  ref
    ..invalidate(daySummaryProvider(originalDate))
    ..invalidate(logEntriesProvider(originalDate));
}
Navigator.of(context).pop<LogEntry?>(updated);
if (!context.mounted) return;
context.go(pathForDay(newDate));    // newDate, not originalDate — see §6.5
```

The failure branch is **unchanged**: `setState(_submitting = false)`,
SnackBar, sheet stays open. PM acceptance §2.2: "The outbox-failure
path stays put (sheet stays open with input intact) — same as today.
No silent navigation on failure."

### 6.5 Edit-mode: should both go to `/today/$consumedOn`, or just
       create? — the architect's call

PM's open question: "should both go to `/today/$consumedOn`, or just
create? (Edit might naturally pop with payload back to the entry's
source.) Be opinionated."

**Architect call: both go to `/today/$consumedOn` (the
possibly-shifted new date).** Three reasons:

1. **The user's mental model is unified.** "I saved this entry; show
   me where it lives." The destination is "where the entry lives,"
   which is its day view, regardless of whether the user created or
   edited it.
2. **The source view for edit is already the day view.** Edits today
   are launched from `editLogEntry` in `today_internals.dart`, which
   is the day-view tap handler. So Case 2 (route-to-effect) and Case
   3 (pop-with-payload) **converge** for edit-from-day-view — the
   "source" and the "natural home" are the same screen. Picking
   Case 2 (route) makes the date-shift case (edit a backdated entry,
   land on the backdate) work; Case 3 (pop-with-payload) would land
   the user on the wrong date if `consumed_on` shifted.
3. **The future "edit from search history" path works the same way.**
   If a v1.1 ticket adds "long-press a recent food → edit your most
   recent entry of it," the source isn't the day view — but the user
   still wants to see the edited entry, not stare at the search
   history. Route-to-effect generalises; pop-with-payload doesn't.

So edit and create share the rule: route to `pathForDay(consumedOn)`
on success. The `consumedOn` is the **new** date (the date the user
just saved with), not the original — if the user edited the entry's
date from May 14 to May 15, they land on `/today/2026-05-15`.

### 6.6 Tests

PM acceptance §2.2: "Tests cover the four paths: compact-create,
compact-edit, expanded-create, expanded-edit. Test fixture: open
the sheet from Food Detail, save, assert the current location is
`/today` (or `/today/2026-05-15` for a backdated entry)."

The harness uses `go_router`'s `routerDelegate.currentConfiguration`
to read the active path after the save handler completes. Each test:

1. Mount `AppScaffold` with the four mock providers seeded.
2. Push to `/foods/:id` to set the source.
3. Tap "Add to log" (or for edit: tap a `FoodRow` on `/today`).
4. Manipulate the sheet's controls (set quantity, tap a backdate
   date row).
5. Tap Save (or "Save changes").
6. Assert: `router.routerDelegate.currentConfiguration.fullPath ==
   '/today'` (or `'/today/2026-05-15'` for the backdated edit).
7. Optionally assert: the optimistic row is in the day view's meal
   section (compact create — outbox).

Eight assertions across four tests. The fixture file lives at
`client/test/features/log_entry/log_save_returns_home_test.dart`.

### 6.7 Files Feature 2 touches

```
client/lib/features/log_entry/log_entry_sheet.dart        (swap 3 pop sites → pop + context.go pairs)
client/lib/features/today/today_internals.dart            (+ pathForDay helper; refactor navigateDay to use it)
client/test/features/log_entry/log_save_returns_home_test.dart  (new — four assertion tests)
```

3 files. Two production files + one test file. The smallest
behavioural-change PR in the pack.

### 6.8 Acceptance criteria — Feature 2

- `pathForDay(DateTime)` exists in
  `client/lib/features/today/today_internals.dart`. `navigateDay` is
  refactored to use it. No duplication of the date-to-path math.
- `LogEntrySheet._onCreatePressed` (compact branch) replaces
  `Navigator.pop` with `context.go(pathForDay(_date))` after the
  outbox enqueue + SnackBar + invalidations.
- `LogEntrySheet._onCreatePressed` (medium/expanded branch) calls
  `Navigator.pop` first, then `context.go(pathForDay(_date))` (with
  a `mounted` check between).
- `LogEntrySheet._onEditPressed` no-op branch pops first, then
  `context.go(pathForDay(_date))`.
- `LogEntrySheet._onEditPressed` success branch pops first, then
  `context.go(pathForDay(newDate))` (the new, possibly-shifted
  date — not the original).
- `LogEntrySheet._onEditPressed` failure branch is unchanged
  (`_submitting = false`, SnackBar, sheet stays open).
- `LogEntrySheet._onCreatePressed` failure branch is unchanged.
- The save handlers' dartdocs name "T-24 Case 2" with one line of
  rationale.
- Four tests pass: compact-create, compact-edit, expanded-create,
  expanded-edit. Each asserts the post-save path on the router.
- Manual: log a food from `/foods/:id` and land on `/today`. Edit a
  backdated entry and land on `/today/2026-05-14`.

---

## 7. Per-screen / per-item map

The PMgr reads this to confirm coverage.

| QL-NNN | Title (PM doc summary) | Handled by section |
|---|---|---|
| QL-001 | Height units (user-selectable) | §5 (Feature 1) |
| QL-002 | Saving a log entry returns to Today | §6 (Feature 2) |
| QL-003 | Audit ALL post-save / post-mutation navigation | §3 (Refactor 2, T-24) |
| QL-004 | Unify the unit-preference seam | §2 (Refactor 1) |
| QL-005 | Replace remaining `CircularProgressIndicator`s | §7.1 (dev ticket — single sweep, T-08-aligned) |
| QL-006 | Delete or wire the bookmark icon on Food Detail | §7.2 (dev ticket — delete) |
| QL-007 | Resolve "Coming soon" SnackBars | §7.3 (dev ticket — hide the two rows) |
| QL-008 | Autofocus inputs on first paint | §7.4 (dev ticket — per-sheet pass) |
| QL-009 | Today day-view: backdate "Jump to today" pill | §7.5 (dev ticket — chip in date bar) |
| QL-010 | Pending-sync edit guard: row feedback | §7.6 (dev ticket — 200ms tint + Semantics) |
| QL-011 | Date-picker affordance in log-entry sheet | §7.7 (dev ticket — DATE row) |
| QL-012 | Touch-target audit (`SheetCloseButton`) | §7.8 (dev ticket — Pattern D cherry-pick) |
| QL-013 | Today compact: empty-day pill | §7.9 (dev ticket — accent-soft pill) |
| QL-014 | Onboarding: Start-over affordance | §7.10 (dev ticket — text button on step 3) |
| QL-015 | Profile editors: dismiss-without-save test | §7.11 (dev ticket — regression tests, no behaviour change) |
| QL-016 | Goals: weight-sweep verification | §7.12 (dev ticket — verification grep) |
| QL-017 | Search: clear-query stale-flash | §7.13 (dev ticket — early-clear in `_ResultsSection`) |
| QL-018 | Custom-food save: retry-failed-servings | §7.14 (dev ticket — fix flow) |

Every QL item is covered.

### 7.1–7.14 Per-item dev-ticket sketches

The QL-005..QL-018 items don't need architect-level depth — PM
already named the file, the proposed behaviour, and the priority. I
inventory each into a short sketch and **flag where any of them
interact with Refactors 1–3 or Features 1–2** so the PMgr can spin
dev tickets without re-reading the audit.

**QL-005 — `CircularProgressIndicator` sweep.** Four sites
(`app_router.dart:309`, `primary_button.dart:92`,
`log_weight_sheet.dart:482`, `editor_footer.dart:73`). Replace each
with a sized `Skeleton` or the `_SaveButtonSkeleton` pattern from
`log_entry_sheet.dart:722`. **Architect call: lift the
button-loader to a shared `client/lib/widgets/button_loading_bar.dart`** —
four sites is over the threshold; lock-step prevents drift. The
barcode resolver gets a `Skeleton` sized to the food-detail hero
(~140 px). No interaction with refactors.

**QL-006 — Bookmark icon.** `food_detail_screen.dart:256–262`. Delete.
~10 lines. No interaction.

**QL-007 — "Coming soon" SnackBars.** PM ruled "hide the row entirely"
for both. `profile_screen.dart:351` (Identity Edit) and
`profile_screen.dart:235` (Export data) are removed. ~30 lines. No
interaction.

**QL-008 — Autofocus.** `autofocus: true` on the first input of:
`LogEntrySheet` quantity (create-mode only), `LogWeightSheet`,
`CurrentWeightSheet`, `CustomFoodScreen` name (create-mode only).
`MyFoodsScreen` filter is **excluded** per PM. **Architect
interaction with Feature 1:** post-Feature-1, `HeightStepperSheet`
no longer has a `TextField` — drop it from the QL-008 site list when
height lands.

**QL-009 — "Today" pill.** A `Chip` widget in the date row, hidden
when `date == local-now-day`. Tap calls
`context.go(Routes.todayPath)`. Lives in `today_internals.dart` as
`TodayPill`. **Architect interaction with Feature 2:** consumes the
same `pathForDay` helper — mention in the ticket.

**QL-010 — Pending-sync row feedback.** Add a 200ms `dangerSoft`
tint to the rejected `_EntryRow` on rejected tap (an
`AnimatedContainer` with a setState toggle). Add the Semantics label
`"Still syncing — edit unavailable"`. Lives in
`widgets/meal_section.dart`, gated on a new `isPendingSync`
constructor flag passed from the day view via
`LogRepository.isPendingSync(entry.id)`.

**QL-011 — Date row in log-entry sheet.** New `DATE` row between
MEAL and NOTE, mirroring `log_weight_sheet.dart`'s `_DateRow`. Tap
opens `showDatePicker(firstDate: now − 365d, lastDate: now)`.
**Architect interaction with Feature 2:** the post-save routing
already reads `_date`, so an edit that changes the date routes to
the new date. Feature 2 needs no additional changes — name this in
the ticket so the dev agent doesn't go hunting.

**QL-012 — `SheetCloseButton`.** Pattern D cherry-pick. New widget at
`client/lib/widgets/sheet_close_button.dart` (44 px hit slop, 30 px
visible icon, `accentSoft`-on-hover, T-06 compliant). Audit replaces
ad-hoc closes in `log_entry_sheet.dart:676–684`,
`log_weight_sheet.dart`, `profile/widgets/editor_host.dart`. Add to
the architecture §3 component inventory (T-23). ~80 lines net.

**QL-013 — Empty-day pill.** In `day_view_compact.dart`, when every
meal subtotal is zero AND `date == local-now-day`, render an
accent-soft pill between the ring and the meal sections reading
`"Tap + to log your first food"`. Hidden on the first entry. The
check is `daySummary.byMeal.values.every((m) => m.kcal == 0)`. No
interaction.

**QL-014 — Onboarding "Start over".** Text button under the primary
CTA on step 3. Tap calls `notifier.reset()` (add the method) and
`context.go('/onboarding/1')`. **Architect interaction with
Refactor 1:** `OnboardingDraft.empty()` returns null for both
`weightUnit` and `heightUnit`. Mention.

**QL-015 — Profile editor dismiss tests.** Regression tests only —
no behaviour change. Five tests in
`client/test/features/profile/dismiss_without_save_test.dart`,
covering each editor. **Architect interaction with Feature 1:** the
simplified `HeightStepperSheet` needs its own test confirming
`HeightStepper` doesn't write on dispose — land alongside Feature 1,
not before.

**QL-016 — Goals weight-sweep verification.** A dev agent greps
`goal_active_card.dart`, `new_goal_dialog.dart`,
`edit_goal_sheet.dart` for `kg` literals to confirm the existing
weight-unit sweep landed. 30-minute check. Goals don't render
height; QL-001 doesn't touch the goal forms.

**QL-017 — Search empty-query flash.** Verify
`search_screen.dart`'s `_ResultsSection` `isQueryActive` ternary
covers the rebuild path on `_onQueryChanged('')`. One ternary or
one early return. ~5 lines.

**QL-018 — Custom-food save retry.** Track failed servings in the
existing `customFoodDraftProvider`; route to `/foods/$foodId/edit`
with the failed servings still in the draft. SnackBar reads `"Your
food saved, but N servings need a retry"` with a `Fix` affordance.
**Architect call on mechanism:** draft `pendingFailedServings`
field, not a query parameter, not a Hive box. The draft already
exists in memory; the field is the smallest delta. **Architect
interaction with T-24:** the right home is the food edit screen
(Case 2 — route-to-effect with failed servings visible), not
pop-to-source. Name the case in the save handler's dartdoc.

---

---

## 8. Tenant proposals

### 8.1 T-24 — Post-mutation navigation follows one of three patterns

Exact wording for `specs/flutter_ui_architecture.md` §8:

> **T-24 Post-mutation navigation follows one of three patterns.**
> After a save / mutation succeeds, the screen must land the user via
> exactly one of: (1) *pop-to-source* — `Navigator.pop()` returning
> to the screen that launched the editor (profile editors, log-weight
> sheet, goal editors); (2) *route-to-effect* — `context.go(target)`
> to a route that renders the mutation's effect, when that route is
> not the source (`LogEntrySheet` save → `/today/:consumedOn`,
> onboarding finish → `/today`); (3) *pop-with-payload* —
> `Navigator.pop(value)` returning the result so the source view can
> re-render against it (`CustomFoodScreen(existing:)` → updated
> `Food`). Each save handler's dartdoc names the case. New sheets are
> reviewed against this decision; the case is explicit, not inferred.
> Dialog-on-expanded sheets that use `context.go` must `pop()` the
> dialog first so the route change doesn't orphan a dialog frame.

That fits the existing 23 tenants' tone (T-14 routes-vs-sheets is the
nearest sibling; T-22 pending-sync-visible matches the per-case
prescription shape).

### 8.2 T-25 — Locale defaults are one chain, not per-axis

**Not proposed.** I considered it — "every display-unit axis's locale
default reads through `defaultUnitsForLocale`, not its own per-axis
locale function" — but the rule is implicit in Refactor 1: there's
only one function returning the record. A tenant would be ceremony.
The `@Deprecated` wrappers + the record's existence are the
enforcement; review catches a hypothetical new per-axis
`defaultEnergyUnitForLocale` and asks "why not extend the record?"
without needing a tenant to point at.

So: **one new tenant (T-24)** from this pack. Not two.

---

## 9. Test seams

The new and changed test surfaces. The PMgr notes these in dev
tickets so the right harness is in place.

**Locale defaults — record-shape override.** The existing
`defaultWeightUnitForLocale(countryCodeOverride:)` seam continues. Add
a sibling for the record: `defaultUnitsForLocale(countryCodeOverride:
'US')` returns `(weight: WeightUnit.lb, height: HeightUnit.ftIn)`. For
Riverpod tests:

```dart
ProviderContainer(overrides: <Override>[
  localeDefaultsProvider.overrideWithValue(
    (weight: WeightUnit.lb, height: HeightUnit.ftIn),
  ),
])
```

Both ergonomics ship; tests pick whichever fits.

**`heightUnitProvider` — fallback + read-from-me.** Two test patterns,
mirrors of the existing `weightUnitProvider` tests. (1) Loading
fallback — override `meProvider` with a never-resolving future,
override `localeDefaultsProvider`, expect the fallback value. (2)
Data path — override `meProvider` with `buildSeedUser(heightUnit:
HeightUnit.cm)`, expect that value. `buildSeedUser` gains a
`HeightUnit heightUnit = HeightUnit.cm` optional param.

**`HeightStepper` widget tests.** Same harness shape as
`WeightStepper`'s tests. Three flavours: cm mode (`+` bumps 1 cm,
clamp at `maxCm`); ftIn mode (inches `+` carries to feet at 12,
inches `-` borrows from feet at 0); round-trip (a `value:
Decimal.parse('175')` renders `"5 ft 9 in"` in ftIn mode and `"175
cm"` in cm mode). Fixture overrides `heightUnitProvider` via
`ProviderScope.overrides`.

**Log-save routing tests.** §6.6 spells the fixture. Four tests
(compact-create, compact-edit, expanded-create, expanded-edit), each
asserts `router.routerDelegate.currentConfiguration.fullPath` after
the save handler resolves. One helper file at
`client/test/features/log_entry/log_save_returns_home_test.dart`.

**Dismiss-without-save (QL-015).** Five tests at
`client/test/features/profile/dismiss_without_save_test.dart`. Each
opens an editor, manipulates the value, swipes-down/Escs to dismiss,
asserts `repo.updateCallCount == 0`.

**Invalidation contract — verification only.** Pattern C is
documentation. The verification is `grep -rn '@invalidates'
client/lib/repositories/` returning ≥ 14 hits. Not a hard test; a
CI-checkable lint candidate for v1.1 if a regression surfaces.

**`UnitsChooser` joined-sheet test.** New widget test confirming the
"editing one preference doesn't dismiss the other" rule (PM acceptance
§2.1): tap a weight option, expect the sheet stays open with the
height section unchanged; then tap a height option, expect the sheet
stays open with the new weight selection visible. A repo-call
assertion confirms two separate PATCHes fired.

---

## 10. Risks / open questions for PMgr

### 10.1 Should `userPreferencesProvider` be a single record?

**The architect picked per-axis providers (§2.1).** PM was opinionated
for unification; I rule against, with three reasons in §2.1. **PMgr —
confirm with the user the architect's call holds**, or revert to the
unified shape if the user wants the record shape for forward-looking
preferences beyond units (e.g., a future "first day of week" or
"timezone override"). My recommendation: ship per-axis for v1, revisit
if a non-unit preference axis lands. The migration is cheap in either
direction.

### 10.2 Should the joined `UnitsChooser` exist, or two separate choosers?

PM acceptance §2.1 named "editing one preference doesn't dismiss the
other." I interpreted this as "one sheet, two sections" (§5.8). The
alternative is "two sheets that can both be open at once" (impossible
on mobile; on expanded it's two popups). **My recommendation: one
sheet with two sections (the §5.8 design).** PMgr — confirm. If the
user prefers two separate flows on the Units row (perhaps with a sub-row
"Weight" and "Height" each tapping its own chooser), the chooser
widgets exist independently and the joined sheet just isn't built;
zero throwaway code.

### 10.3 Pre-backend window for `height_unit`

Same shape as the weight migration (`architect_log_edit_and_units.md`
§4.2). The client sweep can ship before the Rust migration **if the
server doesn't reject extra keys on PATCH /me.** PMgr — confirm the
server's tolerance: does the current Rust API ignore unknown JSON
keys on PATCH, or 400? If 400, the QL-001 client sweep must wait for
the migration. I expect "ignore" per the existing OpenAPI shape but
have not verified.

### 10.4 What if `meProvider` is loading during onboarding — fall back to
       per-axis locale defaults all at once?

This is the architect's concern more than the PM's. The
`onboardingHeightUnitProvider` and `onboardingWeightUnitProvider` both
read from the **draft** + the locale default. If the user is mid-
onboarding and the locale default flips mid-session (the platform
locale changed between launch and submit — rare but possible), the
two axes flip together because they read from the same
`localeDefaultsProvider`. That's correct — the user's "GB" locale
should default to ft_in+st atomically, not weight=st first and
height=cm because a previous session set one and not the other.

The `onboardingHeightUnitProvider` (§2.3) honours this: it reads from
the draft *or* the locale default, not both.

After onboarding's final PATCH, both axes land on `User` and the
`meProvider`-derived `heightUnitProvider` / `weightUnitProvider` take
over. The `localeDefaultsProvider` only matters for the fallback
window when `meProvider` is loading or errored.

### 10.5 The pluralisation of `defaultUnitsForLocale`'s return type

I picked `({WeightUnit weight, HeightUnit height})` — a record with
two named fields. Dart 3.0+ supports this natively (Decimal-style
records). The PMgr may want to confirm Dart 3 is fixed on the project
(`pubspec.yaml` says `dart: ^3.6`, so ✓). No new pub deps. Mention if
the user has a preference for a class type (`UnitDefaults` as a
sealed class) — I picked a record for ergonomics (zero boilerplate,
destructuring at call sites). The class wrapper is a five-line swap
if requested.

---

End of contract.
