import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../domain/log_entry.dart';
import '../../../domain/meal.dart';
import '../../../domain/units/energy.dart';
import '../../../form_factor/form_factor.dart';
import '../../../providers/log_providers.dart';
import '../../../providers/repository_providers.dart';
import '../../../theme/context_extensions.dart';
import '../../../widgets/icon_button_36.dart';
import '../../../widgets/primary_button.dart';
import '../today_internals.dart' show pathForDay;

/// Bottom sheet (compact) / dialog (expanded) shaped form for
/// `POST /log/copy`. F1 from `architect_ux_pack.md` §3 / PM UX pack
/// §2 F1.
///
/// Two entry points exist in UX-106 (parallel ticket — surfaces wire
/// in):
///
/// 1. **Per-meal copy** — from `MealSection.onCopyMeal`. The sheet
///    opens with `preselectMeals = [meal]` pre-selected as a single
///    chip. The user may broaden to "All meals" or pick a different
///    single meal; the date stepper defaults to `targetDate - 1`.
/// 2. **Whole-day copy** — from `_EmptyDayPill`'s "Copy from another
///    day" affordance. The sheet opens with no meal filter (`null`,
///    rendering "All meals" pre-selected) and the date stepper at
///    `targetDate - 1`.
///
/// **Post-save (T-24 Case 2 — route-to-effect).** On success,
/// `Navigator.pop()` the sheet/dialog then `context.go(
/// pathForDay(targetDate))`. The dialog-on-expanded pop-first rule
/// from T-24 applies (architect_qol.md §3.3).
///
/// **Partial-skip** (server contract — see openapi.yaml lines
/// 679–687): when `result.length < requestedCount`, the SnackBar
/// reads `"Copied N of M — K skipped (food no longer available)"`.
/// Sheet still closes; user lands on Today with the partial copy
/// applied.
///
/// **Failure** (T-11): SnackBar with retry affordance; sheet stays
/// open with input intact. Submit re-enables.
///
/// Returns the list of created entries, or `null` if the sheet was
/// dismissed without saving.
Future<List<LogEntry>?> showCopyDaySheet(
  BuildContext context, {
  required DateTime targetDate,
  List<Meal>? preselectMeals,
}) {
  final isCompact = FormFactor.of(context).isCompact;
  final body = CopyDaySheet(
    targetDate: targetDate,
    preselectMeals: preselectMeals,
  );

  if (isCompact) {
    return showModalBottomSheet<List<LogEntry>?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      useSafeArea: true,
      builder: (sheetContext) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.55,
          minChildSize: 0.55,
          maxChildSize: 0.88,
          snap: true,
          snapSizes: const <double>[0.55, 0.88],
          builder: (ctx, scrollController) {
            return _SheetShell(
              scrollController: scrollController,
              child: body,
            );
          },
        );
      },
    );
  }

  return showDialog<List<LogEntry>?>(
    context: context,
    barrierDismissible: true,
    builder: (dialogContext) {
      return Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480, maxHeight: 520),
          child: ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(24)),
            child: _SheetShell(scrollController: null, child: body),
          ),
        ),
      );
    },
  );
}

/// Form-factor-blind chrome wrapping the [CopyDaySheet] body. Compact
/// renders inside a `DraggableScrollableSheet` (with a grabber);
/// expanded renders inside a `Dialog` (no grabber).
class _SheetShell extends StatelessWidget {
  const _SheetShell({required this.child, required this.scrollController});

  final Widget child;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = context.radius;
    final showGrabber = scrollController != null;
    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(radius.r2),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        controller: scrollController,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (showGrabber)
              Padding(
                padding: EdgeInsets.symmetric(vertical: context.space.x2),
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.line2,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            child,
          ],
        ),
      ),
    );
  }
}

/// Body of the copy-day sheet — form-factor-blind per T-15. Public so
/// widget tests can pump it directly without going through
/// `showModalBottomSheet` plumbing.
class CopyDaySheet extends ConsumerStatefulWidget {
  const CopyDaySheet({
    super.key,
    required this.targetDate,
    this.preselectMeals,
  });

  /// The destination day. The sheet never mutates this; on save, the
  /// post-save router pushes `pathForDay(targetDate)`.
  final DateTime targetDate;

