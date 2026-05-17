import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:fulfilled/widgets/quantity_stepper.dart';

import '../../data/outbox/log_outbox_notifier.dart';
import '../../domain/food.dart';
import '../../domain/log_entry.dart';
import '../../domain/meal.dart';
import '../../domain/serving.dart';
import '../../domain/unit.dart';
import '../../form_factor/form_factor.dart';
import '../../providers/food_providers.dart';
import '../../providers/log_providers.dart';
import '../../providers/repository_providers.dart';
import '../../theme/context_extensions.dart';
import '../../widgets/motion.dart';
import '../today/today_internals.dart' show pathForDay;
import 'widgets/log_preview_block.dart';
import 'widgets/meal_chip_picker.dart';
import 'widgets/quick_multiplier_chips.dart';

/// Per-sheet quantity. Scoped via `ProviderScope.overrides` so each
/// sheet instance owns its own `Decimal` — see [LogEntrySheetBody] for
/// the override seed.
///
/// **Why a top-level provider scoped per sheet** instead of a per-state
/// `StateProvider` family or local widget state: the architect's
/// gotcha for screen 04 says "Use a single Riverpod `quantityProvider`
/// for the sheet, not separate widget state." A top-level `StateProvider`
/// re-seeded inside the sheet's `ProviderScope` gives the inner widgets
/// (stepper, chips, preview) one source of truth without dragging
/// `WidgetRef`-aware state up through callbacks.
final quantityProvider = StateProvider<Decimal>((ref) => Decimal.one);

/// Public API the rest of the app calls.
///
/// On `FormFactor.isCompact` pushes a `DraggableScrollableSheet` with
/// `snap: true` and snap-points `[0.5, 0.88]`. On medium/expanded shows
/// a centered `Dialog` capped at 480 px wide. Either path returns the
/// resulting `LogEntry?` — `null` if the user dismissed without saving.
///
/// **Modes.**
/// - `existing == null` → create mode (today's behaviour). On compact,
///   the returned `LogEntry` is an **optimistic** value constructed from
///   the form state; the real entry is created when the outbox flushes.
/// - `existing != null` → edit mode. The form pre-seeds from the entry.
///   The header gets an "(editing)" suffix; the CTA reads "Save changes".
///   Submit routes through `LogRepository.update` on every form factor
///   (edits are not queued — architect §2.5). The returned `LogEntry`
///   is the server response.
///
/// `defaultMeal` is **ignored** in edit mode: the entry's own meal wins.
/// PMgr called this out so dev agents don't burn time chasing the case.
Future<LogEntry?> showLogEntrySheet(
  BuildContext context, {
  required Food food,
  Meal? defaultMeal,
  LogEntry? existing,
}) {
  final isCompact = FormFactor.of(context).isCompact;
  // Capture the parent container so the nested ProviderScope can lift
  // the real LogRepository.create into the outbox notifier — the
  // foundation's `logPostFnProvider` is a throwing stub by default.
  final parent = ProviderScope.containerOf(context, listen: false);
  // Quantity seed: edit mode hydrates from the entry; create mode
  // starts at 1. Architect §2.2 specifies the override seed is the
  // only place quantity-from-entry is read — the body never reads the
  // entry directly to populate the stepper.
  final Decimal quantitySeed = existing?.quantity ?? Decimal.one;

  Widget contents({
    required ScrollController? scrollController,
    required bool showGrabber,
  }) {
    return ProviderScope(
      parent: parent,
      overrides: <Override>[
        // Re-seed so each sheet gets a fresh quantity (otherwise the
        // last-used value would leak across sheets via the top-level
        // provider's container cache). In edit mode the seed is the
        // existing entry's quantity.
        quantityProvider.overrideWith((ref) => quantitySeed),
        // Wire the real POST into the mobile outbox. Without this
        // override, `LogOutboxNotifier` throws `UnimplementedError`
        // when it tries to flush.
        logPostFnProvider.overrideWithValue((payload) async {
          // The notifier passes the raw LogCreate JSON; rebuild a
          // LogCreate so we can hit the typed repository API. The map
          // shape is the same one `LogCreate.toJson` emits.
          final logCreate = _logCreateFromPayload(payload);
          final entry = await parent.read(logRepositoryProvider).create(logCreate);
          return entry.id;
        }),
      ],
      child: LogEntrySheetBody(
        food: food,
        defaultMeal: defaultMeal,
        existing: existing,
        scrollController: scrollController,
        showGrabber: showGrabber,
        onSubmit: (logCreate) async {
          // The submit flow is wired in the body — but expose it on the
          // API too for callers that want to drive it externally in
          // tests. The body still owns navigation.
        },
      ),
    );
  }

  if (isCompact) {
    return showModalBottomSheet<LogEntry?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      useSafeArea: true,
      builder: (sheetContext) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.88,
          minChildSize: 0.5,
          maxChildSize: 0.88,
          snap: true,
          snapSizes: const <double>[0.5, 0.88],
          builder: (ctx, scrollController) {
            return contents(
              scrollController: scrollController,
              showGrabber: true,
            );
          },
        );
      },
    );
  }

  return showDialog<LogEntry?>(
    context: context,
    barrierDismissible: true,
    builder: (dialogContext) {
      return Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(24),
        child: _DialogEnterAnimation(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480, maxHeight: 720),
            child: ClipRRect(
              borderRadius: const BorderRadius.all(Radius.circular(24)),
              child: contents(scrollController: null, showGrabber: false),
            ),
          ),
        ),
      );
    },
  );
}

