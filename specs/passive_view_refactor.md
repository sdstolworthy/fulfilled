# Passive-view refactor backlog

Track the work to lift Riverpod reads out of leaf widgets and into
their parent containers. Rule lives in `specs/testing_guide.md` §4.4;
worked example at commit `a189080` (weight feature).

Done when every `ConsumerWidget` / `ConsumerStatefulWidget` under
`lib/features/*/widgets/` and `lib/widgets/` is gone — leaves are
`StatelessWidget` / `StatefulWidget` taking constructor params, and
parent containers do the `ref.watch` / `ref.listen` / `AsyncValue.when`
work.

Delete sections from this file as they ship. When the file is empty,
delete the file.

---

## Pattern (copy from the weight example)

```dart
// Before — leaf reaches into Riverpod
class MyCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dataAsync = ref.watch(myProvider);
    return dataAsync.when(
      data: (d) => /* render */,
      loading: () => const _Skeleton(),
      error: (...) => /* error UI */,
    );
  }
}

// After — leaf is pure; siblings cover loading/error
class MyCard extends StatelessWidget {
  const MyCard({super.key, required this.data});
  final Data data;
  @override
  Widget build(BuildContext context) { /* render */ }
}
class MyCardSkeleton extends StatelessWidget { ... }
class MyCardError extends StatelessWidget { /* with onRetry param */ }

// Container picks the right widget from the AsyncValue
class MyScreen extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(myProvider);
    return async.when(
      data: (d) => MyCard(data: d),
      loading: () => const MyCardSkeleton(),
      error: (_, __) => MyCardError(onRetry: () => ref.invalidate(myProvider)),
    );
  }
}
```

Reference commit: `a189080` — see `weight_summary_card.dart`,
`weight_history_list.dart`, `weight_sparkline.dart`,
`weight_screen.dart`.

---

## Out of scope (containers, not leaves)

These are containers themselves — sheets, dialogs, and screen-level
widgets are the right place for Riverpod reads. Don't touch:

- `*_screen.dart` files
- `*_sheet.dart` files (log_weight_sheet, current_weight_sheet,
  height_stepper_sheet, edit_goal_sheet, log_entry_sheet,
  quick_add_sheet, copy_day_sheet)
- `*_dialog.dart` files (new_goal_dialog)
- `day_view_compact.dart`, `day_view_expanded.dart` (top-level
  views inside today_screen — themselves containers)

---

## Worklist

Format: `widget file → container that will own its reads → notes`.

### Trivial (one read, one move)

- [ ] **`features/profile/widgets/server_url_row.dart`** → `profile_screen.dart`
  - Reads `baseUrlProvider` for the URL string. Container reads,
    passes `url: String?` as a param. Smallest possible split.

- [ ] **`features/search/widgets/search_field.dart`** → `search_screen.dart`
  - Reads `searchFieldFocusNodeProvider`. Pass the `FocusNode` as a
    constructor param; container reads the provider.

- [ ] **`features/log_entry/widgets/quick_multiplier_chips.dart`** → `log_entry_sheet.dart`
  - Reads `quantityProvider`, calls `quantityProvider.notifier.state =`
    in tap handlers. Container passes `currentQuantity: int` and
    `onSelected: ValueChanged<int>`.

- [ ] **`features/goals/widgets/goal_active_card.dart`** → `goals_screen.dart`
  - Reads `effectiveActiveGoalTargetsProvider`. Pass the resolved
    targets as a param.

### Small (a few reads, action callbacks)

- [ ] **`features/profile/widgets/activity_level_picker.dart`** → `profile_screen.dart`
- [ ] **`features/profile/widgets/sex_picker.dart`** → `profile_screen.dart`
- [ ] **`features/profile/widgets/height_unit_chooser.dart`** → `profile_screen.dart`
- [ ] **`features/profile/widgets/weight_unit_chooser.dart`** → `profile_screen.dart`
- [ ] **`features/profile/widgets/units_chooser.dart`** → `profile_screen.dart`
  - All five pickers share the same shape: no render-time reads;
    only `ref.read(profileRepositoryProvider).updateMe(...) +
    ref.invalidate(meProvider)` in tap handlers. Lift the repo write
    + invalidation up; pass `onChanged: ValueChanged<T>` to the leaf.
    The leaf renders the current selection from a `current: T`
    constructor param.

- [ ] **`features/goals/widgets/goal_editor_body.dart`** → `new_goal_dialog.dart` / `edit_goal_sheet.dart`
  - Reads `weightUnitProvider` and `currentWeightKgProvider`. The
    two containers that mount this body should resolve both before
    constructing it; pass `unit: WeightUnit` and
    `currentKg: Decimal?`.

