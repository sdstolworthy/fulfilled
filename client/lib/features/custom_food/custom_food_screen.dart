import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/food.dart';
import '../../domain/nutrition.dart';
import '../../providers/draft_providers.dart';
import '../../providers/food_providers.dart';
import '../../providers/profile_providers.dart';
import '../../providers/repository_providers.dart';
import '../../repositories/food_repository.dart';
import '../../theme/context_extensions.dart';
import 'widgets/basics_section.dart';
import 'widgets/nutrition_section.dart';
import 'widgets/servings_section.dart';

/// Screen 05 — Create custom food.
///
/// Lives outside the ShellRoute (full-page context). Composes:
/// top bar (Cancel + title + Save) → step indicator
/// (Details / Nutrition / Servings) → scroll body → sticky footer
/// `PrimaryButton`.
///
/// Form state lives on `customFoodDraftProvider`. Drafts do not reset on
/// cancel — only on a successful save or an explicit "Discard". The
/// architecture's reasoning: a user who taps Cancel and comes back
/// expects their typing to still be there.
///
/// Save flow:
/// 1. Validate client-side (kcal/P/C/F + name). If invalid, switch the
///    footer to "Fix N errors to save" and surface inline `Required`
///    rows under each missing field.
/// 2. Build `FoodCreate` (the `NutritionPer100g.toJson` converts sodium
///    mg → g at the wire boundary so the screen never multiplies).
/// 3. Await `foodRepository.createCustom(...)`.
/// 4. On success: `notifier.reset()`, invalidate `meProvider` +
///    `customFoodCountProvider`, `context.pop(food)`.
/// 5. On failure: SnackBar; draft is preserved.
///
/// Tenants honored: T-07 (every numeric is a `QuantityStepper`), T-08
/// (save shows a button-level spinner, never a blocking modal), T-11
/// (inline errors; AlertDialog only for the destructive
/// "Discard unsaved changes" path), T-17 / T-21 (`Decimal` everywhere;
/// sodium captured in mg).
class CustomFoodScreen extends ConsumerStatefulWidget {
  const CustomFoodScreen({this.initialBarcode, super.key});

  /// Optional barcode to prefill the draft's `barcode` field with on
  /// first build. Wired by the router from the `?barcode=` query
  /// parameter on `/foods/new` (T-021): when the barcode resolver
  /// hits a 404, it `pushReplacement`s to `/foods/new?barcode=…` so
  /// the user lands here with the value already typed for them.
  final String? initialBarcode;

  @override
  ConsumerState<CustomFoodScreen> createState() => _CustomFoodScreenState();
}

class _CustomFoodScreenState extends ConsumerState<CustomFoodScreen> {
  /// True once the user has attempted Save with invalid fields. Drives
  /// the inline error rows in the section widgets and the footer copy.
  bool _showErrors = false;