/// T-016 dialog arrival animation. Wraps the medium/expanded `Dialog`
/// child in a one-shot `TweenAnimationBuilder<double>` driving opacity
/// (0 → 1) + an 8-px upward translate. Duration 200 ms with the
/// `easeOutCubic` arrival curve. `motion()` collapses to zero under
/// reduce-motion.
class _DialogEnterAnimation extends StatelessWidget {
  const _DialogEnterAnimation({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: motion(context, const Duration(milliseconds: 200)),
      curve: Curves.easeOutCubic,
      builder: (context, t, inner) {
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 8 * (1 - t)),
            child: inner,
          ),
        );
      },
      child: child,
    );
  }
}

/// The inner widget rendered identically inside the sheet (compact) or
/// the dialog (medium / expanded). Public so tests can pump it without
/// going through `showModalBottomSheet` plumbing.
///
/// `onSubmit` is invoked **after** the form has been turned into a
/// `LogCreate`. The body still owns dispatching to the outbox /
/// repository and popping the route; `onSubmit` is a test seam.
class LogEntrySheetBody extends ConsumerStatefulWidget {
  const LogEntrySheetBody({
    super.key,
    required this.food,
    required this.onSubmit,
    this.existing,
    this.defaultMeal,
    this.scrollController,
    this.showGrabber = true,
    @visibleForTesting this.initialDate,
  });

  final Food food;

  /// The entry being edited. When non-null the sheet is in **edit mode**
  /// (header suffix, "Save changes" CTA, submit routes through
  /// `LogRepository.update`). When null the sheet is in **create mode**
  /// — today's behaviour. Architect §2.3.
  final LogEntry? existing;

  /// Pre-selected meal for create mode. **Ignored when [existing] is
  /// non-null** — the existing entry's meal wins. Architect §2.2 spells
  /// out the precedence; PMgr surfaces it in LU-002 so dev agents don't
  /// chase the ignored-case bug.
  final Meal? defaultMeal;

  final ValueChanged<LogCreate> onSubmit;
  final ScrollController? scrollController;
  final bool showGrabber;

  /// **Test-only.** Forces the date seed instead of letting it default.
  /// In create mode this short-circuits `DateTime.now()`; in edit mode
  /// it overrides `existing.consumedOn` so QL-105's "edit shifts the
  /// date" router test can exercise the `pathForDay(newDate)` branch
  /// without standing up a DATE-picker (out of scope; that lands in
  /// QL-107). The "edit shifts" semantics live entirely in
  /// `_LogEntrySheetBodyState._date`; this hook seeds `_date` directly
  /// while leaving `widget.existing.consumedOn` (the seed-vs-new
  /// comparison anchor in `_buildLogPatch`) untouched. Architect §6.2 /
  /// QL-105 fixture.
  final DateTime? initialDate;

  @override
  ConsumerState<LogEntrySheetBody> createState() => _LogEntrySheetBodyState();
}

class _LogEntrySheetBodyState extends ConsumerState<LogEntrySheetBody> {
  late Meal _meal;
  late Serving _serving;
  late DateTime _date;

  /// Unit the user is currently entering the amount in. Must share a
  /// family with [_serving.unit] (the dropdown only surfaces
  /// same-family options). Defaults to the serving's own unit in
  /// create mode and the entry's `entered_unit` in edit mode.
  late Unit _enteredUnit;

  final TextEditingController _noteCtrl = TextEditingController();
  bool _submitting = false;