- [ ] **`widgets/ring_summary_card.dart`** → wherever it's mounted (likely `today_screen.dart`)
  - Reads `caloriesBurnedTodayProvider` (async) and
    `weeklyLogDaysProvider` (async). Container resolves both; leaf
    takes `burnedKcal: int` and `weeklyLogDays: int`. Add sibling
    skeleton for the loading case.

- [ ] **`widgets/keyboard_shortcuts.dart`** → `today_screen.dart` (or wherever it mounts)
  - Only reads in shortcut handlers, not at render. Pass the
    focusNode and a `onLogShortcut: VoidCallback` (or similar) down.
    Audit the actual call sites — this widget may be mounted from
    multiple places.

### Medium (form widgets with multiple reads + multiple callbacks)

- [ ] **`features/custom_food/widgets/basics_section.dart`** → `custom_food_screen.dart`
- [ ] **`features/custom_food/widgets/servings_section.dart`** → `custom_food_screen.dart`
  - Both read `customFoodDraftProvider` and write via its notifier.
    Container watches the draft; passes a slice of it (`draft.name`,
    `draft.brand`, `draft.servings`, …) plus the relevant
    `onXxxChanged` callbacks. Keep the callback surface tight —
    one per field, not a passed-through notifier reference.

- [ ] **`features/onboarding/widgets/step_2_about_you.dart`** → `onboarding_screen.dart`
- [ ] **`features/onboarding/widgets/step_3_goal.dart`** → `onboarding_screen.dart`
  - Same shape as the custom-food sections: watch
    `onboardingDraftProvider` + the two unit providers in the
    container; pass field values + onChanged callbacks down.

### Larger (login form — five tightly-coupled leaves)

The five login widgets all read selectors off `loginControllerProvider`
(submitting flag, url, urlError, credentialsError, endpointMissing, …)
and call methods on the controller in handlers. The most pragmatic
shape is for `login_screen.dart` to watch the controller once,
extract a `_LoginViewModel`-shaped record of fields + callbacks, and
pass slices to each widget.

- [ ] **`features/login/widgets/server_url_field.dart`** → `login_screen.dart`
  - Takes `initialUrl: String`, `submitting: bool`,
    `urlError: String?`, `onUrlChanged: ValueChanged<String>`.

- [ ] **`features/login/widgets/credentials_form.dart`** → `login_screen.dart`
  - Takes `initialUsername: String`, `submitting: bool`,
    `credentialsError: String?`, callbacks for username/password
    changes.

- [ ] **`features/login/widgets/login_button.dart`** → `login_screen.dart`
  - Takes `submitting: bool`, `url: String`, `onSubmit: VoidCallback`.

- [ ] **`features/login/widgets/oidc_button.dart`** → `login_screen.dart`
  - Takes `apiBase: String?`, `onOidcTap: VoidCallback`.

- [ ] **`features/login/widgets/paste_jwt_disclosure.dart`** → `login_screen.dart`
  - Takes `endpointMissing: bool`, `onPasteJwt: VoidCallback` (or
    however the controller method is currently invoked).

- [ ] **`oidc_callback_screen.dart`** — flagged separately in
  `specs/io_deps_audit.md` as duplicating the `runOidcExchange` seam.
  Fold that fix into the login refactor (one PR per parent container
  is cleaner than splitting a single screen across two).

---

## Tests touching these widgets

Each leaf has at least one test file. Most are `@Skip`-quarantined
(see `specs/testing_guide.md` §2 — 64 of 138 test files are out).
**Don't un-skip during this refactor.** Two acceptable moves:

1. **Update the constructor calls** so the test still type-checks
   (analyze must stay green). The body stays `@Skip`-marked. This
   is what the weight refactor did for `sparkline_scrub_test.dart`.

2. **Delete the quarantined test entirely**, with a note in the
   commit message that the rebuild will land separately. Acceptable
   only if you're confident no in-flight branch is rebaselining it.

The non-quarantined tests under these directories should keep
passing — that's the green-light check before each commit. Run
`flutter test test/features/<feature>/` plus
`flutter analyze --fatal-infos --fatal-warnings` per commit.

---

## Suggested commit cadence

One feature directory per commit. Title format:
`refactor(<feature>): split leaves into pure presentation + skeletons`.
Mirrors the weight commit. Keeps blast radius tight and each commit
self-contained for review or revert.

Optional ordering — fastest to slowest:

1. `server_url_row` (trivial, 5 min)
2. `search_field` (trivial)
3. `goal_active_card` (small read, no callbacks)
4. profile pickers (all in one commit — same shape)
5. `quick_multiplier_chips`
6. `ring_summary_card` + `keyboard_shortcuts`
7. `goal_editor_body`
8. onboarding widgets
9. custom-food sections
10. login widgets + oidc_callback_screen fix