  /// True while a `createCustom` is in flight. Disables the footer
  /// button and shows a skeleton state on it (T-08).
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final seed = widget.initialBarcode?.trim();
    if (seed != null && seed.isNotEmpty) {
      // Seed the draft after the first frame so the notifier mutation
      // happens outside of `initState`'s build-time constraints. We
      // only seed if the current draft barcode is empty — if the user
      // had a previous draft with their own barcode typed, we don't
      // overwrite it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final draft = ref.read(customFoodDraftProvider);
        if (draft.barcode == null || draft.barcode!.isEmpty) {
          ref.read(customFoodDraftProvider.notifier).setBarcode(seed);
        }
      });
    }
  }

  Future<void> _onSave() async {
    final draft = ref.read(customFoodDraftProvider);
    if (!draft.isValid) {
      setState(() => _showErrors = true);
      return;
    }

    setState(() => _saving = true);
    final repo = ref.read(foodRepositoryProvider);
    try {
      final payload = FoodCreate(
        name: draft.name.trim(),
        brand: (draft.brand?.trim().isEmpty ?? true) ? null : draft.brand!.trim(),
        barcode:
            (draft.barcode?.trim().isEmpty ?? true) ? null : draft.barcode!.trim(),
        nutrition: NutritionPer100g(
          energyKcal: draft.energyKcal,
          proteinG: draft.proteinG,
          carbsG: draft.carbsG,
          fatG: draft.fatG,
          fiberG: draft.fiberG,
          sugarG: draft.sugarG,
          // Sodium is mg on the draft (T-21). `NutritionPer100g.toJson`
          // converts mg → g at the wire boundary; we pass through here.
          sodiumMg: draft.sodiumMg,
          saturatedFatG: draft.saturatedFatG,
        ),
      );

      final food = await repo.createCustom(payload);

      // Snapshot draft servings before reset (the notifier wipes them).
      final pendingServings = draft.userServings;

      // Side-effects per arch §9: reset draft, invalidate "me" (which
      // carries the count via `customFoodCount`) and the explicit
      // count provider.
      ref.read(customFoodDraftProvider.notifier).reset();
      ref.invalidate(meProvider);
      ref.invalidate(customFoodCountProvider);

      // POST per arch §9 / T-007: iterate user-defined servings. Each
      // failure is logged + surfaced via a SnackBar but does not abort
      // the loop — the food itself is saved, so the user can retry
      // missing rows from the detail page (a follow-up ticket).
      var anyServingFailed = false;
      for (final draftServing in pendingServings) {
        try {
          await repo.addServing(
            food.id,
            ServingCreate(
              label: draftServing.label,
              grams: draftServing.grams,
            ),
          );
        } on Object catch (err, stack) {
          anyServingFailed = true;
          debugPrint(
            "addServing failed for '${draftServing.label}' on "
            "${food.id}: $err\n$stack",
          );
        }
      }

      // Invalidate only the just-edited food's detail (T-18: no
      // shotgun `everythingProvider`). The food list / search / recent
      // / frequent providers don't change shape just because we added
      // servings to one food.
      ref.invalidate(foodDetailProvider(food.id));

      if (!mounted) return;
      if (anyServingFailed) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text("Saved the food but couldn't add all servings"),
          ),
        );
      }
      context.pop(food);
    } on Object catch (err) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't save food: $err")),
      );
    }
  }

  Future<void> _onCancel() async {
    final draft = ref.read(customFoodDraftProvider);
    final isDirty = draft.name.isNotEmpty ||
        draft.brand != null ||
        draft.barcode != null ||
        draft.energyKcal != null ||
        draft.proteinG != null ||
        draft.carbsG != null ||
        draft.fatG != null ||
        draft.fiberG != null ||
        draft.sugarG != null ||
        draft.sodiumMg != null ||
        draft.userServings.isNotEmpty;

    if (!isDirty) {
      context.pop();
      return;
    }

    // T-11: destructive confirmation is the only legal use of an
    // AlertDialog. The Discard branch clears the draft; Keep editing
    // leaves it alone (so a re-open continues the form).
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard this food?'),
        content: const Text(
          'You have unsaved changes. Discard them or keep editing?',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: context.colors.danger),
            child: const Text('Discard'),
          ),
        ],
      ),
    );

    if (discard == true) {
      ref.read(customFoodDraftProvider.notifier).reset();
      if (mounted) context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final draft = ref.watch(customFoodDraftProvider);
    final errors = draft.errors;
    final colors = context.colors;
    final space = context.space;

    return Scaffold(
      backgroundColor: colors.bg,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            _TopBar(
              onCancel: _saving ? null : _onCancel,
              onSave: _saving || !draft.isValid ? null : _onSave,
            ),
            const _StepIndicator(activeStep: _Step.details),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  space.x5,
                  space.x2,
                  space.x5,
                  space.x6 + space.x1,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    BasicsSection(showNameError: _showErrors),
                    SizedBox(height: space.x5 - 2),
                    NutritionSection(showErrors: _showErrors),
                    SizedBox(height: space.x5 - 2),
                    const ServingsSection(),
                  ],
                ),
              ),
            ),
            _FooterButton(
              errorCount: errors.length,
              saving: _saving,
              onTap: _saving ? null : _onSave,
            ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.onCancel, required this.onSave});

  final VoidCallback? onCancel;
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final space = context.space;
    return Container(
      padding: EdgeInsets.fromLTRB(space.x4, space.x1 + 2, space.x4, space.x3),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.line, width: 1)),
      ),
      child: Row(
        children: <Widget>[
          _TextAction(
            label: 'Cancel',
            onTap: onCancel,
            color: colors.ink2,
          ),
          const Spacer(),
          Text('New food', style: context.text.title),
          const Spacer(),
          _TextAction(
            label: 'Save',
            onTap: onSave,
            color: colors.accent,
            bold: true,
          ),
        ],
      ),
    );
  }
}

