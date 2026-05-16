import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../domain/log_entry.dart';
import '../../domain/meal.dart';
import '../../domain/nutrition.dart';
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
/// Returns the created `LogEntry` on save, or `null` when the user
/// dismisses the sheet.
///
/// **Post-save T-24 Case 2 routing.** On save we pop the sheet (or
/// dialog on expanded — pop-first ordering, mirroring `LogEntrySheet`'s
/// architect §6.3 carveout) and then `context.go(pathForDay(date))` so
/// the user lands on the day-view where their just-logged kcal appears.
///
/// **Macros override.** When the optional "Add macros" toggle is on,
/// the submit payload carries a `nutritionOverride` (a sparse
/// `NutritionPer100g` with the user-supplied P/C/F) that the mock
/// `LogRepository.create` substitutes for the synthetic food's
/// `nutritionPer100g` before computing the snapshot. With the toggle
/// off, only kcal is logged (macros default to zero on the synthetic
/// food's per-100 g panel).
Future<LogEntry?> showQuickAddSheet(
  BuildContext context, {
  DateTime? defaultDate,
  Meal? defaultMeal,
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
class QuickAddSheetBody extends ConsumerStatefulWidget {
  const QuickAddSheetBody({
    super.key,
    this.defaultDate,
    this.defaultMeal,
    this.scrollController,
    this.showGrabber = true,
    @visibleForTesting this.onSubmit,
    @visibleForTesting this.skipRouteOnSave = false,
  });

  /// Pre-seeded date. Defaults to today (local-calendar Y/M/D).
  final DateTime? defaultDate;

  /// Pre-seeded meal. Defaults to the local-time fallback.
  final Meal? defaultMeal;

  final ScrollController? scrollController;
  final bool showGrabber;

  /// **Test-only.** Fires with the constructed `LogCreate` before the
  /// repository call. Test seam mirroring `LogEntrySheetBody.onSubmit`.
  final ValueChanged<LogCreate>? onSubmit;

  /// **Test-only.** When true, skip the post-save `context.go`
  /// navigation. Lets tests assert on the `LogCreate` payload without
  /// standing up a router in the harness.
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

  @override
  void initState() {
    super.initState();
    _meal = widget.defaultMeal ?? mealForLocalTime(DateTime.now());
    final seedDate = widget.defaultDate ?? DateTime.now();
    _date = DateTime(seedDate.year, seedDate.month, seedDate.day);
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

  /// Build the `LogCreate` payload from the current form state. The
  /// quantity field maps directly to kcal because the synthetic
  /// Quick-add food's per-100 g panel is 100 kcal and the `kcal`
  /// serving is 1 g — so `quantity × 1 g × (100 kcal / 100 g) = kcal`.
  ///
  /// When the macros toggle is on the override carries 100 kcal +
  /// user-supplied P/C/F so the snapshot math at `LogRepository.create`
  /// surfaces those macros on the entry.
  LogCreate _buildLogCreate() {
    final kcal = _kcal ?? Decimal.one;
    return LogCreate(
      foodId: _quickAddFoodId,
      servingId: _quickAddServingId,
      consumedOn: _date,
      meal: _meal,
      quantity: kcal,
      note: null,
      nutritionOverride: _macrosExpanded ? _buildOverride() : null,
    );
  }

  /// Build the per-100 g override carrying the user-supplied macros.
  /// Energy stays at 100 kcal so `quantity` still maps to kcal; only
  /// the macro fields differ from the default zero panel.
  NutritionPer100g _buildOverride() {
    return NutritionPer100g(
      energyKcal: Decimal.fromInt(100),
      proteinG: _protein ?? Decimal.zero,
      carbsG: _carbs ?? Decimal.zero,
      fatG: _fat ?? Decimal.zero,
    );
  }

  Future<void> _onSavePressed() async {
    if (_submitting) return;
    if (_kcal == null || _kcal! < Decimal.one) return;
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

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final space = context.space;
    final autofocusKcal = FormFactor.of(context).isCompact;
    final canSave =
        !_submitting && _kcal != null && _kcal! >= Decimal.one;

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
          const _Header(),
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
            onSave: _onSavePressed,
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

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
                  'Quick add calories',
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
  });

  final bool submitting;
  final bool enabled;
  final VoidCallback onSave;

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
        label: 'Save',
        isLoading: submitting,
        onPressed: enabled ? onSave : null,
      ),
    );
  }
}
