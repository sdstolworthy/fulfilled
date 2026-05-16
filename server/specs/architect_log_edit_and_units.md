# Architect — Edit a Log Entry + User-Selectable Weight Units

Implementation contract for `specs/pm_log_edit_and_units.md`. The PM has
ruled scope, direction, and user stories; this doc translates that into
file-level seams, function signatures, repository surfaces, provider
invalidation lists, and acceptance criteria the technical program
manager can carve into developer tickets without re-asking.

The two prior decision docs are the tiebreakers above this one:
`specs/flutter_ui_architecture.md` (the 23 tenants, especially T-15,
T-17, T-21, T-22, T-23) and `specs/pm_decisions_flutter_ui.md` (the
Display Units Principle). Where this doc names a behaviour and a
prior doc disagrees, the prior doc wins.

I read every file PM inventoried in §4 of their direction doc, plus the
seams those files actually touch in the current shipped client. The
column counts in the §3.13 inventory are real (verified by `grep`s
recorded in the source-code spelunking that produced this plan). The
plan compiles in my head; I would expect the tickets that come out of
this to compile on the agent's machine without surprise.

---

## 1. Architectural overview

**Feature A — Edit a log entry.** The day-view `_EntryRow.onTap` (in
`lib/widgets/meal_section.dart`) currently no-ops on the consumer side
— `MealSection.onEntryTap` is declared but `day_view_compact.dart` and
`day_view_expanded.dart` don't pass a handler. We wire both screens to
call `showLogEntrySheet(context, food: ..., existing: entry)`. The
existing sheet (`lib/features/log_entry/log_entry_sheet.dart`) grows an
`existing: LogEntry?` parameter; when non-null it pre-seeds the form
and dispatches to a new `LogRepository.update(id, LogPatch)` instead of
`create(LogCreate)`. The repository hits `PATCH /log/{id}` (already on
the wire). The shell decision (`showModalBottomSheet` on compact,
`Dialog` on medium/expanded) is unchanged per T-15 — edit-mode is a
state of screen 04, not a sibling screen. Pending-sync rows are
explicitly non-editable; tapping shows a SnackBar.