class _TextAction extends StatelessWidget {
  const _TextAction({
    required this.label,
    required this.onTap,
    required this.color,
    this.bold = false,
  });

  final String label;
  final VoidCallback? onTap;
  final Color color;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return Semantics(
      button: true,
      enabled: !disabled,
      label: label,
      child: InkResponse(
        onTap: onTap,
        radius: 22,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Text(
            label,
            style: context.text.bodyStrong.copyWith(
              color: disabled ? context.colors.ink3 : color,
              fontWeight: bold ? FontWeight.w600 : FontWeight.w500,
              fontSize: 15,
            ),
          ),
        ),
      ),
    );
  }
}

enum _Step { details, nutrition, servings }

class _StepIndicator extends StatelessWidget {
  const _StepIndicator({required this.activeStep});
  final _Step activeStep;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final space = context.space;

    // The mock paints a 50%-filled first bar between Details and
    // Nutrition. We keep the screen at "Details" (single-page form) and
    // mirror that visual. When step navigation is wired up, drive these
    // fractions from the active step.
    Widget pill(String label, bool active) => Text(
          label.toUpperCase(),
          style: context.text.eyebrow.copyWith(
            color: active ? colors.accent : colors.ink2,
          ),
        );

    Widget bar(double progress) => Expanded(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: space.x2),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: SizedBox(
                height: 4,
                child: Stack(
                  children: <Widget>[
                    Positioned.fill(
                      child: ColoredBox(color: colors.line2),
                    ),
                    FractionallySizedBox(
                      widthFactor: progress.clamp(0.0, 1.0),
                      child: ColoredBox(color: colors.accent),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        space.x5,
        space.x2 + 2,
        space.x5,
        space.x1,
      ),
      child: Row(
        children: <Widget>[
          pill('Details', activeStep == _Step.details),
          bar(activeStep == _Step.details ? 0.5 : 1.0),
          pill('Nutrition', activeStep == _Step.nutrition),
          bar(activeStep == _Step.servings ? 1.0 : 0.0),
          pill('Servings', activeStep == _Step.servings),
        ],
      ),
    );
  }
}

class _FooterButton extends StatelessWidget {
  const _FooterButton({
    required this.errorCount,
    required this.saving,
    required this.onTap,
  });

  final int errorCount;
  final bool saving;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = context.radius;
    final space = context.space;

    // The button has three visual states (per mock) but stays tappable
    // when invalid so the user can surface inline errors via T-11. We
    // only hard-disable the gesture while saving.
    final invalid = errorCount > 0;
    final greyed = invalid || saving;
    final label = saving
        ? 'Saving…'
        : (errorCount == 0
            ? 'Save'
            : 'Fix $errorCount ${errorCount == 1 ? 'error' : 'errors'} to save');

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.line, width: 1)),
      ),
      padding: EdgeInsets.fromLTRB(space.x5, space.x3 + 2, space.x5, space.x6),
      child: SizedBox(
        height: 52,
        child: Semantics(
          button: true,
          enabled: !saving,
          label: label,
          child: Material(
            color: greyed ? const Color(0xFFC4D2D0) : colors.accent,
            borderRadius: BorderRadius.circular(radius.r3),
            child: InkWell(
              onTap: saving ? null : onTap,
              borderRadius: BorderRadius.circular(radius.r3),
              child: Center(
                child: saving
                    ? const _ButtonSkeleton()
                    : Text(
                        label,
                        style: context.text.bodyStrong.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Button-level loading affordance for T-08. A static "skeleton" bar
/// (no animation loop so widget tests' `pumpAndSettle` finishes) over
/// the button face. The architectural intent is "no blocking modal
/// spinner"; the static treatment is enough to convey work-in-flight
/// without the test-suite friction of an infinite ticker.
class _ButtonSkeleton extends StatelessWidget {
  const _ButtonSkeleton();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 96,
      height: 12,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: ColoredBox(color: Colors.white.withValues(alpha: 0.35)),
      ),
    );
  }
}