  /// True iff the sheet was opened to edit an existing entry. The
  /// header suffix, CTA label, save-button enablement and submit branch
  /// all read this — architect §2.3.
  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final ex = widget.existing;
    // Precedence: `existing.meal` > `defaultMeal` > local-time fallback.
    // `defaultMeal` is documented as ignored in edit mode; this `??`
    // chain implements that without an explicit branch.
    _meal = ex?.meal ?? widget.defaultMeal ?? mealForLocalTime(DateTime.now());
    final seedServingId = ex?.servingId ?? widget.food.defaultServingId;
    _serving = widget.food.servings.firstWhere(
      (s) => s.id == seedServingId,
      orElse: () => widget.food.servings.first,
    );
    // In edit mode the entry carries the unit the user originally
    // entered in; preserve it iff it's same-family as the serving
    // (defensive — server-side validation should already enforce this
    // but the entry could have been edited to a different serving).
    final exEnteredUnit = ex?.enteredUnit;
    _enteredUnit = (exEnteredUnit != null &&
            exEnteredUnit.family == _serving.unit.family)
        ? exEnteredUnit
        : _serving.unit;
    // Seed precedence:
    //   1. `widget.initialDate` (test-only seam — overrides edit-mode's
    //      `existing.consumedOn` so QL-105's date-shift router test can
    //      simulate the user picking a different date without a real
    //      DATE-picker UI, which is out of scope here).
    //   2. `existing.consumedOn` (edit mode).
    //   3. `DateTime.now()` (create-mode default).
    final seedDate =
        widget.initialDate ?? ex?.consumedOn ?? DateTime.now();
    _date = DateTime(seedDate.year, seedDate.month, seedDate.day);
    _noteCtrl.text = ex?.note ?? '';
    // Re-render save-button enablement as the user types in the note.
    // (Quantity / serving / meal / date all already trigger `setState`
    // when they change; the note field is a raw TextField, so we wire
    // its controller here.)
    _noteCtrl.addListener(_onFormChanged);
  }

  void _onFormChanged() {
    // The save button's `onPressed` is a function of the form state vs.
    // the seed; rebuild to recompute it. Cheap — no provider work.
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    _noteCtrl.removeListener(_onFormChanged);
    _noteCtrl.dispose();
    super.dispose();
  }

  /// Backdate / forward-pick the entry's `consumedOn`. QL-107 — DATE
  /// row tap target.
  ///
  /// `firstDate` is 60 days ago (QL-107 dev-ticket constraint —
  /// architect §7.7's 365-day window was narrowed by PM); `lastDate`
  /// is today, so future-dating is not allowed. On cancel the picker
  /// resolves to `null` and `_date` is preserved.
  ///
  /// The picked date updates `_date` via `setState`; the existing
  /// submit path already reads `_date` to construct the payload (and
  /// QL-105's router uses the new date on save), so no other wiring
  /// is needed here.
  Future<void> _pickDate() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final firstDate = today.subtract(const Duration(days: 60));
    // Clamp `initialDate` into `[firstDate, today]` — `showDatePicker`
    // asserts on initial outside the window, which would crash on an
    // edited entry whose `consumedOn` precedes the 60-day floor.
    DateTime initial = _date;
    if (initial.isBefore(firstDate)) initial = firstDate;
    if (initial.isAfter(today)) initial = today;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: firstDate,
      lastDate: today,
    );
    if (picked == null) return;
    if (!mounted) return;
    setState(() {
      _date = DateTime(picked.year, picked.month, picked.day);
    });
  }

  LogCreate _buildLogCreate() {
    final quantity = ref.read(quantityProvider);
    final note = _noteCtrl.text.trim();
    // Per Ask 10 we record what the user actually typed: the amount
    // in [_enteredUnit] (which the dropdown gates to a unit in the
    // serving's family). `quantity` stays as the serving-multiplier so
    // the snapshot math (`serving.kcal × quantity`) remains stable.
    final servingAmountTotal = _serving.amount * quantity;
    final displayAmount = _enteredUnit == _serving.unit
        ? servingAmountTotal
        : convertUnit(servingAmountTotal, _serving.unit, _enteredUnit);
    return LogCreate(
      foodId: widget.food.id,
      servingId: _serving.id,
      consumedOn: _date,
      meal: _meal,
      quantity: quantity,
      enteredAmount: displayAmount,
      enteredUnit: _enteredUnit,
      note: note.isEmpty ? null : note,
    );
  }

  /// Build the sparse [LogPatch] from current form state vs.
  /// `widget.existing!`. Only emits fields that differ from the seed.
  ///
  /// Note semantics — architect §2.4 / PM "Open question 2":
  /// - When the trimmed note is non-empty and differs from the seed,
  ///   emit `note`.
  /// - When the trimmed note is empty **and** the seed had a non-empty
  ///   note, emit `clearNote: true` (server reads `note: null`).
  /// - When the trimmed note is empty **and** the seed was already
  ///   empty/null, omit both `note` and `clearNote` (sparse).
  LogPatch _buildLogPatch() {
    assert(_isEditing, '_buildLogPatch called outside edit mode');
    final ex = widget.existing!;
    final quantity = ref.read(quantityProvider);
    final newNote = _noteCtrl.text.trim();
    final hasNote = newNote.isNotEmpty;
    final originalNote = ex.note;
    final originalHasNote = originalNote != null && originalNote.isNotEmpty;

    // Only emit `note` when the user typed something that differs from
    // the seed. (Re-emitting an unchanged note is wire noise.)
    final String? notePatch =
        hasNote && newNote != originalNote ? newNote : null;
    // `clearNote` fires only when the user blanked a previously-non-null
    // note. If both seed and current are empty, the patch is sparse.
    final bool clearNote = !hasNote && originalHasNote;

    return LogPatch(
      servingId: _serving.id != ex.servingId ? _serving.id : null,
      consumedOn: !_sameDay(_date, ex.consumedOn) ? _date : null,
      meal: _meal != ex.meal ? _meal : null,
      quantity: quantity != ex.quantity ? quantity : null,
      note: notePatch,
      clearNote: clearNote,
    );
  }

  /// True iff every field in the form matches the seed entry. Drives
  /// the "Save changes" enablement guard in edit mode — prevents the
  /// user firing a no-op PATCH.
  bool _isUnchanged() {
    if (!_isEditing) return false;
    final ex = widget.existing!;
    final quantity = ref.read(quantityProvider);
    final newNote = _noteCtrl.text.trim();
    final originalNote = ex.note ?? '';
    return _serving.id == ex.servingId &&
        _sameDay(_date, ex.consumedOn) &&
        _meal == ex.meal &&
        quantity == ex.quantity &&
        newNote == originalNote;
  }

  /// Y/M/D equality. Used by `_buildLogPatch` and the old-date
  /// invalidation branch in `_onEditPressed`.
  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Future<void> _onSavePressed() async {
    if (_submitting) return;
    if (_isEditing) {
      await _onEditPressed();
    } else {
      await _onCreatePressed();
    }
  }

  /// T-24 Case 2 — route-to-effect.
  ///
  /// The natural home of a just-created log entry is the day view for
  /// `consumedOn`, not the food-detail page the user tapped from. The
  /// compact branch's `DraggableScrollableSheet` is a route in the
  /// navigator stack, so `context.go` replaces it implicitly; the
  /// medium/expanded `Dialog` is **not** a route, so we pop the dialog
  /// first then `go` — per T-24's "Dialog-on-expanded sheets that use
  /// `context.go` must `pop()` the dialog first" clause (architect §6.3).
  /// The `_optimisticEntry` return value is dropped — the caller's
  /// `await showLogEntrySheet(...)` future no longer matters because
  /// the user is now on a different route.
  Future<void> _onCreatePressed() async {
    setState(() => _submitting = true);
    final logCreate = _buildLogCreate();
    // Fire the test seam first so callers can observe the constructed
    // payload regardless of which branch (outbox / direct) runs.
    widget.onSubmit(logCreate);

    final messenger = ScaffoldMessenger.maybeOf(context);
    final formFactor = FormFactor.of(context);

    if (formFactor.isCompact) {
      // Outbox path. Enqueue, surface the syncing SnackBar, invalidate
      // provider families, then route-to-effect. The outbox notifier
      // flushes asynchronously; day-summary updates when the server
      // response lands. The optimistic row is rendered on Today via
      // the outbox provider's own optimistic merge — no extra wiring
      // needed for it to appear post-save.
      try {
        await ref
            .read(logOutboxProvider.notifier)
            .enqueue(payload: logCreate.toJson());
        messenger?.showSnackBar(
          const SnackBar(content: Text('Logged — syncing')),
        );
        if (!mounted) return;
        // Invalidate provider families so any optimistic merge re-runs.
        // Safe to invalidate here; the outbox notifier owns the
        // persisted state.
        ref
          ..invalidate(daySummaryProvider(_date))
          ..invalidate(logEntriesProvider(_date))
          ..invalidate(recentFoodsProvider)
          ..invalidate(frequentFoodsProvider);
        // T-24 Case 2: route-to-effect. `go` replaces the stack to the
        // day-view; the sheet's own route disappears as a side effect
        // on compact (DraggableScrollableSheet is in the same stack).
        context.go(pathForDay(_date));
      } catch (e) {
        if (!mounted) return;
        setState(() => _submitting = false);
        messenger?.showSnackBar(
          SnackBar(content: Text('Could not queue log: $e')),
        );
      }
      return;
    }

    // Medium / expanded: direct repository call. Surface failures
    // inline (T-11) — SnackBar, sheet stays open with input intact.
    try {
      final entry = await ref.read(logRepositoryProvider).create(logCreate);
      if (!mounted) return;
      ref
        ..invalidate(daySummaryProvider(_date))
        ..invalidate(logEntriesProvider(_date))
        ..invalidate(recentFoodsProvider)
        ..invalidate(frequentFoodsProvider);
      // T-24 Case 2 with dialog correction: pop the dialog first, then
      // `go` to the day view. Order matters — without the pop the new
      // page renders under the orphaned dialog frame (architect §6.3 /
      // PM acceptance §2.2). The `context.mounted` check between is
      // defence-in-depth in case the BuildContext is disposed during pop.
      Navigator.of(context).pop<LogEntry?>(entry);
      if (!context.mounted) return;
      context.go(pathForDay(_date));
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not save: $e')),
      );
    }
  }

  /// T-24 Case 2 — route-to-effect.
  ///
  /// The natural home of a just-edited log entry is the day view for
  /// the entry's (possibly new) `consumedOn` — the user wants to see
  /// the row land in its meal section, not stare at the source. The
  /// route target uses `newDate` (the date the user just saved with),
  /// not the original — if the user shifted a May 14 entry to May 15,
  /// they land on `/today/2026-05-15`. Architect §6.5.
  ///
  /// Like `_onCreatePressed`'s expanded branch, this is a pop-first,
  /// `go`-second sequence so the dialog frame doesn't orphan against
  /// the new page when the sheet is rendered as a `showDialog` on
  /// medium/expanded. The pop is harmless on compact (the bottom-sheet
  /// route pops normally; the subsequent `go` then replaces the stack).
  ///
  /// Edit-mode submit. Per architect §2.5 / PM "edits don't queue":
  /// PATCH on every form factor, sheet stays open until the server
  /// returns, failure surfaces inline (T-11). Defence-in-depth note:
  /// even if a caller somehow opens this sheet for a pending-sync
  /// entry, save still goes through `update` (never the outbox).
  Future<void> _onEditPressed() async {
    setState(() => _submitting = true);
    final patch = _buildLogPatch();
    // Fire the test seam — same as create-mode, so tests can observe
    // the constructed `LogCreate` shadow even in edit mode if needed.
    widget.onSubmit(_buildLogCreate());

    // No-op guard: if nothing changed, just pop + route without a
    // network call. The CTA enablement guard should have prevented
    // this, but it's cheap to re-check at submit time. PM acceptance
    // §2.2: "The edit-mode no-op-PATCH branch routes too — the user
    // pressed save and expects to land at Today even if nothing
    // changed."
    if (patch.isEmpty) {
      if (!mounted) return;
      // T-24 Case 2 (dialog ordering): pop the dialog first, then `go`.
      Navigator.of(context).pop<LogEntry?>(widget.existing);
      if (!context.mounted) return;
      context.go(pathForDay(_date));
      return;
    }

    final messenger = ScaffoldMessenger.maybeOf(context);
    final repo = ref.read(logRepositoryProvider);
    final originalDate = widget.existing!.consumedOn;
    final newDate = _date;

    try {
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
      // T-24 Case 2 (dialog ordering): pop first, then `go(newDate)` —
      // never `originalDate`. The `context.mounted` check between is
      // defence in case the BuildContext is disposed during pop.
      Navigator.of(context).pop<LogEntry?>(updated);
      if (!context.mounted) return;
      context.go(pathForDay(newDate));
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not save changes: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final space = context.space;
    final quantity = ref.watch(quantityProvider);
    // Autofocus the quantity stepper only when (a) the sheet is in
    // create mode (edit mode is reviewing pre-filled values, per
    // architect §7.4 / QL-107) and (b) the form factor is compact —
    // popping the system keyboard inside the centered desktop dialog
    // is jarring (per QL-107 dev-ticket constraint).
    final autofocusQuantity =
        !_isEditing && FormFactor.of(context).isCompact;

    return Material(
      color: colors.bg,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.max,
        children: <Widget>[
          if (widget.showGrabber)
            Padding(
              padding: EdgeInsets.symmetric(vertical: space.x2),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.emptyDot,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          _Header(food: widget.food, editing: _isEditing),
          Expanded(
            child: SingleChildScrollView(
              controller: widget.scrollController,
              keyboardDismissBehavior:
                  ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.fromLTRB(
                space.x5,
                space.x2,
                space.x5,
                space.x5,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _SectionLabel(text: 'SERVING'),
                  SizedBox(height: space.x2),
                  _ServingSelect(
                    food: widget.food,
                    selected: _serving,
                    quantity: quantity,
                    onChanged: (s) => setState(() => _serving = s),
                  ),
                  SizedBox(height: space.x4 + 2),
                  _SectionLabel(text: 'AMOUNT'),
                  SizedBox(height: space.x2),
                  // Per Ask 10 the user picks an amount in any unit
                  // that shares a family with the serving. The stepper
                  // shows the amount in the chosen unit; the underlying
                  // `quantityProvider` (the wire's `quantity`
                  // multiplier on the serving) is back-derived via
                  // [convertUnit]. Family invariant: the unit
                  // dropdown only surfaces same-family options, so
                  // `convertUnit` never throws.
                  _AmountAndUnitRow(
                    serving: _serving,
                    enteredUnit: _enteredUnit,
                    autofocusAmount: autofocusQuantity,
                    onUnitChanged: (u) => setState(() => _enteredUnit = u),
                  ),
                  SizedBox(height: space.x2),
                  const QuickMultiplierChips(),
                  SizedBox(height: space.x4 + 2),
                  _SectionLabel(text: 'MEAL'),
                  SizedBox(height: space.x2),
                  MealChipPicker(
                    value: _meal,
                    onChanged: (m) => setState(() => _meal = m),
                  ),
                  SizedBox(height: space.x4 + 2),
                  _SectionLabel(text: 'DATE'),
                  SizedBox(height: space.x2),
                  _DateRow(
                    date: _date,
                    onTap: _pickDate,
                  ),
                  SizedBox(height: space.x4 + 2),
                  _SectionLabel(text: 'NOTE (OPTIONAL)'),
                  SizedBox(height: space.x2),
                  _NoteField(controller: _noteCtrl),
                  SizedBox(height: space.x4 + 2),
                  LogPreviewBlock(
                    food: widget.food,
                    serving: _serving,
                    quantity: quantity,
                  ),
                ],
              ),
            ),
          ),
          _Footer(
            submitting: _submitting,
            // In edit mode disable until the form differs from the
            // seed — prevents firing a no-op PATCH. Create mode is
            // always enabled (today's behaviour).
            disabled: _isEditing && _isUnchanged(),
            label: _isEditing ? 'Save changes' : 'Save to log',
            onSave: _onSavePressed,
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.food, this.editing = false});
  final Food food;

  /// In edit mode the header appends a small `(editing)` suffix in
  /// `text.meta` / `ink2` style below the food name. Architect §2.3 —
  /// no new tokens, no `IconButton36`, just one extra `Text`.
  final bool editing;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final space = context.space;
    final brand = <String>[
      if (food.brand != null && food.brand!.isNotEmpty) food.brand!,
      _sourceLabel(food.source.wire),
    ].join(' · ');
    return Padding(
      padding: EdgeInsets.fromLTRB(
        space.x5,
        space.x1 + 2,
        space.x5,
        space.x3,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (brand.isNotEmpty)
                  Text(
                    brand.toUpperCase(),
                    style: context.text.eyebrow.copyWith(
                      color: colors.ink2,
                    ),
                  ),
                SizedBox(height: space.x05),
                Text(
                  food.name,
                  style: context.text.title.copyWith(fontSize: 20),
                ),
                if (editing) ...<Widget>[
                  SizedBox(height: space.x05),
                  Text(
                    '(editing)',
                    key: const Key('log_entry_header_editing_suffix'),
                    style: context.text.meta.copyWith(color: colors.ink2),
                  ),
                ],
              ],
            ),
          ),
          SizedBox(width: space.x3),
          Semantics(
            button: true,
            label: 'Close',
            child: InkResponse(
              onTap: () => Navigator.of(context).maybePop(),
              radius: 24,
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: colors.line2,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(Icons.close, size: 14, color: colors.ink2),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _sourceLabel(String wire) {
    switch (wire) {
      case 'off':
        return 'OpenFoodFacts';
      case 'usda':
        return 'USDA';
      case 'user':
        return 'My foods';
      default:
        return wire;
    }
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: context.text.eyebrow.copyWith(color: context.colors.ink3),
    );
  }
}

/// Serving select. Tap → modal popup with all servings. Renders the
/// current serving name + a "227 g · 130 kcal" subtitle computed from
/// the food panel and the current quantity.
class _ServingSelect extends StatelessWidget {
  const _ServingSelect({
    required this.food,
    required this.selected,
    required this.quantity,
    required this.onChanged,
  });

  final Food food;
  final Serving selected;
  final Decimal quantity;
  final ValueChanged<Serving> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = context.radius;
    final space = context.space;
    // Trailing meta: total amount (in the serving's unit) + kcal for
    // this quantity. Per Ask 10 the kcal comes off the serving directly.
    final totalAmount = selected.amount * quantity;
    final kcal = selected.kcal * quantity;

    return InkResponse(
      onTap: () async {
        final result = await showModalBottomSheet<Serving>(
          context: context,
          builder: (ctx) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (final s in food.servings)
                  ListTile(
                    title: Text(s.name),
                    trailing: s.id == selected.id
                        ? Icon(Icons.check, color: colors.accent)
                        : null,
                    onTap: () => Navigator.of(ctx).pop(s),
                  ),
              ],
            ),
          ),
        );
        if (result != null) onChanged(result);
      },
      child: Container(
        height: 48,
        padding: EdgeInsets.symmetric(horizontal: space.x3 + 2),
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border.all(color: colors.line),
          borderRadius: BorderRadius.circular(radius.r2),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    selected.name,
                    style: context.text.body.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    '${formatAmountUnit(totalAmount, selected.unit)} · ${_trimDecimal(kcal.round(scale: 0))} kcal',
                    style: context.text.meta.copyWith(
                      fontSize: 11,
                      color: colors.ink2,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.keyboard_arrow_down, color: colors.ink3, size: 18),
          ],
        ),
      ),
    );
  }

  String _trimDecimal(Decimal v) {
    final s = v.toString();
    if (!s.contains('.')) return s;
    return s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }
}

