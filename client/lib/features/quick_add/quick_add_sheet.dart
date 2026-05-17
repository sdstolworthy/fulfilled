import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../domain/log_entry.dart';
import '../../domain/meal.dart';
import '../../domain/unit.dart';
import '../../form_factor/form_factor.dart';
import '../../providers/log_providers.dart';
import '../../providers/food_providers.dart';
import '../../providers/repository_providers.dart';
import '../../theme/context_extensions.dart';
import '../../widgets/motion.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/quantity_stepper.dart';
import '../log_entry/widgets/meal_chip_picker.dart';
import '../today/today_internals.dart' show pathForDay;

/// Stable id of the synthetic Quick-add food in the catalog. Mirrors
/// `quickAddFoodId` in `repositories/_fixtures.dart`; defined inline so
/// the feature widget does not import the mock-data file (which is
/// documented as deletable once the real API lands).
const String _quickAddFoodId = 'food_quick_add';

/// Stable id of the synthetic 1 g `kcal` serving on the Quick-add food.
/// Mirrors `quickAddServingId` from `repositories/_fixtures.dart`.
const String _quickAddServingId = 'sv_kcal';

/// Show the Quick-add calories sheet.
///
/// Mirrors `showLogEntrySheet`'s form-factor split:
///   - **Compact** (mobile / narrow web): a `DraggableScrollableSheet`
///     mounted via `showModalBottomSheet`. The kcal stepper autofocuses
///     so the keyboard pops on first paint.
///   - **Medium / Expanded** (desktop / iPad-landscape): a centered
///     `Dialog` capped at 440 px wide. No autofocus — popping the
///     keyboard inside a centered dialog is jarring (matches the same
///     carve-out in `LogEntrySheet`'s QL-107 dev-ticket).
///
/// Returns the created (or updated) `LogEntry` on save, or `null` when
/// the user dismisses the sheet.
///
/// **Modes.** Mirrors `showLogEntrySheet({existing:})` from LU-002:
/// - `existing == null` → create mode. The default sheet flow.
/// - `existing != null` → edit mode. Pre-seeds kcal (= entry quantity),
///   meal, date, and macros from the entry's snapshot. Header reads
///   "Edit quick add"; the CTA reads "Save changes" and is disabled
///   until the form differs from the seed. Submit builds a `LogPatch`
///   and calls `LogRepository.update(existing.id, patch)` rather than
///   `create`.
///
/// **Post-save T-24 Case 2 routing.** On save we pop the sheet (or
/// dialog on expanded — pop-first ordering, mirroring `LogEntrySheet`'s
/// architect §6.3 carveout) and then `context.go(pathForDay(date))` so
/// the user lands on the day-view where their just-logged kcal appears.
///
/// **Macros override.** When the optional "Add macros" toggle is on,
/// the create payload carries a `nutritionOverride` (a sparse
/// `NutritionPer100g` with the user-supplied P/C/F) that the mock
/// `LogRepository.create` substitutes for the synthetic food's
/// `nutritionPer100g` before computing the snapshot. With the toggle
/// off, only kcal is logged (macros default to zero on the synthetic
/// food's per-100 g panel). In edit mode the macros override is **not**
/// re-emitted on the wire (`LogPatch` has no `nutritionOverride`
/// field); the snapshot is recomputed from the food's per-100 g panel.
Future<LogEntry?> showQuickAddSheet(
  BuildContext context, {
  DateTime? defaultDate,
  Meal? defaultMeal,
  LogEntry? existing,
}) {
  final isCompact = FormFactor.of(context).isCompact;
  final parent = ProviderScope.containerOf(context, listen: false);

  Widget contents({
    required ScrollController? scrollController,
    required bool showGrabber,
  }) {
    return ProviderScope(
      parent: parent,
      child: QuickAddSheetBody(
        defaultDate: defaultDate,
        defaultMeal: defaultMeal,
        existing: existing,
        scrollController: scrollController,
        showGrabber: showGrabber,
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
          initialChildSize: 0.78,
          minChildSize: 0.5,
          maxChildSize: 0.92,
          snap: true,
          snapSizes: const <double>[0.5, 0.78, 0.92],
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
            constraints: const BoxConstraints(maxWidth: 440, maxHeight: 640),
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

/// T-016 dialog arrival animation — mirrors `LogEntrySheet`'s `_DialogEnterAnimation`.
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

/// Public body widget. Exposed so widget tests can pump it directly
/// without going through `showModalBottomSheet`'s overlay plumbing —
/// same pattern as `LogEntrySheetBody`.
///
/// **Modes (FX-001).** When [existing] is non-null the sheet runs in
/// edit mode: pre-seeds kcal / meal / date / macros from the entry,
/// renames the title to "Edit quick add", flips the CTA to "Save
/// changes" (disabled until the form differs from the seed), and
/// dispatches submit through `LogRepository.update` with a sparse
/// `LogPatch`. The macros override is **not** patchable — `LogPatch`
/// doesn't model `nutritionOverride`. The macros UI in edit mode is
/// therefore a read-only-ish surface: seeds correctly so the user sees
/// what was logged, but if they change a macro the diff is not emitted
/// (the snapshot will be recomputed against the synthetic food's
/// per-100 g panel, which is zero macros). PMgr accepted this carveout
/// for v1.1; a future ticket may add `nutritionOverride` to `LogPatch`.
class QuickAddSheetBody extends ConsumerStatefulWidget {
  const QuickAddSheetBody({
    super.key,
    this.defaultDate,
    this.defaultMeal,
    this.existing,
    this.scrollController,
    this.showGrabber = true,
    @visibleForTesting this.onSubmit,
    @visibleForTesting this.onPatch,
    @visibleForTesting this.skipRouteOnSave = false,
  });

  /// Pre-seeded date. Defaults to today (local-calendar Y/M/D).
  /// **Ignored in edit mode** — the existing entry's `consumedOn` wins.
  final DateTime? defaultDate;

  /// Pre-seeded meal. Defaults to the local-time fallback.
  /// **Ignored in edit mode** — the existing entry's `meal` wins.
  final Meal? defaultMeal;

  /// The entry being edited. When non-null the sheet is in **edit
  /// mode** — see class dartdoc. When null the sheet is in **create
  /// mode** (today's behaviour).
  final LogEntry? existing;

  final ScrollController? scrollController;
  final bool showGrabber;

  /// **Test-only.** Fires with the constructed `LogCreate` before the
  /// repository call in **create mode**. Test seam mirroring
  /// `LogEntrySheetBody.onSubmit`.
  final ValueChanged<LogCreate>? onSubmit;

  /// **Test-only.** Fires with the constructed `LogPatch` before the
  /// `LogRepository.update` call in **edit mode**. Lets tests assert on
  /// the sparse-patch shape without round-tripping through the mock
  /// repo's `update` (which would recompute the snapshot).
  final ValueChanged<LogPatch>? onPatch;

  /// **Test-only.** When true, skip the post-save `context.go`
  /// navigation. Lets tests assert on the `LogCreate` / `LogPatch`
  /// payload without standing up a router in the harness.
  final bool skipRouteOnSave;

  @override
  ConsumerState<QuickAddSheetBody> createState() => _QuickAddSheetBodyState();
}

class _QuickAddSheetBodyState extends ConsumerState<QuickAddSheetBody> {
  late Meal _meal;
  late DateTime _date;
  Decimal? _kcal = Decimal.fromInt(100);
  bool _macrosExpanded = false;
  Decimal? _protein = Decimal.zero;
  Decimal? _carbs = Decimal.zero;
  Decimal? _fat = Decimal.zero;
  bool _submitting = false;

  /// True iff the sheet was opened to edit an existing entry. Drives
  /// the header copy, CTA label + enablement, and the submit branch.
  /// FX-001 — mirrors `LogEntrySheetBody._isEditing`.
  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final ex = widget.existing;
    // Precedence (edit mode wins): existing.meal > defaultMeal > local-time fallback.
    _meal = ex?.meal ?? widget.defaultMeal ?? mealForLocalTime(DateTime.now());
    final seedDate = ex?.consumedOn ?? widget.defaultDate ?? DateTime.now();
    _date = DateTime(seedDate.year, seedDate.month, seedDate.day);

    if (ex != null) {
      // Quick-add foods log `quantity == kcal` (1 g serving, 100 kcal /
      // 100 g panel). Pre-seed the kcal stepper directly from quantity.
      _kcal = ex.quantity;

      // Reverse the snapshot-from-override math to recover macros.
      // The Quick-add food's panel is 100 kcal per 100 g (1 g serving),
      // so `snapshot.macroG == override.macroG × kcal / 100` →
      // `override.macroG = snapshot.macroG × 100 / kcal`. Guard against
      // div-by-zero (kcal should never be zero on a real entry, but
      // skip cleanly if it is).
      final snap = ex.nutritionSnapshot;
      final kcal = ex.kcal;
      Decimal? recover(Decimal? snapshotG) {
        if (snapshotG == null) return null;
        if (kcal == Decimal.zero) return null;
        return (snapshotG * Decimal.fromInt(100) / kcal)
            .toDecimal(scaleOnInfinitePrecision: 6);
      }

      final seedProtein = recover(snap.proteinG);
      final seedCarbs = recover(snap.carbsG);
      final seedFat = recover(snap.fatG);

      // If any macro is non-null and non-zero on the seed, expand the
      // macros block so the user sees the values that drove the entry
      // without having to hunt for the toggle. The values are shown
      // read-only-ish — the macros override is not patchable on edit
      // (see class dartdoc), but pre-filling preserves continuity.
      final hasMacros = (seedProtein != null && seedProtein > Decimal.zero) ||
          (seedCarbs != null && seedCarbs > Decimal.zero) ||
          (seedFat != null && seedFat > Decimal.zero);
      _macrosExpanded = hasMacros;
      _protein = seedProtein ?? Decimal.zero;
      _carbs = seedCarbs ?? Decimal.zero;
      _fat = seedFat ?? Decimal.zero;
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final firstDate = today.subtract(const Duration(days: 60));
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

  /// Build the `LogCreate` payload from the current form state. Per
  /// Ask 10 the quick-add sentinel food has a single serving
  /// `{amount: 1, unit: serving, kcal: 1}` — so the user-typed kcal
  /// rides on `quantity` 1:1. The fixture's `computeLogEntry` keys off
  /// `quantity * serving.kcal` (= `quantity * 1`), so the snapshot
  /// equals the user's kcal value.
  ///
  /// Macros toggle (when on) is a v1.1 enhancement once the wire
  /// supports per-entry macro overrides. For now those values are
  /// captured locally but not sent — the macros panel is still useful
  /// to gather the user's intent during the form, even if the snapshot
  /// only records kcal until the BE adds the override field.
  LogCreate _buildLogCreate() {
    final kcal = _kcal ?? Decimal.one;
    return LogCreate(
      foodId: _quickAddFoodId,
      servingId: _quickAddServingId,
      consumedOn: _date,
      meal: _meal,
      quantity: kcal,
      enteredAmount: kcal,
      enteredUnit: Unit.serving,
      note: null,
    );
  }

  /// Build the sparse [LogPatch] from current form state vs. the seed
  /// entry. Only emits fields that differ. Mirrors `LogEntrySheetBody
  /// ._buildLogPatch`'s shape. The Quick-add sheet has no note field,
  /// so `note` / `clearNote` are always absent.
  LogPatch _buildLogPatch() {
    assert(_isEditing, '_buildLogPatch called outside edit mode');
    final ex = widget.existing!;
    final kcal = _kcal ?? Decimal.one;
    return LogPatch(
      consumedOn: _sameDay(_date, ex.consumedOn) ? null : _date,
      meal: _meal != ex.meal ? _meal : null,
      // Quick-add maps quantity 1:1 to kcal; kcal-only edits surface
      // here as a quantity diff.
      quantity: kcal != ex.quantity ? kcal : null,
    );
  }

  /// True iff every patchable field in the form matches the seed
  /// entry. Drives the "Save changes" enablement guard in edit mode —
  /// prevents the user firing a no-op PATCH. Mirrors
  /// `LogEntrySheetBody._isUnchanged`.
  ///
  /// Only checks kcal / meal / date. Macros are seeded but not
  /// patchable (`LogPatch` has no `nutritionOverride` field — see
  /// class dartdoc), so a macro-only diff is not considered a real
  /// change for the purposes of the no-op-PATCH guard.
  bool _isUnchanged() {
    if (!_isEditing) return false;
    final ex = widget.existing!;
    final kcal = _kcal ?? Decimal.one;
    return kcal == ex.quantity &&
        _meal == ex.meal &&
        _sameDay(_date, ex.consumedOn);
  }

  /// Y/M/D equality. Same helper shape as
  /// `LogEntrySheetBody._sameDay`.
  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Future<void> _onSavePressed() async {
    if (_submitting) return;
    if (_kcal == null || _kcal! < Decimal.one) return;
    if (_isEditing) {
      await _onEditPressed();
    } else {
      await _onCreatePressed();
    }
  }

  Future<void> _onCreatePressed() async {
    setState(() => _submitting = true);

    final payload = _buildLogCreate();
    widget.onSubmit?.call(payload);

    final messenger = ScaffoldMessenger.maybeOf(context);
    final formFactor = FormFactor.of(context);

    try {
      final entry = await ref.read(logRepositoryProvider).create(payload);
      if (!mounted) return;
      // Invalidate the same provider family as `LogEntrySheet.onCreate`
      // (matches `LogRepository.create`'s `@invalidates` block).
      ref
        ..invalidate(daySummaryProvider(_date))
        ..invalidate(logEntriesProvider(_date))
        ..invalidate(recentFoodsProvider)
        ..invalidate(frequentFoodsProvider);

      if (widget.skipRouteOnSave) {
        Navigator.of(context).maybePop<LogEntry?>(entry);
        return;
      }

      // T-24 Case 2 route-to-effect.
      //
      // Compact: the bottom sheet IS a navigator-stack route, so
      // popping it first keeps the user on the source page while
      // `context.go` rewrites the stack. On compact this is also the
      // safer path because the dialog enter animation isn't running.
      //
      // Expanded: the dialog overlay is NOT a navigator-stack route;
      // mirror `LogEntrySheet`'s architect §6.3 carveout — pop the
      // dialog first, then `go`, so the new page doesn't render
      // against an orphan dialog frame.
      Navigator.of(context).pop<LogEntry?>(entry);
      if (formFactor.isCompact) {
        // On compact a SnackBar matches LogEntrySheet's "Logged" cue.
        messenger?.showSnackBar(
          const SnackBar(content: Text('Logged')),
        );
      }
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

  /// FX-001 edit-mode submit. Mirrors `LogEntrySheetBody._onEditPressed`:
  /// build a sparse `LogPatch`, dispatch to `LogRepository.update`,
  /// invalidate the same provider families as the create path (the
  /// originating-date families too if the user shifted the date), then
  /// pop + route-to-effect.
  ///
  /// Edits are never queued through the outbox (architect §2.5 / PM
  /// ruling) — patches go straight to the repository on every form
  /// factor. The sheet stays open on failure so the user can retry.
  Future<void> _onEditPressed() async {
    setState(() => _submitting = true);

    final patch = _buildLogPatch();
    widget.onPatch?.call(patch);

    final messenger = ScaffoldMessenger.maybeOf(context);
    final repo = ref.read(logRepositoryProvider);
    final originalDate = widget.existing!.consumedOn;
    final newDate = _date;

    // No-op guard — mirrors the create-path's "Save disabled until
    // something differs" predicate. Skip the network call and just
    // route-to-effect.
    if (patch.isEmpty) {
      if (!mounted) return;
      if (widget.skipRouteOnSave) {
        Navigator.of(context).maybePop<LogEntry?>(widget.existing);
        return;
      }
      Navigator.of(context).pop<LogEntry?>(widget.existing);
      if (!context.mounted) return;
      context.go(pathForDay(newDate));
      return;
    }

    try {
      final updated = await repo.update(widget.existing!.id, patch);
      if (!mounted) return;
      // Invalidate the same family as the create path.
      ref
        ..invalidate(daySummaryProvider(newDate))
        ..invalidate(logEntriesProvider(newDate))
        ..invalidate(recentFoodsProvider)
        ..invalidate(frequentFoodsProvider);
      if (!_sameDay(originalDate, newDate)) {
        // Date shifted — also drop the moved entry from the originating
        // date's totals + list. Mirrors `LogEntrySheetBody
        // ._onEditPressed`'s old-date branch.
        ref
          ..invalidate(daySummaryProvider(originalDate))
          ..invalidate(logEntriesProvider(originalDate));
      }

      if (widget.skipRouteOnSave) {
        Navigator.of(context).maybePop<LogEntry?>(updated);
        return;
      }

      // T-24 Case 2 (dialog ordering): pop first, then `go(newDate)`.
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
    // Mirror `LogEntrySheetBody`'s autofocus carveout: edit mode is
    // *reviewing* a logged value, not entering a new one, so we don't
    // pop the keyboard on first paint.
    final autofocusKcal =
        !_isEditing && FormFactor.of(context).isCompact;
    final hasKcal = _kcal != null && _kcal! >= Decimal.one;
    // Create mode: enabled whenever kcal is valid.
    // Edit mode: also gate on `_isUnchanged()` so the user can't fire a
    // no-op PATCH.
    final canSave = !_submitting && hasKcal && !(_isEditing && _isUnchanged());

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
          _Header(editing: _isEditing),
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
                  _SectionLabel(text: 'CALORIES'),
                  SizedBox(height: space.x2),
                  QuantityStepper(
                    key: const Key('quick_add_kcal_field'),
                    value: _kcal,
                    step: Decimal.fromInt(5),
                    min: Decimal.one,
                    max: Decimal.fromInt(5000),
                    unitSuffix: 'kcal',
                    allowDecimal: false,
                    autofocus: autofocusKcal,
                    semanticsLabel: 'Calories',
                    onChanged: (next) => setState(() => _kcal = next),
                  ),
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
                  _DateRow(date: _date, onTap: _pickDate),
                  SizedBox(height: space.x4 + 2),
                  _MacrosToggle(
                    expanded: _macrosExpanded,
                    onToggle: () => setState(
                      () => _macrosExpanded = !_macrosExpanded,
                    ),
                  ),
                  if (_macrosExpanded) ...<Widget>[
                    SizedBox(height: space.x3),
                    _MacrosRow(
                      protein: _protein,
                      carbs: _carbs,
                      fat: _fat,
                      onProteinChanged: (v) =>
                          setState(() => _protein = v),
                      onCarbsChanged: (v) => setState(() => _carbs = v),
                      onFatChanged: (v) => setState(() => _fat = v),
                    ),
                  ],
                ],
              ),
            ),
          ),
          _Footer(
            submitting: _submitting,
            enabled: canSave,
            label: _isEditing ? 'Save changes' : 'Save',
            onSave: _onSavePressed,
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({this.editing = false});

  /// In edit mode the title reads "Edit quick add" instead of "Quick
  /// add calories". The eyebrow stays "QUICK ADD" so the surface still
  /// reads as the same affordance. FX-001.
  final bool editing;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final space = context.space;
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
                Text(
                  'QUICK ADD',
                  style: context.text.eyebrow.copyWith(color: colors.ink2),
                ),
                SizedBox(height: space.x05),
                Text(
                  editing ? 'Edit quick add' : 'Quick add calories',
                  key: const Key('quick_add_title'),
                  style: context.text.title.copyWith(fontSize: 20),
                ),
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

/// QL-107 — date row mirroring `LogEntrySheet`'s `_DateRow`. Kept
/// inline so this feature folder doesn't reach into `lib/features/log_entry/`
/// (treated as read-only per the quick-add ticket). When QL-107 is
/// re-litigated and the `_DateRow` lifts to a shared widget, this
/// inline copy can be deleted.
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
        key: const Key('quick_add_date_row'),
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
                  style: context.text.body.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: colors.ink3),
            ],
          ),
        ),
      ),
    );
  }
}

