# Frontend ticket ledger

Source of truth for every client-side ticket shipped or pending across
the Fulfilled project. The per-pack ticket docs (`dev_tickets_*.md`)
remain the detail source — each ticket body, dependency graph, and
failure protocol still lives there. This file gives a flat ID-ordered
view for hand-offs, status reads, and cross-pack searches.

For backend-team tickets (`BE-NNN`), see `backend_tickets_ledger.md`.
QL-110 in the QoL pack was a mis-classified backend ticket; it is
listed here only as a pointer ("moved to BE-004") and lives canonically
in the backend ledger.

## Pack overview

| Pack | Prefix | Range | Source spec | Theme |
|---|---|---|---|---|
| Overnight pool | T- | T-001..T-022 (T-017 merged into T-013) | dev_tickets.md | Post-screen-build polish: widget lifts, lint scripts, font bundling, accessibility, animations |
| Log edit + units | LU- | LU-001..LU-012 | dev_tickets_log_edit_and_units.md | Tap-to-edit log entries + user-selectable weight units (kg/lb/st) |
| Barcode scanner | SC- | SC-001..SC-005 | dev_tickets_barcode.md | Mobile camera barcode scan + web paste tightening |
| Quality of life | QL- | QL-101..QL-110 (QL-110 moved to backend → BE-004) | dev_tickets_qol.md | Coherent screen polish: post-mutation nav, height units, autofocus, empty-day affordances |
| UX review pack | UX- | UX-101..UX-113 | dev_tickets_ux_pack.md | Retention-shaped daily-use polish: cheaper ritual + visible signal (Theme A header, F1 copy-day, F2 chip strip, F4 sparkline scrub, F5 weight pre-fill, F10 streak pill) |

## Status legend

- `shipped` — committed to `main`; the referenced commit is the
  ticket's landing commit (or the wave bundle that carried it).
- `merged into <ID>` — bundled into another ticket; no standalone work.
- `deferred (v1.1)` — explicitly punted in the pack docs (`SC-004`).
- `pending (backend)` — see `backend_tickets_ledger.md`; the row stays
  here for navigation only and is not a client deliverable.

Status was derived from the `## Status snapshot` at the top of
`dev_tickets.md` and from the wave-bundle commit subjects on `main`
(`git log --oneline`). The per-pack docs were dispatched with each
ticket body still marked `pending`; that is a known doc-drift artifact
of the wave-merge workflow and does not reflect reality. The commit
columns below are the load-bearing signal.

## Tickets

### Overnight pool (T-)

| ID | Title | Status | Commit | Owner area |
|---|---|---|---|---|
| T-001 | Lift Tier-A shared widgets to `lib/widgets/` (ring + bars + meal) | shipped | `1fe3384` | `lib/widgets/` |
| T-002 | Lift `QuantityStepper`, `ServingList`, `ActivityOption` with API reconciliation | shipped | `1fe3384` | `lib/widgets/` |
| T-003 | Lift primitives (`EmptyState`, `Skeleton`, `NumberText`, `PrimaryButton`, `IconButton36`) | shipped | `7707446` | `lib/widgets/` |
| T-004 | Tenant doc updates: T-23 (package imports) + T-05 refinement | shipped | `40eecba` | `specs/flutter_ui_architecture.md` |
| T-005 | Lint scripts: no cross-feature widget imports + no hex outside tokens | shipped | `5c88f4d` | `tool/lint_*.dart` |
| T-006 | My Foods screen at `/foods/mine` | shipped | `c6d5bed` | `lib/features/my_foods/` |
| T-007 | `FoodRepository.addServing()` + custom-food save-flow wire-through | shipped | `7707446` | `lib/repositories/food_repository.dart` |
| T-008 | `GoalRepository.update()` + edit-goal-sheet fix | shipped | `40eecba` | `lib/repositories/goal_repository.dart` |
| T-009 | Lift `calories_estimate.dart` to `lib/domain/calories/` | shipped | `8d99c77` | `lib/domain/calories/` |
| T-010 | Rewire `edit_goal_sheet` to use `estimateCalories` | shipped | `f0ae6bd` | `lib/features/goals/edit_goal_sheet.dart` |
| T-011 | PM rulings on §10 items 2, 9, 10 — code edits | shipped | `c6d5bed` | mixed |
| T-012 | Inter font bundling | shipped | `40eecba` | `assets/fonts/`, `pubspec.yaml` |
| T-013 | Empty / error / loading sweep — fix the four `CircularProgressIndicator` violations | shipped | `5c88f4d` | mixed (absorbed T-017) |
| T-014 | Light theme polish: tokens, hex sweep, divider/border audit | shipped | `3235fe8` | `lib/theme/` |
| T-015 | Web keyboard shortcuts (scoped: `/`, `⌘K`, `n`, `g _`, `Esc`) | shipped | `8d99c77` | `lib/shell/keyboard_shortcuts.dart` |
| T-016 | Animations and transitions (ring, macros, FAB, sheets, routes) | shipped | `5c88f4d` | mixed |
| T-017 | Quick-add empty state on Today expanded right rail | merged into T-013 | `5c88f4d` | (folded into T-013) |
| T-018 | Web hover states audit + `Hoverable` helper | shipped | `f0ae6bd` | `lib/widgets/hoverable.dart` |
| T-019 | Auth-token notifier + sign-out wiring | shipped | `3235fe8` | `lib/auth/` |
| T-020 | Calories-burned provider for Today "Burned" row | shipped | `c6d5bed` | `lib/features/today/` |
| T-021 | Desktop "paste a barcode" affordance | shipped | `8d99c77` | `lib/features/foods_search/` |
| T-022 | Accessibility audit (Semantics + T-20 enforcement) | shipped | `3235fe8` | mixed |