class _NoteField extends StatelessWidget {
  const _NoteField({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = context.radius;
    final space = context.space;
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(radius.r2),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: space.x3 + 2,
        vertical: space.x2 + 2,
      ),
      child: TextField(
        controller: controller,
        maxLines: 2,
        textInputAction: TextInputAction.done,
        style: context.text.body.copyWith(color: colors.ink2),
        decoration: InputDecoration(
          isCollapsed: true,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: EdgeInsets.zero,
          hintText: 'After yoga, before the meeting…',
          hintStyle: context.text.body.copyWith(color: colors.ink3),
        ),
      ),
    );
  }
}

/// Sticky bottom CTA. T-12: lives inside a `BottomAppBar`-shaped footer
/// with a top divider; NOT floating.
class _Footer extends StatelessWidget {
  const _Footer({
    required this.submitting,
    required this.onSave,
    required this.label,
    this.disabled = false,
  });

  final bool submitting;
  final VoidCallback onSave;

  /// CTA label. "Save to log" in create mode; "Save changes" in edit
  /// mode. Promoted to a constructor param per architect §2.3.
  final String label;

  /// External enablement gate. Edit mode passes `_isEditing &&
  /// _isUnchanged()` so the button greys out for no-op PATCH attempts.
  /// Create mode passes `false` (today's behaviour).
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final space = context.space;
    final radius = context.radius;
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.line)),
      ),
      padding: EdgeInsets.fromLTRB(
        space.x5,
        space.x3 + 2,
        space.x5,
        MediaQuery.viewInsetsOf(context).bottom > 0
            ? space.x3 + 2
            : space.x6 + space.x1,
      ),
      child: SizedBox(
        height: 54,
        width: double.infinity,
        child: FilledButton(
          key: const Key('log_entry_save_button'),
          onPressed: (submitting || disabled) ? null : onSave,
          style: FilledButton.styleFrom(
            backgroundColor: colors.accent,
            foregroundColor: colors.surface,
            disabledBackgroundColor: colors.accent.withValues(alpha: 0.6),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radius.r3),
            ),
            textStyle: context.text.bodyStrong.copyWith(fontSize: 16),
          ),
          child: submitting ? const _SaveButtonSkeleton() : Text(label),
        ),
      ),
    );
  }
}