**Feature B — Weight unit preference.** A new `WeightUnit { kg, lb, st }`
enum lives on `User`; the wire field is `weight_unit` (new, additive,
optional from the client's perspective). Display goes through one new
seam, `formatWeight(Decimal kg, WeightUnit unit)` in
`lib/domain/units/weight.dart`. Existing `formatWeightKg` becomes a
thin internal helper; the 17 call sites identified migrate to
`formatWeight(value, ref.watch(weightUnitProvider))`. Input parsing
mirrors the seam — one new `parseWeightToKg(String, WeightUnit)`
helper, used by a new `WeightStepper` widget wrapping the lifted
`QuantityStepper`. Locale default (`US → lb`, `GB → st`, else `kg`,
plus the PM-named non-metric carve-outs) fires once at first
onboarding submit; after that the server is canonical.

---

## 2. Feature A — Edit a log entry (deep dive)

### 2.1 Row tap behaviour

**Today.** `lib/widgets/meal_section.dart:50` declares
`final void Function(LogEntry entry)? onEntryTap` on `MealSection` and
the `_EntryRow` inside (`meal_section.dart:75`) already conditions its
`InkWell.onTap` on that callback. The callback is **never passed in**
today:

- `day_view_compact.dart:232` constructs `MealSection(subtotal:,
  entries:, onAddTap: ...)` with no `onEntryTap` argument.
- `day_view_expanded.dart:306` does the same.

So the row's `InkWell` falls through to `onTap: null` — visually
hoverable on web but unactivatable. The PM correctly identified this
as "the tap is a no-op today."

**After.** Both screens pass `onEntryTap: (entry) => _onEntryTap(ref,
context, entry)`. The handler:

1. Look up the pending-sync state. On compact, read
   `ref.watch(logOutboxProvider).entries` and check whether any
   `OutboxEntryRecord` whose optimistic id matches `entry.id` has
   status `pending` or `failed`. On medium/expanded the outbox doesn't
   exist (PM Risk 6 / T-22 are compact-only), so this check is a noop
   — `LogRepository.isPendingSync` returns `false`.
2. If pending or failed, show a `SnackBar` reading `"Still syncing —
   edit when sync finishes"` and return. Don't open the sheet. This is
   the T-22-inherited rule the PM explicitly named in §2 "Conflict +
   concurrency."
3. Otherwise, fetch the food via `ref.read(foodDetailProvider(entry.foodId))`
   (it's an `AsyncValue<Food>` — await its `.future` getter). On error
   show a SnackBar `"Couldn't load food. Try again."` and abort.
4. Call `showLogEntrySheet(context, food: food, existing: entry)`.
5. On a non-null return, do nothing further — the sheet itself handled
   provider invalidation. On null (dismissed), do nothing.

The pending-sync guard owner is **the call site, not `MealSection`**.
`MealSection` stays form-factor-blind per T-15 and feature-blind per
T-23. The row gets the same `InkWell.onTap` it has today; the
*handler* knows about pending-sync. This keeps `MealSection` shipping
unchanged from a widget contract standpoint.

The `Semantics` label on `_EntryRow` (`meal_section.dart` around
line 162; today it's not explicit, the InkWell inherits) gains an
`button: true, label: '${entry.foodName}, ${entry.servingName ?? ''},
${formatKcal(entry.kcal)} kilocalories, edit'`. Add this to the
`_EntryRow` build method behind a `Semantics(...)` wrapper so screen
readers announce "edit" — T-20.

### 2.2 `showLogEntrySheet` public API

The exact new signature, replacing the current one
(`log_entry_sheet.dart:46`):

```dart
/// Open the log-entry sheet/dialog.
///
/// - `food` is required; in edit mode it is fetched via
///   `foodDetailProvider(existing.foodId)` by the caller.
/// - `defaultMeal` only applies in **create mode**. Ignored if
///   `existing != null`.
/// - `existing == null` → create mode. Today's behaviour. Outbox path
///   on compact, direct `LogRepository.create` on medium/expanded.
/// - `existing != null` → edit mode. Title appends "(editing)" in
///   `ink2` `meta` style; CTA reads "Save changes"; on submit calls
///   `LogRepository.update(existing.id, LogPatch)` on **all** form
///   factors. Edits are not queued (see §2.6).
///
/// Returns the resulting `LogEntry?` — `null` on dismiss. In edit mode
/// the returned entry is the server response (or, on compact create,
/// the optimistic entry; create-mode behaviour is unchanged).
Future<LogEntry?> showLogEntrySheet(
  BuildContext context, {
  required Food food,
  Meal? defaultMeal,
  LogEntry? existing,
});
```

Three implementation rules:

- `defaultMeal` and `existing` are **mutually exclusive in spirit** but
  not enforced; if both are passed, `existing.meal` wins (`defaultMeal`
  is ignored in edit mode). The PMgr's tickets should call out the
  ignored case so dev agents don't waste a half-hour debugging.
- The wrapping `Dialog`/`showModalBottomSheet` shell is **identical**
  to create mode. Width 480 on dialog. Snap points `[0.5, 0.88]` on
  sheet. The header changes (see 2.3) and the footer button label
  changes ("Save changes" vs "Save to log"); nothing else moves.
- The `quantityProvider` (defined at `log_entry_sheet.dart:34`)
  override seed becomes `existing?.quantity ?? Decimal.one`. The
  `ProviderScope` override list (`log_entry_sheet.dart:63`) is
  extended; no new provider is introduced.

### 2.3 `LogEntrySheetBody` edit-mode plumbing

`LogEntrySheetBody` (the inner widget at `log_entry_sheet.dart:177`)
gets one new constructor field:

```dart
const LogEntrySheetBody({
  super.key,
  required this.food,
  required this.onSubmit,
  this.existing,            // NEW
  this.defaultMeal,
  this.scrollController,
  this.showGrabber = true,
});

final LogEntry? existing;   // NEW
```

`bool get _isEditing => widget.existing != null;` is the branching
predicate the rest of the widget reads.

**`initState` pre-seeding.** Today (lines 204–214) it picks the food's
default serving + `mealForLocalTime(DateTime.now())` + today's date.
In edit mode the seed is the entry:

```dart
@override
void initState() {
  super.initState();
  final ex = widget.existing;
  _meal = ex?.meal ?? widget.defaultMeal ?? mealForLocalTime(DateTime.now());
  _serving = widget.food.servings.firstWhere(
    (s) => s.id == (ex?.servingId ?? widget.food.defaultServingId),
    orElse: () => widget.food.servings.first,
  );
  final seedDate = ex?.consumedOn ?? DateTime.now();
  _date = DateTime(seedDate.year, seedDate.month, seedDate.day);
  _noteCtrl.text = ex?.note ?? '';
}
```

The `quantityProvider` override (in `showLogEntrySheet`'s contents
builder) already supplies the quantity seed, so the body doesn't read
it directly.

**Header.** `_Header` (`log_entry_sheet.dart:440`) currently renders
`brand · source` + `food.name`. In edit mode append a small "(editing)"
suffix in `text.meta` `ink2` style on the title line — or, equivalently,
add a `_HeaderSubtitle` text reading `Editing entry · MMM d` (the
entry's `consumedOn`). I lean toward the simpler **append a `Editing`
chip-style label** below the eyebrow: it reads as a state, not a
question. Either way the implementation is one extra `Text` in
`_Header` gated on a new `bool editing` prop passed from
`LogEntrySheetBody`. No new tokens; no `IconButton36`.

**Footer.** `_Footer` (`log_entry_sheet.dart:668`) hardcodes
`'Save to log'`. Promote the label to a constructor param:

```dart
const _Footer({
  required this.submitting,
  required this.onSave,
  required this.label,    // NEW — "Save to log" or "Save changes"
});
```

`LogEntrySheetBody.build` passes `label: _isEditing ? 'Save changes' :
'Save to log'`.

**Save button enablement.** Disable the CTA when in edit mode and the
form matches the pre-seed (`_isEditing && _isUnchanged()`). `_isUnchanged`
compares (quantity, serving id, meal, date, note) against `widget.existing`.
This is one `==` test per field; the predicate lives on the body. It
keeps the user from firing a no-op PATCH and prevents the "I tapped
Save but nothing happened" feeling. Per PM acceptance criteria.

The "submit" handler `_onSavePressed` (`log_entry_sheet.dart:235`) gets
a top-level `if (_isEditing) _onEditPressed() else _onCreatePressed()`
split. Same outer structure (`setState(_submitting = true)`, the
`widget.onSubmit` test seam, etc.). The two branches are:

- `_onCreatePressed`: today's logic, unchanged.
- `_onEditPressed`: see §2.5 below.

### 2.4 `LogRepository.update` shape

Add to `lib/repositories/log_repository.dart`:

```dart
/// Patch an existing log entry. Mirrors `PATCH /log/{id}`.
///
/// - `food_id` is immutable server-side (sending one returns 400).
///   The signature does not accept one. Changing food is delete +
///   create by design.
/// - Optional fields: when `null`, the field is omitted from the
///   PATCH body (= "leave unchanged"). A `note: null` cannot be
///   distinguished from "leave note alone" through this API — we
///   add a dedicated `clearNote: true` flag if a future ticket
///   needs to clear the note. v1 of edit-mode does not clear notes.
/// - Mock implementation: locate the entry by id, recompute the
///   nutrition snapshot from (food + new serving + new quantity) the
///   same way `create` does, update timestamps, return the new entry.
///   The mock food row is looked up via the existing `FoodRepository`
///   the way `create` does — same `FoodNotFoundError` on miss.
/// - Real implementation (when wire lands): `PATCH /log/{id}` with
///   `LogPatch.toJson()`. On 200 returns `LogEntry.fromJson(body)`.
///   Failure throws — caller surfaces SnackBar (T-11).
Future<LogEntry> update(String entryId, LogPatch patch);
```

And a sibling helper used by the day-view tap guard:

```dart
/// Returns `true` if the entry's id matches an outbox entry that is
/// `pending` or `failed` — i.e. not yet server-acked. Always `false`
/// on medium/expanded (no outbox).
///
/// Implementation reads `LogOutboxNotifier.state` via a private
/// helper container or accepts the outbox state as a parameter — see
/// §2.6 for the placement choice.
bool isPendingSync(String entryId);
```

`LogPatch` is a new outgoing payload class in
`lib/domain/log_entry.dart`, sibling to `LogCreate`:

```dart
class LogPatch {
  const LogPatch({
    this.servingId,
    this.consumedOn,
    this.meal,
    this.quantity,
    this.note,
    this.clearNote = false,
  });

  final String? servingId;
  final DateTime? consumedOn;
  final Meal? meal;
  final Decimal? quantity;
  final String? note;
  final bool clearNote;   // true → emit `"note": null`; else omit.

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      if (servingId != null) 'serving_id': servingId,
      if (consumedOn != null) 'consumed_on': _isoDate(consumedOn!),
      if (meal != null) 'meal': meal!.wire,
      if (quantity != null) 'quantity': quantity.toString(),
      if (note != null) 'note': note,
      if (clearNote && note == null) 'note': null,
    };
    return m;
  }
}
```

Per the OpenAPI: omit unchanged fields, send `note: null` to clear,
never send `food_id`. The class does this contractually. The PMgr
should note `clearNote` is *not* exposed in the v1 UI — the note
field today either has text or is empty-string-trimmed to `null`. We
emit `clearNote: true` when the user blanked a previously-non-null
note. Code path:

```dart
final originalNote = widget.existing?.note;
final newNote = _noteCtrl.text.trim();
final hasNote = newNote.isNotEmpty;
return LogPatch(
  servingId: _serving.id != widget.existing?.servingId ? _serving.id : null,
  // ...
  note: hasNote ? newNote : null,
  clearNote: !hasNote && (originalNote != null && originalNote.isNotEmpty),
);
```

The patch is sparse — we only send fields the user actually changed,
to keep the wire small and the day-view diff narrow.

### 2.5 The submit branch (`_onEditPressed`)

Per PM "Backend implications — there is an endpoint" and "Conflict +
concurrency" sections. Edits do **not** queue. The outbox is
create-only.

```dart
Future<void> _onEditPressed() async {
  final patch = _buildLogPatch();
  if (patch.isEmpty) return;            // no-op guard

  final messenger = ScaffoldMessenger.maybeOf(context);
  final repo = ref.read(logRepositoryProvider);
  final originalDate = widget.existing!.consumedOn;
  final newDate = _date;

  // Optimistic apply on medium/expanded — see §2.7.
  // On compact we do NOT apply optimistically because the day-view's
  // current optimistic model targets the outbox, and edits aren't
  // queued. Compact runs synchronous-from-the-user's-perspective:
  // sheet stays open with a button skeleton (T-013) until the PATCH
  // returns. ~300 ms on a healthy connection.

  try {
    final updated = await repo.update(widget.existing!.id, patch);
    if (!mounted) return;

    // Invalidate both dates if consumed_on moved.
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
  } catch (e) {
    if (!mounted) return;
    setState(() => _submitting = false);
    messenger?.showSnackBar(
      SnackBar(content: Text('Could not save changes: $e')),
    );
  }
}
```

`_sameDay` is a one-line helper that lives in `log_entry_sheet.dart`
(this file already has private helpers — keep this one private).

### 2.6 The pending-sync guard — placement

The PMgr will ask: "Where does the `isPendingSync(entryId)` check
actually live in the code?" Three options, ranked:

1. **On `LogRepository`** (recommended). The repository takes a
   `LogOutboxNotifier` as an optional construction parameter (mobile
   only — the existing `repositoryProviders` set the outbox to `null`
   for desktop). `isPendingSync` reads the outbox state.
2. On a new `pendingSyncProvider(entryId)`. Reader-side ergonomics
   are slightly better (no method on the repo), but it duplicates
   knowledge between the day-view's row tap handler and a future
   "pending badge" widget that already reads the outbox provider
   directly.
3. Inline in the day-view tap handler. Rejected — the rule belongs to
   the log domain, not the screen.

Pick (1). The compact-only check is implemented as:

```dart
class LogRepository {
  LogRepository({
    required ApiClient api,
    required FoodRepository foodRepository,
    required GoalRepository goalRepository,
    LogOutboxNotifier? outbox,    // NEW, nullable
  }) : _outbox = outbox, /* ... */;

  final LogOutboxNotifier? _outbox;

  bool isPendingSync(String entryId) {
    final ox = _outbox;
    if (ox == null) return false;     // medium/expanded
    return ox.state.entries.any((e) =>
      e.optimisticId == entryId &&
      (e.status == OutboxEntryStatus.pending ||
       e.status == OutboxEntryStatus.failed));
  }
}
```

The wiring (in `repository_providers.dart`) reads:

```dart
final logRepositoryProvider = Provider<LogRepository>((ref) {
  final ff = ref.read(formFactorProvider);    // already exists
  return LogRepository(
    api: ref.watch(apiClientProvider),
    foodRepository: ref.watch(foodRepositoryProvider),
    goalRepository: ref.watch(goalRepositoryProvider),
    outbox: ff.isCompact ? ref.watch(logOutboxProvider.notifier) : null,
  );
});
```

`OutboxEntryRecord` in `outbox_entry.dart` will need an `optimisticId`
field if it doesn't already store one — the optimistic id pattern
(`'optimistic_${microsecondsSinceEpoch}'`) comes from
`log_entry_sheet.dart:321` and is currently *invented* on the spot for
the dialog's return value. The outbox stores its own client UUID per
PM Risk 6. We need to make the two reconcile, or document that the
optimistic id is the same as the outbox key. **PMgr — flag a
sub-ticket**: "Unify optimistic LogEntry id with outbox entry key so
the day-view row can correlate the two." This is a 30-minute change
but it isn't free; without it `isPendingSync` has no key to look
against.

### 2.7 Optimistic update — yes/no

The PM punted; I rule **no optimistic update on edits**. Reasons:

- The compact path is already non-optimistic for edits because edits
  don't queue (PM Risk 6 ruling) and the create-path's optimism is
  exclusively the outbox's gift.
- On medium/expanded the typical roundtrip is well under 300 ms; the
  button-skeleton in `_SaveButtonSkeleton`
  (`log_entry_sheet.dart:722`) communicates "in flight" without a
  spinner, satisfying T-08 / T-13.
- Adding optimistic edit-apply on medium/expanded means writing a
  rollback path for an edge case (PATCH fails) that is rare on
  desktop. Tests for the rollback are non-trivial; the buy is one
  frame of perceived latency on the happy path.

The PMgr can revisit if a user reports the edit save feels slow on
expanded. Until then: no.

### 2.8 Files Feature A touches (sequencing-friendly bundles)

```
lib/domain/log_entry.dart                                 (+ LogPatch class)
lib/repositories/log_repository.dart                       (+ update, isPendingSync)
lib/data/outbox/outbox_entry.dart                          (+ optimisticId field if absent)
lib/providers/repository_providers.dart                    (wire outbox into LogRepository)
lib/features/log_entry/log_entry_sheet.dart                (existing param + edit branch + Save changes)
lib/widgets/meal_section.dart                              (Semantics label on _EntryRow only)
lib/features/today/day_view_compact.dart                   (pass onEntryTap)
lib/features/today/day_view_expanded.dart                  (pass onEntryTap)
lib/features/today/today_internals.dart                    (a new `editLogEntry` helper if we lift the handler)
```

9 files. The bulk is `log_entry_sheet.dart` (existing param + edit
branch + label wiring) and `log_repository.dart` (the new method).
Everything else is a 3–10 line edit.

### 2.9 Acceptance criteria — Feature A

- Tapping any `_EntryRow` on Today (compact or expanded) opens
  `LogEntrySheet` pre-seeded with the entry's serving, quantity, meal,
  date, and note. The food header shows the entry's `foodName`.
- The save CTA reads **"Save changes"** in edit mode and is disabled
  when the form is unchanged from the pre-seed (no-op PATCH guard).
- Pressing save calls `LogRepository.update(entryId, LogPatch)` on
  every form factor. The outbox is not involved. On medium/expanded
  the sheet stays open with the `_SaveButtonSkeleton` until the PATCH
  returns.
- On success, the sheet pops with the returned `LogEntry`. The
  day-view's `daySummaryProvider(newDate)`, `logEntriesProvider(newDate)`,
  `recentFoodsProvider`, and `frequentFoodsProvider` invalidate. If
  `consumed_on` changed, `daySummaryProvider(originalDate)` and
  `logEntriesProvider(originalDate)` also invalidate.
- On failure, the sheet stays open with input intact and a SnackBar
  reads `"Could not save changes: <error>"`. (T-11.)
- Tapping a pending-sync row (compact, outbox entry status pending or
  failed) does **not** open the sheet. A SnackBar reads `"Still
  syncing — edit when sync finishes"`. The row's existing overflow
  (Retry now / Discard) remains the only interaction. Verified by a
  widget test that constructs an outbox with one pending entry and
  asserts the sheet does not open on tap.
- `food_id` is never sent in the PATCH body. The sheet header is
  read-only — no food-picker affordance.
- Close / cancel / swipe-down on an edit sheet discards the edit; the
  original entry is untouched. Verified by a widget test.
- A `Semantics` label on the row reads `"<foodName>, <servingName>,
  <kcal> kilocalories, edit"`. (T-20.)
- Foods missing from `foodDetailProvider` (404) surface an inline
  SnackBar (`"Couldn't load food. Try again."`) and the sheet does
  not open. The row remains in the list.

---

## 3. Feature B — Weight unit preference (deep dive)

### 3.1 Wire shape

**`User.weight_unit: WeightUnit` — new field, additive.** OpenAPI shape
the backend ticket needs to land:

```yaml
User:
  type: object
  required: [id, issuer, external_id, created_at, updated_at, weight_unit]
  properties:
    # ... existing ...
    weight_unit:
      $ref: "#/components/schemas/WeightUnit"

ProfilePatch:
  properties:
    # ... existing ...
    weight_unit: { $ref: "#/components/schemas/WeightUnit" }

WeightUnit:
  type: string
  enum: [kg, lb, st]
```

**Server default `kg`** for existing users so the migration is a
one-column add. PM has flagged the backend ticket; this section names
the wire so the client can mock pre-backend.

**Client is tolerant of the field being missing on the wire** during
the pre-backend window — `User.fromJson` reads
`json['weight_unit']` and falls back to `WeightUnit.kg`. See §3.3.
This lets the client sweep ship behind the backend without a feature
flag.

### 3.2 Client domain — the enum

New value in `lib/domain/enums.dart`:

```dart
/// User-selected weight display unit. Persists on `User.weight_unit`.
/// Wire string: lowercase enum name (`'kg' | 'lb' | 'st'`).
enum WeightUnit {
  kg,
  lb,
  st;

  String get wire => name;

  /// User-facing short label rendered in chooser rows + suffixes.
  /// kg → "kg", lb → "lb", st → "st".
  String get shortLabel => name;

  /// Long-form for `Semantics` labels — "kilograms", "pounds",
  /// "stones and pounds". (Used by T-20.)
  String get longLabel {
    switch (this) {
      case WeightUnit.kg: return 'kilograms';
      case WeightUnit.lb: return 'pounds';
      case WeightUnit.st: return 'stones and pounds';
    }
  }

  static WeightUnit fromWire(String wire) {
    for (final v in WeightUnit.values) {
      if (v.name == wire) return v;
    }
    throw ArgumentError.value(wire, 'wire', 'Unknown WeightUnit');
  }
}
```

Matches the strict-`fromWire` pattern every other enum here uses.

### 3.3 `User` model + `UserPatch`

`lib/domain/user.dart` additions:

```dart
// constructor
const User({
  // ... existing ...
  this.weightUnit = WeightUnit.kg,    // server default
});

final WeightUnit weightUnit;          // NEW

// copyWith — add `WeightUnit? weightUnit` param + assignment.

// fromJson — tolerate missing field:
weightUnit: json['weight_unit'] == null
    ? WeightUnit.kg
    : WeightUnit.fromWire(json['weight_unit'] as String),

// toJson — always emit:
'weight_unit': weightUnit.wire,

// operator==, hashCode — include weightUnit.
```

`UserPatch` (same file, around line 143):

```dart
class UserPatch {
  const UserPatch({
    // ... existing ...
    this.weightUnit,        // NEW
  });

  final WeightUnit? weightUnit;       // NEW

  Map<String, dynamic> toJson() => <String, dynamic>{
    // ... existing ...
    if (weightUnit != null) 'weight_unit': weightUnit!.wire,
  };
}
```

`ProfileRepository.update` (`profile_repository.dart:53`) accumulates
the new field the same way it does the others — one extra `if (data.weightUnit
!= null)` block. No new repository method.

The mock seed user (`_fixtures.dart:65 buildSeedUser`) gains a
`weightUnit` param defaulting to `WeightUnit.kg`. Tests that want a US
or UK locale can override.

### 3.4 Locale default

**Placement: `lib/domain/locale_defaults.dart`** (new file). Reasoning
— it's not a units transform (so not `units/weight.dart`), and it
already needs to be Riverpod-overridable for tests (see §4.1), so a
small dedicated file keeps the seam clean.

```dart
import 'package:flutter/widgets.dart';
import 'enums.dart';

/// Best-guess weight unit from the platform locale's country code.
/// Called **once** at first onboarding submit (when the User is being
/// created). Not re-read on subsequent launches — once persisted on
/// User.weight_unit, the server is canonical.
///
/// US, Liberia (LR), Myanmar (MM) → lb (the three non-metric
/// countries). GB + the British Crown Dependencies (IM, JE, GG) → st.
/// Else → kg. PM directional doc §3 "locale default" picked this
/// chain explicitly.
WeightUnit defaultWeightUnitForLocale({String? countryCodeOverride}) {
  final cc = countryCodeOverride ??
      WidgetsBinding.instance.platformDispatcher.locale.countryCode;
  switch (cc) {
    case 'US':
    case 'LR':
    case 'MM':
      return WeightUnit.lb;
    case 'GB':
    case 'IM':
    case 'JE':
    case 'GG':
      return WeightUnit.st;
    default:
      return WeightUnit.kg;
  }
}
```

The `countryCodeOverride` param is the **test seam** (see §4.1 — the
ergonomics over `localesTestValue` are higher because we don't have
to spin up a `WidgetsBinding`).

In onboarding (`onboarding_screen.dart:89`), the PATCH-on-finish step
sets:

```dart
final pickedUnit = draft.weightUnit ?? defaultWeightUnitForLocale();
await profileRepo.update(UserPatch(
  // ... existing fields ...
  weightUnit: pickedUnit,
));
```

`draft.weightUnit` is a new field on the onboarding draft (next
section).

### 3.5 The `formatWeight` seam

`lib/domain/units/weight.dart` is rewritten. The existing
`formatWeightKg(Decimal kg, {String? locale})` becomes an **internal**
helper (`_formatKg`) and the public entry point is `formatWeight`:

```dart
import 'package:decimal/decimal.dart';
import 'package:intl/intl.dart';

import '../_rounding.dart';
import '../enums.dart';

const _kgPerLb = '0.45359237';           // exact (international avoirdupois)
const _lbPerKg = '2.2046226218487758';   // 1 / 0.45359237; we use a Decimal
                                          // constant truncated to 16 digits.

/// Format a weight stored canonically in `kg` for display in `unit`.
/// Half-to-even rounding (architecture §10 #9). Locale-aware decimal
/// separator via `intl`.
///
/// - `WeightUnit.kg` → "79.4 kg"-shaped (the caller appends " kg",
///   today's convention; see §3.10 for the caller contract).
/// - `WeightUnit.lb` → "175.1 lb"-shaped. One decimal, half-to-even.
/// - `WeightUnit.st` → composite "12 st 7 lb". Integer stones,
///   integer pounds. See §3.7 for the carry rule.
///
/// **Number only — no unit suffix.** Callers append the suffix (so
/// the SemanticsLabel and the visible glyph can diverge). The stone
/// case is the exception: composite IS the rendered string, including
/// the "st" and "lb" units inline.
String formatWeight(Decimal kg, WeightUnit unit, {String? locale}) {
  switch (unit) {
    case WeightUnit.kg: return _formatKg(kg, locale: locale);
    case WeightUnit.lb: return _formatLb(kg, locale: locale);
    case WeightUnit.st: return _formatStone(kg);
  }
}

/// kg → one decimal, locale-aware. Today's `formatWeightKg` body.
String _formatKg(Decimal kg, {String? locale}) {
  final formatter = NumberFormat.decimalPatternDigits(
    locale: locale,
    decimalDigits: 1,
  );
  final rounded = roundHalfToEvenScaled(kg, 1);
  return formatter.format(rounded.toDouble());
}

/// kg → lb, one decimal, locale-aware separator.
String _formatLb(Decimal kg, {String? locale}) {
  final lb = kg * Decimal.parse(_lbPerKg);
  final rounded = roundHalfToEvenScaled(lb, 1);
  final formatter = NumberFormat.decimalPatternDigits(
    locale: locale,
    decimalDigits: 1,
  );
  return formatter.format(rounded.toDouble());
}

/// kg → "12 st 7 lb" composite. The PM picked this format explicitly.
/// Algorithm:
///   1. lb_total = kg × _lbPerKg
///   2. lb_rounded = roundHalfToEvenScaled(lb_total, 0)   // integer lb
///   3. st = lb_rounded ~/ 14
///   4. lb_remainder = lb_rounded - st * 14
///   5. render "${st} st ${lb_remainder} lb"
/// Edge case: lb_remainder == 0 → render "${st} st" (drop the " 0 lb").
String _formatStone(Decimal kg) {
  final lbTotal = kg * Decimal.parse(_lbPerKg);
  final lbRounded = roundHalfToEvenScaled(lbTotal, 0);
  final lbInt = lbRounded.toBigInt().toInt();
  final stones = lbInt ~/ 14;
  final remainderLb = lbInt - stones * 14;
  if (remainderLb == 0) return '$stones st';
  return '$stones st $remainderLb lb';
}
```

**Backward-compat: keep `formatWeightKg` as a one-line wrapper** for the
duration of the sweep. The PMgr's ticket can be "delete `formatWeightKg`
once all call sites migrate"; we land the wrapper alongside the new
function so the migration is mechanical, file-by-file, without a
single-PR rename. After the sweep lands, the wrapper is deleted in a
follow-up. PM said "lean migrate all call sites"; I agree.

```dart
@Deprecated('Use formatWeight(kg, unit) — kg is no longer the only unit.')
String formatWeightKg(Decimal kg, {String? locale}) =>
    _formatKg(kg, locale: locale);
```

Compiler warnings will surface the migration list during the sweep.

### 3.6 Decimal constants — float safety

`_kgPerLb = '0.45359237'` and `_lbPerKg = '2.2046226218487758'` are
parsed as `Decimal` once at module load and reused. Per T-17, the
multiplication happens in `Decimal` space; we only `.toDouble()` once,
after rounding, at the `NumberFormat.format` boundary. This mirrors
the existing `_formatKg` discipline. No `double` math in the Decimal
chain.

### 3.7 The stone carry rule

PM named the edge case: `13 st 13.6 lb` after the half-to-even round
becomes `14 st 0 lb`, not `13 st 14 lb`. The algorithm above handles
this **because we round to integer pounds first, then divmod by 14** —
so 195.6 lb → rounds to 196 lb → divmods to 14 st 0 lb → renders
`'14 st'` (the remainder-zero branch).

Test cases the PMgr should put on the ticket:

| kg input | Expected stone output |
|---|---|
| `0` | `0 st` |
| `6.35` (~14 lb) | `1 st` |
| `45.36` (~100 lb) | `7 st 2 lb` |
| `79.4` (~175.07 lb) | `12 st 7 lb` |
| `88.9` (~195.99 lb) | `14 st` (carry edge) |
| `88.85` (~195.88 lb) | `13 st 13 lb` (just below carry) |
| `127.0` (~280.0 lb) | `20 st` |

### 3.8 Input parsing

New function in `lib/domain/units/weight.dart`:

```dart
/// Parse a raw text input into canonical kg. Inverse of `formatWeight`.
///
/// - `kg`: parses the raw as a decimal kg. Locale separator-tolerant
///   (accepts "70.5" and "70,5"; the comma is normalized to a dot
///   before `Decimal.parse`).
/// - `lb`: parses the raw as a decimal lb, multiplies by `_kgPerLb`.
/// - `st`: parses the raw as either "12 st 7" or "12 7" or just "12"
///   (= 12 st 0 lb). The stone input is a composite control (see
///   §3.9), so the raw string is constructed by the WeightStepper —
///   widgets don't call this with arbitrary text. Returns kg.
///
/// Throws `FormatException` on unparseable input. Callers wrap and
/// surface inline error (T-11).
Decimal parseWeightToKg(String input, WeightUnit unit) { ... }
```

For the stone case the `WeightStepper` keeps **two `Decimal`-typed
sub-fields** (stones, pounds) and combines them via a typed overload
`parseStoneToKg(int stones, int pounds)`. The string overload is for
symmetry / test ergonomics; widgets call the typed overload.

### 3.9 `WeightStepper` widget

Lifted T-23-compliant primitive at `lib/widgets/weight_stepper.dart`:

```dart
/// Numeric input for a body weight, in the user's preferred display
/// unit. Wraps the lifted `QuantityStepper` (kg / lb case) or two
/// side-by-side steppers (st case). The internal model is always
/// `Decimal kg`; the widget converts on read and on commit.
///
/// **The unit is a constructor param, not a Riverpod read.** Callers
/// pass `unit: ref.watch(weightUnitProvider)`; this keeps the widget
/// composable (the onboarding flow's "let the user pick a unit
/// before the User exists on the wire" path constructs it manually).
class WeightStepper extends StatelessWidget {
  const WeightStepper({
    super.key,
    required this.valueKg,
    required this.onChangedKg,
    required this.unit,
    this.minKg,
    this.maxKg,
    this.semanticsLabel,
  });

  final Decimal? valueKg;
  final ValueChanged<Decimal?> onChangedKg;
  final WeightUnit unit;
  final Decimal? minKg;
  final Decimal? maxKg;
  final String? semanticsLabel;

  // build():
  //   - kg / lb → one QuantityStepper with `unitSuffix: unit.shortLabel`,
  //     `step: 0.1` (kg) or `0.2` (lb), `min` / `max` converted to the
  //     display unit so the stepper's clamp matches the on-screen number.
  //     onChanged: parse the display-unit value back to kg, call
  //     onChangedKg(kg).
  //   - st → a row with two QuantityStepper (integer mode,
  //     allowDecimal: false): "Stones" + "Pounds (0-13)". On change of
  //     either, recompute kg = parseStoneToKg(stones, pounds), call
  //     onChangedKg(kg). The `Pounds` stepper has `min: 0, max: 13`.
  //     A wrap-on-overflow rule (entering "14" pounds bumps stones)
  //     is nice-to-have but NOT required v1 — the max: 13 clamp is
  //     enough.
}
```

Lives in `lib/widgets/` so it's package-imported via
`package:fulfilled/widgets/weight_stepper.dart` — T-23.

The widget reads zero hex (T-01) — it composes `QuantityStepper`,
which already complies. It uses `context.text`, `context.colors`, and
`context.space`. It does not touch macros tokens (T-03).

### 3.10 The `weightUnitProvider`

`lib/providers/profile_providers.dart` gains:

```dart
/// Active weight unit, derived from the cached `me` user. Falls back
/// to `WeightUnit.kg` while `meProvider` is loading or errored.
///
/// **Re-renders propagate**: any widget that
/// `ref.watch(weightUnitProvider)` rebuilds when the user changes
/// their preference (the PATCH /me invalidates `meProvider`, which
/// updates this provider on the next frame). The sparkline's Y-axis
/// ticks, the profile row's caption, every weight number — all snap
/// to the new unit without a manual rebuild.
final weightUnitProvider = Provider<WeightUnit>((ref) {
  return ref.watch(meProvider).whenData((u) => u.weightUnit).valueOrNull
      ?? WeightUnit.kg;
});
```

**Suffix discipline.** The PM doc and §3.5 carefully separate the
*number* from the *unit suffix*. The convention across the inventory:
the caller emits something like `'${formatWeight(kg, unit)} ${unit ==
WeightUnit.st ? '' : unit.shortLabel}'` — the stone case includes its
units inline, the kg/lb cases get the suffix appended by the caller.

To avoid every caller re-implementing this, add one more helper in
`weight.dart`:

```dart
/// `formatWeight` + the appropriate visible suffix, in one string.
/// Useful for callers that don't render the unit separately.
/// - kg/lb: `"79.4 kg"` / `"175.1 lb"`
/// - st: `"12 st 7 lb"` (suffix is already inline)
String formatWeightWithUnit(Decimal kg, WeightUnit unit) {
  final num = formatWeight(kg, unit);
  if (unit == WeightUnit.st) return num;
  return '$num ${unit.shortLabel}';
}
```

Most existing call sites today render `'${formatWeightKg(value)} kg'`
— those collapse to `formatWeightWithUnit(value, unit)`. Sites that
render the number and unit in two different `Text` widgets (e.g.
`mini_weight_sparkline.dart` lines 93–101, two `Text`s with a
`SizedBox` between them) continue to use the bare `formatWeight` and
render the unit in their own Text — but those sites need the **stone
carve-out**: when `unit == st`, drop the second `Text` because the
composite string already includes its units. See §3.13 for which
sites are which.

### 3.11 Onboarding step 2

`lib/features/onboarding/widgets/step_2_about_you.dart` changes:

- The weight stepper switches from kg-only to `WeightStepper`. Its
  `unit` is `ref.watch(_onboardingWeightUnitProvider)` (new — see
  below).
- The `_formatWeightKgLabel` helper (lines 343–345) is replaced with
  inline `formatWeightWithUnit(value, unit)`.
- A small unit chooser sits **above** the weight row (a three-up
  `SegmentedSelect` styled like the existing sex one — same widget,
  same tokens). The user can override the locale default. Default
  selection: `defaultWeightUnitForLocale()` on first build.
- The onboarding draft (`lib/domain/drafts.dart`) gains a
  `WeightUnit? weightUnit` field. `null` means "use locale default at
  submit time"; the chooser sets it explicitly the moment the user
  taps a segment.

The `_onboardingWeightUnitProvider` is local to onboarding:

```dart
// In lib/providers/draft_providers.dart (sibling of the existing
// onboarding draft provider).
final _onboardingWeightUnitProvider = Provider<WeightUnit>((ref) {
  final draft = ref.watch(onboardingDraftProvider);
  return draft.weightUnit ?? defaultWeightUnitForLocale();
});
```

Reasoning: during onboarding, the user is pre-User. `weightUnitProvider`
(global) reads `meProvider` which hasn't seen this user yet — it
would always return `WeightUnit.kg`, which is wrong for the US
onboarder. So onboarding has its own provider that derives from the
draft + the locale default, until the final PATCH lands. After that,
`meProvider` invalidates and the global provider takes over.

### 3.12 Profile screen — interactive Units row

`lib/features/profile/profile_screen.dart` lines 191–209 today render
an informational `SettingsRow` for Units. Replace with a tappable row
that opens the chooser:

```dart
SettingsCard(
  title: 'Preferences',
  rows: <Widget>[
    SettingsRow(
      key: const Key('row-units'),
      icon: Icons.public,
      label: 'Units',
      value: '${user.weightUnit.shortLabel}, cm, kcal, g',
      onTap: () => showWeightUnitChooser(context, ref,
          initial: user.weightUnit),
      semanticsLabel:
          'Weight unit: ${user.weightUnit.longLabel}. Tap to change.',
    ),
  ],
),
```

`showWeightUnitChooser` is a new feature-private widget at
`lib/features/profile/widgets/weight_unit_chooser.dart`:

```dart
Future<void> showWeightUnitChooser(
  BuildContext context,
  WidgetRef ref, {
  required WeightUnit initial,
}) {
  // FormFactor.of(context).isCompact → modal bottom sheet, three
  // ActivityOption-shaped rows ("Kilograms (kg) — most countries",
  // "Pounds (lb) — common in the US", "Stones & pounds (st) —
  // common in the UK").
  //
  // medium / expanded → a popup menu anchored to the row.
  //
  // On select: PATCH /me with weight_unit, invalidate meProvider,
  // close. The downstream `weightUnitProvider` swaps on the next
  // frame; every weight render updates.
}
```

The chooser is **feature-private** (not in `lib/widgets/`) because
nothing outside profile uses it. T-23 — the lifted widget list is the
component inventory in architecture §3; this chooser isn't in it.

`SettingsRow.value` (the trailing text) shows the active unit's short
label first ("kg", "lb", or "st") followed by ", cm, kcal, g" —
matching the PM's caption directive (other quantities are locked).

The pre-existing "Coming soon" SnackBar PM mentions doesn't exist on
this row in the current codebase (the row's `onTap: null` makes it
non-interactive); but a SnackBar **does** exist on the "Export data"
row (`profile_screen.dart:224`). That one is unrelated. No deletion
needed for the Units row — there's nothing there to delete.

### 3.13 Inventoried weight surfaces

The complete table. Column 1 is file. Column 2 is what the file
renders today. Column 3 is what it should render after Feature B.

| File | Today | After |
|---|---|---|
| `lib/domain/units/weight.dart` | `formatWeightKg` only | `formatWeight(kg, unit)`, `formatWeightWithUnit(kg, unit)`, `parseWeightToKg(input, unit)`, internal `_formatKg/_formatLb/_formatStone`; `formatWeightKg` becomes `@Deprecated` wrapper |
| `lib/domain/user.dart` | no unit field | `weightUnit` field, copyWith, fromJson tolerant of missing, toJson always emits |
| `lib/domain/enums.dart` | no `WeightUnit` | add `WeightUnit { kg, lb, st }` |
| `lib/domain/drafts.dart` | onboarding draft has no unit | add `WeightUnit? weightUnit` |
| `lib/domain/locale_defaults.dart` | n/a (new file) | exports `defaultWeightUnitForLocale({String? countryCodeOverride})` |
| `lib/providers/profile_providers.dart` | `meProvider` only | + `weightUnitProvider` (derived) |
| `lib/providers/draft_providers.dart` | onboarding draft notifier | + `_onboardingWeightUnitProvider` |
| `lib/repositories/profile_repository.dart` | `update(UserPatch)` ignores unit | accepts `UserPatch.weightUnit`, writes through |
| `lib/widgets/weight_stepper.dart` | n/a (new file) | `WeightStepper(valueKg, onChangedKg, unit, minKg, maxKg, semanticsLabel)` |
| `lib/features/onboarding/widgets/step_2_about_you.dart` | kg-only stepper + `_formatWeightKgLabel` | `WeightStepper` + unit chooser above the row + `formatWeightWithUnit` |
| `lib/features/onboarding/onboarding_screen.dart` | PATCHes profile w/o unit | PATCHes profile WITH `weightUnit: draft.weightUnit ?? defaultWeightUnitForLocale()` |
| `lib/features/profile/profile_screen.dart` line 171 | `'${formatWeightKg(user.currentWeightKg!)} kg'` | `formatWeightWithUnit(user.currentWeightKg!, user.weightUnit)` |
| `lib/features/profile/profile_screen.dart` lines 191–209 (Units row) | informational, `value: 'kg, cm, kcal, g'`, `onTap: null` | interactive, value reflects user.weightUnit, `onTap` opens chooser |
| `lib/features/profile/widgets/current_weight_sheet.dart` | kg-only `QuantityStepper` (~lines 122–166), `formatWeightKg` label | swap to `WeightStepper(unit: ref.watch(weightUnitProvider))`; replace `_format` with `formatWeight(_kg, unit)` |
| `lib/features/profile/widgets/weight_unit_chooser.dart` | n/a (new file) | the chooser bottom-sheet / popup |
| `lib/features/weight/weight_screen.dart` | docstring references `formatWeightKg` | docstring update only; the screen composes other widgets which do the work |
| `lib/features/weight/widgets/weight_summary_card.dart` | `formatWeightKg` × 4, `kg` literal × 3 (lines 114, 225, 230, 250, 305, 306, 324, 352) | all sites → `formatWeight(value, unit)`; suffix `Text` widgets check the stone case and drop the suffix when `unit == st` |
| `lib/features/weight/widgets/weight_sparkline.dart` | `'GOAL ${formatWeightKg(goalKg!)}'` × 2 (lines 427, 588) | `'GOAL ${formatWeightWithUnit(goalKg!, unit)}'`; the painter needs `unit` as a constructor param + axis ticks computed in the display unit (see §3.14) |
| `lib/features/weight/widgets/weight_history_list.dart` | `'${formatWeightKg(entry.weightKg)} kg'` (line 226), Semantics labels in `formatWeightKg` (lines 248, 256, 290) | `formatWeightWithUnit(entry.weightKg, unit)` for the visible label; Semantics uses `formatWeight(value, unit)` + `unit.longLabel` |
| `lib/features/weight/widgets/log_weight_sheet.dart` | `QuantityStepper(unitSuffix: 'kg', ...)` at line 286, `'Logged ${formatWeightKg(_weightKg)} kg ...'` at line 130, `formatWeightKg(v)` at line 396 | swap to `WeightStepper`; toast uses `formatWeightWithUnit(_weightKg, unit)`; line 396 (quick-chip label) same |
| `lib/features/goals/widgets/goal_active_card.dart` | start/target weight rendered via local `_formatRate` + kg literal `'kg / week'` (lines 229–230) | start/target weight (search for any direct render — `Goal.startWeightKg` / `Goal.targetWeightKg` are *rendered* in this card per PM §3 scope-in) goes through `formatWeightWithUnit`. **The rate label keeps `kg / week`** per PM ruling — punt list explicitly says rate stays in kg |
| `lib/features/goals/widgets/new_goal_dialog.dart` | derives template start/target from the user; no user-editable weight inputs visible (line 200–201 pass `template?.startWeightKg`/`targetWeightKg` through) | display-only sites (if any preview of start/target) → `formatWeightWithUnit`. **No new weight input field**; this dialog doesn't ask the user to type a start/target weight today. PM's inventory included it because the *display* shows kg; verified there's no input |
| `lib/features/goals/widgets/edit_goal_sheet.dart` | same as new_goal_dialog — no user-editable weight inputs | same — display-only update if any preview |
| `lib/features/goals/widgets/goal_editor_body.dart` | rate slider in `kg/week`, label `'$rateLabel kg / week'` (line 168), `'1.0 kg/wk'` (line 203) | **no change**. Rate stays in kg/week per PM ruling |
| `lib/features/goals/widgets/goal_history_list.dart` | rate label `'0 kg/week'` / `'$sign$mag kg/week'` (lines 263, 267, 280) | **no change**. Rate stays in kg/week. Note: this file *also* doesn't render start/target weight today |
| `lib/features/today/widgets/mini_weight_sparkline.dart` | `formatWeightKg(latest)` + a separate `'kg'` `Text` (lines 94, 99); `_deltaLabel` with `formatWeightKg(delta.abs()) + ' kg'` (lines 119, 124) | header `Text` becomes `formatWeight(latest, unit)`; the separate `'kg'` `Text` is hidden when `unit == st` and reads `unit.shortLabel` otherwise; `_deltaLabel` becomes a stone-aware composite (lose the explicit `' kg'`, use `formatWeightWithUnit` and prepend the sign). **Note**: the `'±0.0 kg'` zero case needs a stone branch — `'±0 st'` is the cleanest |
| `lib/widgets/quantity_stepper.dart` | unit-agnostic (already T-23-ready) | **no change**. `WeightStepper` wraps it |

23 distinct surfaces / files. PM's inventory was 16 + the file list
ignored some surfaces I want named explicitly (the providers, the
domain enums, the deprecated wrapper). Net widget-level edit sites:
12 (everything in the `features/` rows above with a "swap" verb).

**Files I am explicitly NOT touching** from PM's §4 list and why:

- `lib/features/profile/widgets/settings_card.dart` — the card chrome
  doesn't change. The row content does (handled at the consumer in
  `profile_screen.dart`). PM said "no change; row content does."
  Confirmed.
- `lib/features/today/today_internals.dart` — Feature A might add a
  helper here, but Feature B doesn't touch it. The mini sparkline
  lives in `widgets/mini_weight_sparkline.dart`, sibling but distinct.
- Anything under `lib/data/`, `lib/theme/`, `lib/routing/` — Feature B
  doesn't change wire transport, tokens, or routes.

### 3.14 Sparkline Y-axis

PM raised this. `weight_sparkline.dart` lines 427 / 588 use
`formatWeightKg(goalKg!)` for the dashed goal-line label. The
painter's Y-axis ticks are computed from `weightKg` values in the
points list.

**Decision: pre-convert in the painter setup, not via a formatter
callback.** Two reasons:

1. The painter does layout math against tick *numbers* (string width
   to position the label, range min/max), not just glyph rendering.
   Working in the display unit from the start keeps the math obvious.
2. Stone tick labels render as composites (`'12 st 7 lb'`) — wider
   than a kg or lb tick. Pre-converting lets the painter measure
   widths up-front and adjust horizontal padding once, rather than
   re-measuring each tick.

`WeightSparkline` (the public widget) takes a `WeightUnit unit`
param. The painter takes the same. Inside the painter:

- Convert each point's `weightKg` to the display unit's
  `Decimal`-typed value via a private helper (`_displayValue(kg,
  unit)` returns a `Decimal` representing the visible y, in lb for
  lb, in stones-with-fractional-lb for st — actually, for st we
  reduce to total pounds for the y-axis to keep the linear math
  simple; the *label* is still composite, computed from the same
  total-pounds value via the existing `_formatStone` algorithm).
- Compute min/max in the display unit. Pick the tick interval the
  same way today's painter does, but in the display unit.
- Render each tick via `formatWeightWithUnit(kg_value, unit)`.

The change ripples to ~30 lines inside the painter; the public
widget gains the `unit` param. Call sites pass
`unit: ref.watch(weightUnitProvider)`.

### 3.15 Acceptance criteria — Feature B

- `User.weight_unit` round-trips through OpenAPI (backend ticket
  pending), `User.fromJson`, `User.toJson`, `UserPatch.toJson`. The
  field is tolerated as missing during the pre-backend window —
  `User.fromJson` defaults to `WeightUnit.kg`.
- `WeightUnit` is an enum with three values (`kg | lb | st`). The
  wire string is the lowercase enum name.
- `formatWeight(Decimal kg, WeightUnit unit) → String` exists in
  `lib/domain/units/weight.dart`. `formatWeightKg` continues to exist
  as a deprecated wrapper for one release; the sweep deletes its call
  sites in the same PR that lands `formatWeight`.
- `formatWeightWithUnit` and `parseWeightToKg` are public; the stone
  case has its own typed `parseStoneToKg(int st, int lb)`.
- Locale default applies only at first onboarding submit when the
  draft's `weightUnit` is null. The locale read is overridable by
  test (`defaultWeightUnitForLocale(countryCodeOverride: 'US')`).
- The Profile → Preferences → Units row is interactive; tapping it
  opens the chooser. Selecting a unit PATCHes `weight_unit`,
  invalidates `meProvider`, and the change reflects across the app
  on the next frame via `weightUnitProvider`.
- Onboarding step 2 shows a unit chooser above the weight stepper.
  The stepper is a `WeightStepper`. The default chooser selection is
  `defaultWeightUnitForLocale()`. PATCH at finish writes the picked
  unit.
- Every weight-rendering surface in §3.13 goes through `formatWeight`
  / `formatWeightWithUnit`. No widget multiplies by `2.2046226` or
  divides by `14`. The lint check is a `grep` for those literals in
  `lib/features/` and `lib/widgets/`.
- The stone composite renders correctly across the test cases in
  §3.7. The carry edge (`88.9 kg → "14 st"`) is covered by a unit
  test on `_formatStone`.
- The stone input renders two side-by-side `QuantityStepper`s
  (stones integer, pounds integer 0–13). Save combines them via
  `parseStoneToKg`.
- The sparkline Y-axis ticks render in the user's unit (and as
  composite stones for st). The dashed goal label uses
  `formatWeightWithUnit`.
- `Semantics` labels include the rendered value with its long-form
  unit (`"Current weight 12 stones and pounds"` becomes `"Current
  weight 12 st 7 lb, 12 stones and pounds"` — read literally,
  composed by the call site). For lb: `"Current weight 175.1 pounds"`.
  For kg: `"Current weight 79.4 kilograms"` (unchanged from today).

---

## 4. Cross-cutting concerns

### 4.1 Test seam — locale override

`tester.binding.platformDispatcher.localesTestValue` works but
requires a `WidgetTester` and the right binding initialization. It
also can't be set inside a Riverpod-only unit test (no widget tree).

**Pick the constructor-param override on `defaultWeightUnitForLocale`.**
The function takes `String? countryCodeOverride`. Tests pass `'US'` /
`'GB'` / `null`. Riverpod tests that want to override the *provider*
can do so directly (`weightUnitProvider.overrideWith((_) =>
WeightUnit.lb)`).

Two seams, two consumers — they don't conflict.

The widget-level test seam (when the test wants to mount onboarding
under a faked locale) layers on top: a `ProviderScope.overrides` for
`_onboardingWeightUnitProvider` is the easy path; falling back to
`localesTestValue` works for end-to-end tests that exercise the
locale-default chain itself.

### 4.2 Pre-backend window

The Rust migration adds `weight_unit` to `users`. The client should
ship before the migration lands, provided:

1. `User.fromJson` tolerates missing `weight_unit` (defaults to `kg`).
   ✓ Per §3.3.
2. `UserPatch.toJson` only emits `weight_unit` when it's set. ✓ Per §3.3.
3. The mock `ProfileRepository.update` accepts and writes it. ✓ The
   mock has full control of the user shape.

Result: dev agents can land the entire client sweep against the
*mock* repository. When the backend lands, the only client change is
"the value persists across sessions"; no code change. **PMgr — name
this in the ticket pack so a dev agent doesn't block waiting for the
Rust PR.**

### 4.3 Outbox behaviour for edits

PM ruled "edits are not queued; online-only." The implementation:

- `_onEditPressed` (§2.5) calls `LogRepository.update` directly on all
  form factors.
- On failure, the sheet stays open with input intact, a SnackBar
  surfaces the error (T-11), `_submitting` returns to false.
- The day-view's pending-sync guard (§2.6) prevents tapping into the
  sheet on a row whose POST hasn't acked.
- The outbox path (`logOutboxProvider.notifier.enqueue`) is untouched.
  It remains create-only.

Documented in `_onEditPressed`'s doc comment so a future dev doesn't
ask "why is this code path so different from `_onCreatePressed`."

### 4.4 Lint compliance

- **T-01 (no raw hex).** No new color in Feature A or B.
  `lint_no_hex_outside_tokens.sh` should continue to pass; if it
  starts failing, the offender is almost certainly a new widget
  someone wrote with a literal — review.
- **T-17 (Decimal in / formatted out).** All weight inputs are
  `Decimal`-typed end-to-end. The lb conversion uses
  `Decimal.parse('2.2046226218487758')`, not `2.2046226 * value`. The
  `_kgPerLb` constant is the inverse; we use it for lb→kg in
  `parseWeightToKg`. The `toDouble()` call only fires inside
  `NumberFormat.format` at the very leaf (already today's pattern in
  `_formatKg`).
- **T-21 (display units customer-expected).** Feature B is the
  fulfillment of T-21's v2 commitment. Macros stay g, sodium stays
  mg, energy stays kcal — only weight gains a preference.
- **T-22 (pending sync visible).** Feature A inherits T-22 by refusing
  to edit pending rows; the guard is implemented at the repository,
  the SnackBar surface at the day view.
- **T-23 (lifted widgets package-imported).** `WeightStepper` is
  added to the architecture §3 component inventory. Imports use
  `package:fulfilled/widgets/weight_stepper.dart`.
  `lint_no_cross_feature_widget_import.sh` continues to pass — no
  feature imports another feature's widget.
- **T-15 (form factor branches at the screen root).** The Profile
  units chooser branches inside `showWeightUnitChooser`, which is a
  bottom-sheet vs popup-menu choice at the screen edge. The chooser
  body widget is the same; only the shell differs.

### 4.5 Sequencing

**Sub-tasks that can run in parallel:**

1. New `WeightUnit` enum + `User.weightUnit` plumbing (Feature B §3.2–3.3).
2. `formatWeight` + helpers + tests (Feature B §3.5–3.8).
3. `LogPatch` class + `LogRepository.update` mock + tests (Feature A
   §2.4).
4. `outbox_entry.optimisticId` reconciliation (Feature A §2.6).

These have zero file overlap with each other.

**Serial dependencies:**

- `WeightStepper` (§3.9) depends on `formatWeight` landing.
- `weightUnitProvider` (§3.10) depends on `User.weightUnit` field
  landing.
- The 12 widget-level swaps in §3.13 depend on `formatWeight` +
  `weightUnitProvider` + `WeightStepper` all landing.
- The Profile Units chooser depends on `weightUnitProvider` + the
  `ProfileRepository.update` path accepting `weightUnit`.
- The day-view tap wiring depends on `LogEntrySheet`'s `existing`
  param + `LogRepository.update`.
- The day-view pending-sync guard depends on the
  `outbox_entry.optimisticId` reconciliation.

**Recommended PR sequence:**

1. PR 1 — Feature A: `LogPatch`, `LogRepository.update`,
   `LogEntrySheet existing:` param, day-view wiring, pending-sync
   guard. One PR.
2. PR 2 — Feature B foundations: `WeightUnit` enum, `User`/`UserPatch`
   plumbing, `formatWeight` + helpers, `weightUnitProvider`,
   `WeightStepper`. Includes tests for the seam.
3. PR 3 — Feature B sweep: the 12 widget swaps + sparkline painter
   `unit` param + onboarding chooser. Mechanical given PR 2.
4. PR 4 — Feature B chooser: profile Units row interactivity + the
   chooser widget + the `ProfileRepository.update` weightUnit pass-through.

Per PM: ship A first, then B in three sub-PRs. Total ~4 PRs.

---

## 5. Tenant updates

No new tenants. T-21 already commits "Display units are
customer-expected, not canonical" — Feature B is the v2-ticket
follow-through PM Risk 4 promised. T-22 already covers "pending-sync
state is visible, not silent" — Feature A inherits the rule by
refusing to edit pending rows; the existing tenant is sufficient.

The text on T-21 in the architecture doc currently says "body weight
in kg for v1." Update to "body weight in the user's chosen unit (kg
/ lb / st), persisted on `User.weight_unit`" once Feature B lands.
This is a one-sentence amendment, not a new tenant.

A T-24 about "row taps are routable affordances" would be forced —
skip. The behaviour is already implicit in T-14 (routes are
addressable; sheets are not) and the day-view brief in §9 of the
architecture doc.

---

## 6. Open questions / risks for the PMgr

1. **Optimistic id reconciliation with outbox keys** (§2.6). The
   pending-sync guard needs the optimistic `LogEntry.id` and the
   outbox `OutboxEntryRecord` key to agree. Today they're generated
   separately. The fix is small but it's a real ticket. **PMgr —
   include a sub-task: "Unify optimistic LogEntry id with outbox
   entry key."**

2. **`note: null` semantics on `LogPatch`.** The OpenAPI uses the
   absence-vs-explicit-null distinction; the client's `LogPatch.toJson`
   honours it via the `clearNote` flag. v1's UI does not expose
   "clear note" as a distinct affordance; we emit `clearNote: true`
   when the user blanked a previously-non-null note. **PMgr —
   confirm with the user this matches their mental model**, or punt
   note-clearing to v2 and never emit `clearNote: true`. (My
   recommendation: ship the auto-clear; users would be surprised if
   blanking the field didn't actually blank the field.)

3. **Live-flip behaviour of `weightUnitProvider`.** Question: "What if
   the user changes weight_unit mid-session — does the sparkline
   re-render with new ticks?" **Answer: yes.** Every widget that
   reads weight goes through `ref.watch(weightUnitProvider)`; on
   `PATCH /me`, `meProvider` invalidates and the new unit propagates
   on the next frame. The sparkline painter takes `unit` as a
   constructor param, so the `CustomPaint` rebuilds. This is a
   correctness guarantee — and it's the reason the painter must take
   `unit` as a param (vs. computing it internally — that would
   require a `ref` inside the painter, which is awkward).

4. **Pre-backend window for `weight_unit`.** The client sweep can
   ship before the Rust migration if the server doesn't reject extra
   keys on `PATCH /me`. **PMgr — confirm the server's tolerance:**
   does the current Rust API ignore unknown JSON keys, or 400? If
   400, PR 4 must wait for the migration. I would expect "ignore"
   based on the OpenAPI patch-style schemas elsewhere, but I haven't
   verified.

5. **Stone input ergonomics on mobile.** Two side-by-side steppers in
   a 390-wide compact viewport is tight. The stepper's
   `showStepperButtons: false` mode (already in the lifted
   `QuantityStepper`) is available; we may need to use it for the
   pound sub-field to fit on iPhone SE. **PMgr — flag for design**:
   if the two-stepper layout fights the compact width, the fallback
   is the +/− buttons collapse to a row above the field, not beside
   it. Either way the contract holds; the visual is the choice.

---

End of contract.