### Log edit + units (LU-)

| ID | Title | Status | Commit | Owner area |
|---|---|---|---|---|
| LU-001 | `LogPatch` + `LogRepository.update` + outbox optimistic-id reconciliation | shipped | `81ff22e` (Wave 1) | `lib/repositories/log_repository.dart`, outbox |
| LU-002 | `LogEntrySheet existing:` param + edit-mode plumbing | shipped | `f935db8` (Wave 2) | `lib/features/log/log_entry_sheet.dart` |
| LU-003 | `formatWeight` + `parseWeightToKg` + locale default seam | shipped | `81ff22e` (Wave 1) | `lib/domain/weight/weight.dart` |
| LU-004 | `User.weightUnit` + `UserPatch` plumbing + `ProfileRepository.update` | shipped | `f935db8` (Wave 2) | `lib/models/user.dart`, profile repo |
| LU-005 | Day-view tap-to-edit wiring + pending-sync guard call site | shipped | `3d71c51` (Wave 3) | `lib/features/today/` |
| LU-006 | `weightUnitProvider` + `_onboardingWeightUnitProvider` | shipped | `3d71c51` (Wave 3) | `lib/providers/weight_unit_provider.dart` |
| LU-007 | `WeightStepper` widget | shipped | `1ac6495` (Wave 4) | `lib/widgets/weight_stepper.dart` |
| LU-008 | Onboarding step 2 — `WeightStepper` + unit chooser + draft write | shipped | `3470aa5` (Wave 5) | `lib/features/onboarding/` |
| LU-009 | Sweep all weight-rendering sites through `formatWeight` | shipped | `3470aa5` (Wave 5) | mixed (sweep) |
| LU-010 | Profile → Preferences → Units row interactivity + chooser widget | shipped | `92c74bf` (Wave 6) | `lib/features/profile/`, `UnitsChooser` |
| LU-011 | Delete `@Deprecated formatWeightKg` + final lint check | shipped | `3e832fa` (Wave 7) | `lib/domain/weight/weight.dart` |
| LU-012 | Documentation pass — architecture & PM addenda | shipped | `3e832fa` (Wave 7) | `specs/` (doc-only) |

### Barcode scanner (SC-)

| ID | Title | Status | Commit | Owner area |
|---|---|---|---|---|
| SC-001 | `ScanScreen` skeleton + opener + routing wire + native config | shipped | `f5bf7b4` (Wave 1) | `lib/features/scan/`, iOS/Android native config |
| SC-002 | `ViewfinderOverlay` painter + iPad-landscape cap | shipped | `7999c1c` (Wave 2) | `lib/features/scan/viewfinder_overlay.dart` |
| SC-003 | Torch button + no-detect hint + `PermissionDenied` empty state | shipped | `7999c1c` (Wave 2) | `lib/features/scan/` |
| SC-004 | Dedicated manual-entry modal sheet | deferred (v1.1) | — | `lib/features/scan/manual_entry_sheet.dart` (not yet created) |
| SC-005 | `PrimaryButton.dense` size variant | shipped | `f5bf7b4` (Wave 1) | `lib/widgets/primary_button.dart` |

### Quality of life (QL-)

| ID | Title | Status | Commit | Owner area |
|---|---|---|---|---|
| QL-101 | T-24 codification + post-mutation nav doc pass + `@invalidates` repository docs | shipped | `9fdb695` (Wave 1) | `specs/flutter_ui_architecture.md`, repos (doc + annotations) |
| QL-102 | `defaultUnitsForLocale` record + `localeDefaultsProvider` + `HeightUnit` enum | shipped | `9fdb695` (Wave 1) | `lib/domain/units/`, `lib/providers/` |
| QL-103 | `length.dart` seam + `HeightStepper` widget + carry-edge tests | shipped | `b0b4a91` (Wave 2) | `lib/domain/length/`, `lib/widgets/height_stepper.dart` |
| QL-104 | Height feature sweep — onboarding step 2, profile screen, `HeightStepperSheet`, `UnitsChooser` | shipped | `2caa3bd` (Wave 3a) | `lib/features/onboarding/`, `lib/features/profile/` |
| QL-105 | `LogEntrySheet` save → `context.go(pathForDay(_date))` + `pathForDay` helper | shipped | `b0b4a91` (Wave 2) | `lib/features/log/log_entry_sheet.dart`, router |
| QL-106 | "Today" pill + `CircularProgressIndicator` sweep + bookmark/Coming-soon row cuts | shipped | `24b654b` (Wave 3b) | mixed |
| QL-107 | Autofocus pass + DATE row in `LogEntrySheet` | shipped | `24b654b` (Wave 3b) | `lib/features/log/log_entry_sheet.dart` |
| QL-108 | Empty-day pill + pending-sync row feedback + onboarding "Start over" | shipped | `9bdf08d` (Wave 3c) | `lib/features/today/`, onboarding |
| QL-109 | Search empty-query flash + goals weight-sweep verify + dismiss-without-save regression tests + custom-food retry flow | shipped | `9bdf08d` (Wave 3c) | mixed |
| QL-110 | `users.height_unit` migration | moved to BE-004 in backend ledger | — | (backend; not a client ticket) |