  /// Optional initial meal filter. `null` = pre-select "All meals"
  /// (whole-day copy from the empty-day affordance); a single-element
  /// list = pre-select that meal (per-meal overflow from
  /// `MealSection`); a multi-element list = pre-select that set.
  final List<Meal>? preselectMeals;

  @override
  ConsumerState<CopyDaySheet> createState() => _CopyDaySheetState();
}

class _CopyDaySheetState extends ConsumerState<CopyDaySheet> {
  late DateTime _sourceDate;

  /// `null` = "All meals" (whole-day copy); a non-null set = the
  /// selected meal chips. The chips render their own selected/not
  /// state by checking against this set.
  Set<Meal>? _meals;

  bool _isSubmitting = false;

  /// 60-day floor on the source-date picker / stepper. Matches the
  /// `DatePill` (UX-104) + QL-009 backdate range. Symmetry — see
  /// architect §3.4 (C).
  static const int _sourceFloorDays = 60;

  @override
  void initState() {
    super.initState();
    final t = widget.targetDate;
    _sourceDate = DateTime(t.year, t.month, t.day - 1);
    final pre = widget.preselectMeals;
    _meals = pre == null ? null : <Meal>{...pre};
  }

  /// Bound the source-date stepper / picker:
  ///   - lower: `max(today - 60 days, …)` — 60-day floor
  ///   - upper: `targetDate - 1 day` (source must be strictly before
  ///     target, even on backdated targets)
  ///   - upper-cap (today): the picker's `lastDate` is `today`; the
  ///     stepper's right chevron caps at `min(today, targetDate - 1)`.
  DateTime get _sourceFloor {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return today.subtract(const Duration(days: _sourceFloorDays));
  }

  DateTime get _sourceCeil {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final t = widget.targetDate;
    final dayBefore = DateTime(t.year, t.month, t.day - 1);
    // Source must be strictly before target AND not in the future.
    return dayBefore.isBefore(today) ? dayBefore : today;
  }

  void _stepSource(int days) {
    final next = DateTime(
      _sourceDate.year,
      _sourceDate.month,
      _sourceDate.day + days,
    );
    if (next.isBefore(_sourceFloor)) return;
    if (next.isAfter(_sourceCeil)) return;
    setState(() => _sourceDate = next);
  }