/// Button-level loading affordance for T-08 / T-13. The submit flow
/// used to spin a `CircularProgressIndicator` here; T-013 swaps it for
/// a static skeleton bar that communicates "work-in-flight" without a
/// ticker — and without the test-suite friction of an indefinite
/// animation (`pumpAndSettle` finishes cleanly). Mirrors `_ButtonSkeleton`
/// in `custom_food_screen.dart`.
class _SaveButtonSkeleton extends StatelessWidget {
  const _SaveButtonSkeleton();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 96,
      height: 12,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: ColoredBox(
          color: context.colors.surface.withValues(alpha: 0.35),
        ),
      ),
    );
  }
}

/// QL-107 — DATE row inside `LogEntrySheet`. Mirrors
/// `log_weight_sheet.dart`'s `_DateRow` shape: a full-width tap target
/// (≥ 44 px tall — T-06 floor) rendering the current date with a
/// calendar leading icon and a chevron trailing affordance.
///
/// Label wording per architect §7.7 / QL-107:
/// - `"Today · MMM d"` when `date` is today (DateFormat `MMM d` —
///   e.g. `"Today · May 14"`).
/// - `"EEE, MMM d"` otherwise (e.g. `"Wed, May 14"`).
class _DateRow extends StatelessWidget {
  const _DateRow({required this.date, required this.onTap});