### UX review pack (UX-)

| ID | Title | Status | Commit | Owner area |
|---|---|---|---|---|
| UX-101 | Lift `QuickAddChips` to `lib/widgets/` (T-23) | shipped | `e6288ee` (Wave 1a) | `lib/widgets/quick_add_chips.dart` |
| UX-102 | Theme A PR 2 — avatar cut + bolt → FAB long-press menu | shipped | `e6288ee` (Wave 1a) | `lib/features/today/`, shell header |
| UX-103 | Theme A PR 3 — `DaySwipeWrap` horizontal swipe gesture | shipped | `90f2277` (Wave 1b) | `lib/features/today/day_swipe_wrap.dart` |
| UX-104 | Theme A PR 4 — `DatePill` + chevron removal | shipped | `f9c1983` (Wave 2a) | `lib/features/today/`, `lib/widgets/date_pill.dart` |
| UX-105 | F1 — `LogRepository.copyDay` + `CopyDaySheet` + preview provider | shipped | `e6288ee` (Wave 1a) | `lib/repositories/log_repository.dart`, `lib/features/copy_day/` |
| UX-106 | F1 — `MealSection` overflow + empty-day "Copy from another day" | shipped | `f9c1983` (Wave 2a) | `lib/features/today/meal_section.dart` |
| UX-107 | F2 — `QuickAddChips.compact` flag + Today compact mount | shipped | `ded73e1` (Wave 2b) | `lib/widgets/quick_add_chips.dart`, `lib/features/today/` |
| UX-108 | F4 — Sparkline scrub-to-read gesture | shipped | `e6288ee` (Wave 1a) | `lib/widgets/sparkline.dart` |
| UX-109 | F5 — Log Weight pre-fill from most-recent history | shipped | `90f2277` (Wave 1b) | `lib/features/weight/log_weight_sheet.dart` |
| UX-110 | F10 — `weeklyLogDaysProvider` + `_WeekProgressPill` | shipped | `f9c1983` (Wave 2a) | `lib/providers/weekly_log_days_provider.dart`, `lib/features/today/` |
| UX-111 | Theme C — dead-affordance sweep | shipped | `90f2277` (Wave 1b) | mixed |
| UX-112 | Cross-cutting polish bundle — Theme D + E + a11y + Goals + (dev) tag | shipped | `90f2277` (Wave 1b) | mixed |
| UX-113 | T-12 clarifying rider — FAB long-press menu (doc only) | shipped | `f9c1983` (Wave 2a) | `specs/flutter_ui_architecture.md` (doc-only) |

## Totals

- **T- pack**: 22 tickets numbered; T-017 merged into T-013; 21 shipped, 1 merged.
- **LU- pack**: 12 tickets; all 12 shipped.
- **SC- pack**: 5 tickets; 4 shipped, 1 deferred (SC-004).
- **QL- pack**: 10 tickets; 9 shipped, 1 (QL-110) lifted to backend ledger as BE-004.
- **UX- pack**: 13 tickets; all 13 shipped.
- **Grand total**: 62 client-pack ticket slots → 59 shipped, 1 merged (T-017), 1 deferred (SC-004), 1 reclassified as backend (QL-110).

## Quick reference — backend hand-off pointers

| Client pack reference | Canonical backend ID |
|---|---|
| LU pack BE-001 (weight_unit) | BE-001 |
| Barcode pack BE-002 (OFF live fallback) | BE-002 |
| Barcode pack BE-003 (EAN-13 normalization) | BE-003 |
| QoL pack QL-110 (height_unit) | BE-004 |
| UX pack BE-002 (weekly-logging endpoint) | BE-005 |
| UX pack BE-003 (barcode scan history) | BE-006 |
| UX pack BE-004 (goal achievement status) | BE-007 |

The collisions on `BE-002`/`BE-003`/`BE-004` between the barcode pack
and the UX pack are resolved in `backend_tickets_ledger.md` by
sequential renumbering in chronological pack order (LU → barcode → QoL
→ UX). Legacy references in the per-pack docs are preserved as-is with
a pointer line to the canonical ledger.