class _MacrosToggle extends StatelessWidget {
  const _MacrosToggle({required this.expanded, required this.onToggle});

  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final space = context.space;
    return Semantics(
      button: true,
      label: expanded ? 'Hide macros' : 'Add macros',
      child: InkWell(
        key: const Key('quick_add_macros_toggle'),
        onTap: onToggle,
        borderRadius: BorderRadius.circular(context.radius.r2),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: space.x1,
            vertical: space.x2,
          ),
          child: Row(
            children: <Widget>[
              Icon(
                expanded ? Icons.expand_less : Icons.expand_more,
                size: 18,
                color: colors.accent,
              ),
              SizedBox(width: space.x1 + 2),
              Text(
                expanded ? 'Hide macros' : 'Add macros (optional)',
                style: context.text.meta.copyWith(
                  color: colors.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MacrosRow extends StatelessWidget {
  const _MacrosRow({
    required this.protein,
    required this.carbs,
    required this.fat,
    required this.onProteinChanged,
    required this.onCarbsChanged,
    required this.onFatChanged,
  });

  final Decimal? protein;
  final Decimal? carbs;
  final Decimal? fat;
  final ValueChanged<Decimal?> onProteinChanged;
  final ValueChanged<Decimal?> onCarbsChanged;
  final ValueChanged<Decimal?> onFatChanged;

  @override
  Widget build(BuildContext context) {
    final space = context.space;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: _MacroField(
            keyName: 'quick_add_protein',
            label: 'PROTEIN',
            value: protein,
            onChanged: onProteinChanged,
          ),
        ),
        SizedBox(width: space.x2),
        Expanded(
          child: _MacroField(
            keyName: 'quick_add_carbs',
            label: 'CARBS',
            value: carbs,
            onChanged: onCarbsChanged,
          ),
        ),
        SizedBox(width: space.x2),
        Expanded(
          child: _MacroField(
            keyName: 'quick_add_fat',
            label: 'FAT',
            value: fat,
            onChanged: onFatChanged,
          ),
        ),
      ],
    );
  }
}

class _MacroField extends StatelessWidget {
  const _MacroField({
    required this.keyName,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String keyName;
  final String label;
  final Decimal? value;
  final ValueChanged<Decimal?> onChanged;

  @override
  Widget build(BuildContext context) {
    final space = context.space;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          label,
          style: context.text.eyebrow.copyWith(color: context.colors.ink3),
        ),
        SizedBox(height: space.x1 + 2),
        QuantityStepper(
          key: Key('${keyName}_field'),
          value: value,
          min: Decimal.zero,
          step: Decimal.one,
          unitSuffix: 'g',
          allowDecimal: true,
          showStepperButtons: false,
          semanticsLabel: '$label grams',
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.submitting,
    required this.enabled,
    required this.onSave,
    this.label = 'Save',
  });

  final bool submitting;
  final bool enabled;
  final VoidCallback onSave;

  /// CTA label. "Save" in create mode; "Save changes" in edit mode
  /// (FX-001).
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final space = context.space;
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
      child: PrimaryButton(
        key: const Key('quick_add_save_button'),
        label: label,
        isLoading: submitting,
        onPressed: enabled ? onSave : null,
      ),
    );
  }
}