  final DateTime date;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final isToday = now.year == date.year &&
        now.month == date.month &&
        now.day == date.day;
    final label = isToday
        ? 'Today · ${DateFormat('MMM d').format(date)}'
        : DateFormat('EEE, MMM d').format(date);
    final colors = context.colors;
    final radius = context.radius;
    final space = context.space;

    return Semantics(
      button: true,
      label: 'Date: $label. Tap to change.',
      child: InkWell(
        key: const Key('log_entry_date_row'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(radius.r2),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: EdgeInsets.symmetric(
            horizontal: space.x3 + 2,
            vertical: space.x2 + 2,
          ),
          decoration: BoxDecoration(
            color: colors.surface,
            border: Border.all(color: colors.line),
            borderRadius: BorderRadius.circular(radius.r2),
          ),
          child: Row(
            children: <Widget>[
              Icon(
                Icons.calendar_today_outlined,
                size: 18,
                color: colors.ink2,
              ),
              SizedBox(width: space.x2),
              Expanded(
                child: Text(
                  label,
                  key: const Key('log_entry_date_row_label'),
                  style: context.text.body.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: 18,
                color: colors.ink3,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

LogCreate _logCreateFromPayload(Map<String, dynamic> json) {
  return LogCreate(
    foodId: json['food_id'] as String,
    servingId: json['serving_id'] as String,
    consumedOn: DateTime.parse(json['consumed_on'] as String),
    meal: Meal.fromWire(json['meal'] as String),
    quantity: Decimal.parse((json['quantity'] as Object).toString()),
    enteredAmount:
        Decimal.parse((json['entered_amount'] as Object).toString()),
    enteredUnit: Unit.fromWire(json['entered_unit'] as String),
    note: json['note'] as String?,
  );
}

/// Amount stepper + Unit dropdown side-by-side. The dropdown only
/// surfaces same-family units; for count-family servings the
/// dropdown collapses to a plain unit label (count units don't
/// auto-convert between each other, per Ask 10).
///
/// State source-of-truth is the scoped [quantityProvider]
/// (multiplier on the serving). The displayed amount is
/// `serving.amount × quantity` converted into the user's chosen
/// unit; editing the amount back-computes a new quantity via the
/// inverse conversion.
class _AmountAndUnitRow extends ConsumerWidget {
  const _AmountAndUnitRow({
    required this.serving,
    required this.enteredUnit,
    required this.onUnitChanged,
    this.autofocusAmount = false,
  });

  final Serving serving;
  final Unit enteredUnit;
  final ValueChanged<Unit> onUnitChanged;
  final bool autofocusAmount;

  /// Units we offer in the dropdown given the serving's family. Count
  /// family returns a single-element list (just the serving's own
  /// unit) — count units don't auto-convert.
  List<Unit> _unitsInFamily() {
    if (serving.unit.family == UnitFamily.count) {
      return <Unit>[serving.unit];
    }
    return <Unit>[
      for (final u in Unit.values)
        if (u.family == serving.unit.family) u,
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quantity = ref.watch(quantityProvider);
    final colors = context.colors;
    final radius = context.radius;
    final space = context.space;

    final servingAmountTotal = serving.amount * quantity;
    final displayAmount = enteredUnit == serving.unit
        ? servingAmountTotal
        : convertUnit(servingAmountTotal, serving.unit, enteredUnit);

    final units = _unitsInFamily();
    final showDropdown = units.length > 1;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          flex: showDropdown ? 6 : 8,
          child: QuantityStepper(
            key: const Key('log_entry_amount_field_host'),
            value: displayAmount,
            step: _stepFor(enteredUnit),
            min: Decimal.zero,
            unitSuffix: enteredUnit.shortLabel,
            autofocus: autofocusAmount,
            onChanged: (next) {
              if (next == null) return;
              // Convert the user's typed amount back to the serving's
              // own unit, then divide by the serving's amount to get
              // the new quantity multiplier. Same-family invariant
              // makes `convertUnit` safe here.
              final inServingUnit = enteredUnit == serving.unit
                  ? next
                  : convertUnit(next, enteredUnit, serving.unit);
              final newQuantity = (inServingUnit / serving.amount)
                  .toDecimal(scaleOnInfinitePrecision: 6);
              ref.read(quantityProvider.notifier).state = newQuantity;
            },
          ),
        ),
        if (showDropdown) ...<Widget>[
          SizedBox(width: space.x2),
          Expanded(
            flex: 3,
            child: Container(
              height: 44,
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(radius.r1 + 2),
                border: Border.all(color: colors.line, width: 1),
              ),
              padding: EdgeInsets.symmetric(horizontal: space.x2),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<Unit>(
                  key: const Key('log_entry_unit_dropdown'),
                  value: enteredUnit,
                  isExpanded: true,
                  isDense: true,
                  icon: Icon(Icons.expand_more, size: 18, color: colors.ink2),
                  style: context.text.body.copyWith(color: colors.ink),
                  dropdownColor: colors.surface,
                  items: <DropdownMenuItem<Unit>>[
                    for (final u in units)
                      DropdownMenuItem<Unit>(
                        value: u,
                        child: Text(u.shortLabel),
                      ),
                  ],
                  onChanged: (v) {
                    if (v == null || v == enteredUnit) return;
                    onUnitChanged(v);
                  },
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// Per-unit step size. Mass/volume canonical units get fine-grained
  /// steps (1 g / 1 ml); coarser units (cup, lb) step by 0.25. Count
  /// units step by 0.5 (matches the original quantity-stepper behavior).
  Decimal _stepFor(Unit unit) {
    switch (unit) {
      case Unit.g:
      case Unit.ml:
        return Decimal.one;
      case Unit.kg:
      case Unit.l:
      case Unit.lb:
        return Decimal.parse('0.1');
      case Unit.oz:
      case Unit.cup:
      case Unit.flOz:
        return Decimal.parse('0.25');
      case Unit.tbsp:
      case Unit.tsp:
        return Decimal.parse('0.5');
      case Unit.serving:
      case Unit.piece:
        return Decimal.parse('0.5');
    }
  }
}
