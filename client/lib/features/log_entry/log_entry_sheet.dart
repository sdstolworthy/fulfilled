import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fulfilled/widgets/quantity_stepper.dart';

import '../../data/outbox/log_outbox_notifier.dart';
import '../../domain/food.dart';
import '../../domain/log_entry.dart';
import '../../domain/meal.dart';
import '../../domain/nutrition.dart';
import '../../domain/serving.dart';
import '../../form_factor/form_factor.dart';
import '../../providers/food_providers.dart';
import '../../providers/log_providers.dart';
import '../../providers/repository_providers.dart';
import '../../theme/context_extensions.dart';
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
/// On compact, the returned `LogEntry` is an **optimistic** value
/// constructed from the form state; the real entry is created when the
/// outbox flushes against the server.
Future<LogEntry?> showLogEntrySheet(
  BuildContext context, {
  required Food food,
  Meal? defaultMeal,
}) {
  final isCompact = FormFactor.of(context).isCompact;
  // Capture the parent container so the nested ProviderScope can lift
  // the real LogRepository.create into the outbox notifier — the
  // foundation's `logPostFnProvider` is a throwing stub by default.
  final parent = ProviderScope.containerOf(context, listen: false);

  Widget contents({
    required ScrollController? scrollController,
    required bool showGrabber,
  }) {
    return ProviderScope(
      parent: parent,
      overrides: <Override>[
        // Re-seed so each sheet gets a fresh quantity (otherwise the
        // last-used value would leak across sheets via the top-level
        // provider's container cache).
        quantityProvider.overrideWith((ref) => Decimal.one),
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
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480, maxHeight: 720),
          child: ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(24)),
            child: contents(scrollController: null, showGrabber: false),
          ),
        ),
      );
    },
  );
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
    this.defaultMeal,
    this.scrollController,
    this.showGrabber = true,
  });

  final Food food;
  final Meal? defaultMeal;
  final ValueChanged<LogCreate> onSubmit;
  final ScrollController? scrollController;
  final bool showGrabber;

  @override
  ConsumerState<LogEntrySheetBody> createState() => _LogEntrySheetBodyState();
}

class _LogEntrySheetBodyState extends ConsumerState<LogEntrySheetBody> {
  late Meal _meal;
  late Serving _serving;
  late DateTime _date;
  final TextEditingController _noteCtrl = TextEditingController();
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _meal = widget.defaultMeal ?? mealForLocalTime(DateTime.now());
    _serving = widget.food.servings.firstWhere(
      (s) => s.id == widget.food.defaultServingId,
      orElse: () => widget.food.servings.first,
    );
    final now = DateTime.now();
    _date = DateTime(now.year, now.month, now.day);
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  LogCreate _buildLogCreate() {
    final quantity = ref.read(quantityProvider);
    final note = _noteCtrl.text.trim();
    return LogCreate(
      foodId: widget.food.id,
      servingId: _serving.id,
      consumedOn: _date,
      meal: _meal,
      quantity: quantity,
      note: note.isEmpty ? null : note,
    );
  }

  Future<void> _onSavePressed() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    final logCreate = _buildLogCreate();
    // Fire the test seam first so callers can observe the constructed
    // payload regardless of which branch (outbox / direct) runs.
    widget.onSubmit(logCreate);

    final messenger = ScaffoldMessenger.maybeOf(context);
    final formFactor = FormFactor.of(context);