  Future<void> _pickSourceDate() async {
    final initial = _sourceDate.isBefore(_sourceFloor)
        ? _sourceFloor
        : (_sourceDate.isAfter(_sourceCeil) ? _sourceCeil : _sourceDate);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: _sourceFloor,
      lastDate: _sourceCeil,
    );
    if (picked == null) return;
    if (!mounted) return;
    setState(() {
      _sourceDate = DateTime(picked.year, picked.month, picked.day);
    });
  }

  /// Toggle a single-meal chip. Selecting any of the four deselects
  /// the implicit "All meals" state (`_meals == null`). Tapping the
  /// only selected chip a second time turns "All meals" back on
  /// (the empty set has no meaning here — fall through to "all").
  void _toggleMeal(Meal m) {
    setState(() {
      final cur = _meals;
      if (cur == null) {
        _meals = <Meal>{m};
        return;
      }
      final next = <Meal>{...cur};
      if (next.contains(m)) {
        next.remove(m);
      } else {
        next.add(m);
      }
      _meals = next.isEmpty ? null : next;
    });
  }

  /// Tap on the "All meals" chip — deselect every single-meal chip,
  /// store `_meals = null`. If "All meals" is already active a second
  /// tap is a no-op (the empty single-meal set is the same UX state).
  void _selectAllMeals() {
    setState(() => _meals = null);
  }

  /// List form of the current meal filter — passed to
  /// `LogRepository.copyDay` and the preview provider's family key.
  /// `null` ⇒ whole-day copy.
  List<Meal>? get _mealsAsList {
    final m = _meals;
    if (m == null) return null;
    // Stable order: enum declaration order. The repository's filter
    // is `contains`-based so order doesn't matter for correctness;
    // we sort for `CopyDayPreviewKey` equality stability across
    // chip toggles that re-build the same set.
    final list = Meal.values.where(m.contains).toList();
    return list;
  }

  Future<void> _save(CopyDayPreview snapshot) async {
    if (_isSubmitting) return;
    if (snapshot.count == 0) return;
    setState(() => _isSubmitting = true);

    final messenger = ScaffoldMessenger.maybeOf(context);
    final isCompact = FormFactor.of(context).isCompact;
    final requestedCount = snapshot.count;
    try {
      final created = await ref.read(logRepositoryProvider).copyDay(
            sourceDate: _sourceDate,
            targetDate: widget.targetDate,
            meals: _mealsAsList,
          );
      if (!mounted) return;
      // T-18 minimal invalidation. Source-date providers are NOT
      // invalidated (the source is read-only — see `copyDay`'s
      // `@invalidates` block).
      ref
        ..invalidate(daySummaryProvider(widget.targetDate))
        ..invalidate(logEntriesProvider(widget.targetDate))
        ..invalidate(recentFoodsProvider)
        ..invalidate(frequentFoodsProvider)
        ..invalidate(weeklyLogDaysProvider);

      // T-24 Case 2 — route-to-effect.
      //
      // Compact: the `DraggableScrollableSheet` is a route in the
      // navigator stack, so `context.go` replaces it implicitly —
      // but we still pop with the created list so callers awaiting
      // `showCopyDaySheet` get the entries.
      // Expanded: the `Dialog` is NOT a route, so we pop the dialog
      // first then `go` — T-24's dialog-pop-first rule (architect
      // §6.3).
      if (isCompact) {
        Navigator.of(context).pop<List<LogEntry>>(created);
      } else {
        Navigator.of(context, rootNavigator: true)
            .pop<List<LogEntry>>(created);
      }
      if (!context.mounted) return;
      context.go(pathForDay(widget.targetDate));

      final skipped = requestedCount - created.length;
      final text = skipped <= 0
          ? 'Copied ${created.length} '
              '${created.length == 1 ? 'entry' : 'entries'}'
          : 'Copied ${created.length} of $requestedCount — '
              '$skipped skipped (food no longer available)';
      messenger?.showSnackBar(SnackBar(content: Text(text)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      messenger?.showSnackBar(
        SnackBar(
          content: Text('Could not copy: $e'),
          action: SnackBarAction(
            label: 'Try again',
            onPressed: () => _save(snapshot),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final space = context.space;
    final previewKey = CopyDayPreviewKey(
      sourceDate: _sourceDate,
      meals: _mealsAsList,
    );
    final previewAsync = ref.watch(copyDayPreviewProvider(previewKey));
    return Padding(
      padding: EdgeInsets.fromLTRB(
        space.x4,
        space.x2,
        space.x4,
        space.x4,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _SourceDateRow(
            sourceDate: _sourceDate,
            onPickDate: _pickSourceDate,
            onPrev: () => _stepSource(-1),
            onNext: () => _stepSource(1),
            canStepPrev: _sourceDate.isAfter(_sourceFloor),
            canStepNext: _sourceDate.isBefore(_sourceCeil),
          ),
          SizedBox(height: space.x3),
          _MealScopeChips(
            selectedMeals: _meals,
            onSelectAll: _selectAllMeals,
            onToggle: _toggleMeal,
          ),
          SizedBox(height: space.x3),
          _PreviewLine(previewAsync: previewAsync),
          SizedBox(height: space.x4),
          previewAsync.maybeWhen(
            data: (preview) => PrimaryButton(
              key: const Key('copy-day-save'),
              label: _saveLabel(preview.count),
              onPressed:
                  preview.count == 0 || _isSubmitting ? null : () => _save(preview),
              isLoading: _isSubmitting,
            ),
            orElse: () => PrimaryButton(
              key: const Key('copy-day-save'),
              label: _saveLabel(0),
              onPressed: null,
            ),
          ),
        ],
      ),
    );
  }

  String _saveLabel(int count) {
    if (count == 0) return 'Save — nothing to copy';
    return 'Save — copy $count ${count == 1 ? 'entry' : 'entries'}';
  }
}

class _SourceDateRow extends StatelessWidget {
  const _SourceDateRow({
    required this.sourceDate,
    required this.onPickDate,
    required this.onPrev,
    required this.onNext,
    required this.canStepPrev,
    required this.canStepNext,
  });

  final DateTime sourceDate;
  final VoidCallback onPickDate;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final bool canStepPrev;
  final bool canStepNext;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final space = context.space;
    final dateLabel = DateFormat('EEE, MMM d').format(sourceDate);
    return Row(
      children: <Widget>[
        Text(
          'From',
          style: context.text.meta.copyWith(color: colors.ink2),
        ),
        SizedBox(width: space.x2),
        Expanded(
          child: InkWell(
            key: const Key('copy-day-source-date'),
            onTap: onPickDate,
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: space.x2),
              child: Text(
                dateLabel,
                style: context.text.body.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
        IconButton36(
          key: const Key('copy-day-prev'),
          icon: Icons.chevron_left,
          tooltip: 'Earlier day',
          onPressed: canStepPrev ? onPrev : _noop,
          color: canStepPrev ? null : colors.ink2,
        ),
        IconButton36(
          key: const Key('copy-day-next'),
          icon: Icons.chevron_right,
          tooltip: 'Later day',
          onPressed: canStepNext ? onNext : _noop,
          color: canStepNext ? null : colors.ink2,
        ),
        IconButton36(
          key: const Key('copy-day-calendar'),
          icon: Icons.calendar_today_outlined,
          tooltip: 'Pick a source date',
          onPressed: onPickDate,
        ),
      ],
    );
  }

  static void _noop() {}
}

class _MealScopeChips extends StatelessWidget {
  const _MealScopeChips({
    required this.selectedMeals,
    required this.onSelectAll,
    required this.onToggle,
  });

  /// `null` ⇒ "All meals" is active. A non-null set ⇒ those meals
  /// are selected; "All meals" is inactive.
  final Set<Meal>? selectedMeals;
  final VoidCallback onSelectAll;
  final ValueChanged<Meal> onToggle;

  @override
  Widget build(BuildContext context) {
    final space = context.space;
    final allSelected = selectedMeals == null;
    return Wrap(
      spacing: space.x2,
      runSpacing: space.x2,
      children: <Widget>[
        _ScopeChip(
          label: 'All meals',
          selected: allSelected,
          onTap: onSelectAll,
          chipKey: const Key('copy-day-chip-all'),
        ),
        for (final meal in Meal.values)
          _ScopeChip(
            label: meal.label,
            selected: selectedMeals?.contains(meal) ?? false,
            onTap: () => onToggle(meal),
            chipKey: Key('copy-day-chip-${meal.wire}'),
          ),
      ],
    );
  }
}

class _ScopeChip extends StatelessWidget {
  const _ScopeChip({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.chipKey,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Key chipKey;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = context.radius;
    final space = context.space;
    return Semantics(
      button: true,
      selected: selected,
      // A11y per architect §3.5: combine label + selected state.
      label: '$label, ${selected ? 'selected' : 'not selected'}',
      child: InkResponse(
        key: chipKey,
        onTap: onTap,
        radius: 24,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: space.x3,
            vertical: space.x2,
          ),
          decoration: BoxDecoration(
            color: selected ? colors.accent : colors.surface,
            border: Border.all(
              color: selected ? colors.accent : colors.line,
            ),
            borderRadius: BorderRadius.circular(radius.r2),
          ),
          child: Text(
            label,
            style: context.text.meta.copyWith(
              fontWeight: FontWeight.w500,
              color: selected ? colors.surface : colors.ink2,
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewLine extends StatelessWidget {
  const _PreviewLine({required this.previewAsync});

  final AsyncValue<CopyDayPreview> previewAsync;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return previewAsync.when(
      data: (preview) {
        final entryWord = preview.count == 1 ? 'entry' : 'entries';
        return Text(
          key: const Key('copy-day-preview'),
          '${preview.count} $entryWord · '
          '${formatKcal(preview.totalKcal)} kcal',
          style: context.text.body.copyWith(color: colors.ink2),
        );
      },
      // The preview is in-memory so loading is near-instant; render a
      // muted dash skeleton rather than a spinner (T-08 / T-13).
      loading: () => Text(
        key: const Key('copy-day-preview-loading'),
        '—',
        style: context.text.body.copyWith(color: colors.ink2),
      ),
      error: (_, __) => Text(
        key: const Key('copy-day-preview-error'),
        '—',
        style: context.text.body.copyWith(color: colors.ink2),
      ),
    );
  }
}