    if (formFactor.isCompact) {
      // Outbox path. Enqueue + pop with an optimistic LogEntry; the
      // outbox notifier flushes asynchronously, day-summary updates
      // when the server response lands.
      try {
        await ref
            .read(logOutboxProvider.notifier)
            .enqueue(payload: logCreate.toJson());
        messenger?.showSnackBar(
          const SnackBar(content: Text('Logged — syncing')),
        );
        if (!mounted) return;
        // Invalidate provider families so an optimistic merge (if/when
        // the app gains one) re-runs. Safe to invalidate here; the
        // outbox notifier owns the persisted state.
        ref
          ..invalidate(daySummaryProvider(_date))
          ..invalidate(logEntriesProvider(_date))
          ..invalidate(recentFoodsProvider)
          ..invalidate(frequentFoodsProvider);
        Navigator.of(context).pop<LogEntry?>(_optimisticEntry(logCreate));
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
      Navigator.of(context).pop<LogEntry?>(entry);
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not save: $e')),
      );
    }
  }

  /// Build an optimistic [LogEntry] mirroring what the server will
  /// compute. Same math as `LogRepository.create` — kept here because
  /// the outbox path returns *immediately* before any server roundtrip.
  LogEntry _optimisticEntry(LogCreate data) {
    final mult = (_serving.grams / Decimal.fromInt(100))
            .toDecimal(scaleOnInfinitePrecision: 6) *
        data.quantity;
    final n = widget.food.nutritionPer100g;

    Decimal? scaled(Decimal? per100) =>
        per100 == null ? null : per100 * mult;

    final now = DateTime.now();
    final snapshot = NutritionSnapshot(
      caloriesKcal: (n.energyKcal ?? Decimal.zero) * mult,
      proteinG: scaled(n.proteinG),
      carbsG: scaled(n.carbsG),
      fatG: scaled(n.fatG),
      fiberG: scaled(n.fiberG),
      sugarG: scaled(n.sugarG),
      sodiumMg: scaled(n.sodiumMg),
      saturatedFatG: scaled(n.saturatedFatG),
    );
    return LogEntry(
      id: 'optimistic_${now.microsecondsSinceEpoch}',
      foodId: widget.food.id,
      foodName: widget.food.name,
      servingId: _serving.id,
      servingName: _serving.name,
      consumedOn: data.consumedOn,
      meal: data.meal,
      quantity: data.quantity,
      gramsTotal: _serving.grams * data.quantity,
      nutritionSnapshot: snapshot,
      note: data.note,
      createdAt: now,
      updatedAt: now,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final space = context.space;
    final quantity = ref.watch(quantityProvider);

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
          _Header(food: widget.food),
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
                  _SectionLabel(text: 'QUANTITY'),
                  SizedBox(height: space.x2),
                  // Consumer bridge: the lifted `QuantityStepper` is
                  // callback-shaped (T-15 — same render regardless of
                  // who drives state). The sheet keeps its scoped
                  // `quantityProvider`; this wrapper forwards both ways.
                  Consumer(
                    builder: (context, ref, _) {
                      final value = ref.watch(quantityProvider);
                      return QuantityStepper(
                        key: const Key('log_entry_quantity_field_host'),
                        value: value,
                        step: Decimal.parse('0.5'),
                        min: Decimal.parse('0.5'),
                        onChanged: (next) {
                          if (next == null) return;
                          ref.read(quantityProvider.notifier).state = next;
                        },
                      );
                    },
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
            onSave: _onSavePressed,
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.food});
  final Food food;

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
    final gramsTotal = selected.grams * quantity;
    final kcal = (food.nutritionPer100g.energyKcal ?? Decimal.zero) *
        (selected.grams / Decimal.fromInt(100))
            .toDecimal(scaleOnInfinitePrecision: 6) *
        quantity;

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
                    '${_trimDecimal(gramsTotal)} g · ${_trimDecimal(kcal.round(scale: 0))} kcal',
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
  const _Footer({required this.submitting, required this.onSave});

  final bool submitting;
  final VoidCallback onSave;

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
          onPressed: submitting ? null : onSave,
          style: FilledButton.styleFrom(
            backgroundColor: colors.accent,
            foregroundColor: colors.surface,
            disabledBackgroundColor: colors.accent.withValues(alpha: 0.6),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radius.r3),
            ),
            textStyle: context.text.bodyStrong.copyWith(fontSize: 16),
          ),
          child: submitting
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colors.surface,
                  ),
                )
              : const Text('Save to log'),
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
    note: json['note'] as String?,
  );
}
