import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/drafts.dart';
import '../../domain/enums.dart';
import '../../domain/food.dart';
import '../../domain/food_patch.dart';
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
  const CustomFoodScreen({this.initialBarcode, this.existing, super.key});

  /// Optional barcode to prefill the draft's `barcode` field with on
  /// first build. Wired by the router from the `?barcode=` query
  /// parameter on `/foods/new` (T-021): when the barcode resolver
  /// hits a 404, it `pushReplacement`s to `/foods/new?barcode=…` so
  /// the user lands here with the value already typed for them.
  final String? initialBarcode;

  /// Non-null flips the screen into **edit mode**: the draft is seeded
  /// from this food on first build, the title reads "Edit food", the
  /// footer reads "Save changes", and submit routes through
  /// `FoodRepository.updateCustom` (sparse patch) instead of
  /// `createCustom`. Mirrors `LogEntrySheet`'s `existing:` plumbing
  /// (LU-002). Only `source == user` foods are editable — the router
  /// already gates here, but the screen also asserts in debug mode.
  final Food? existing;

  @override
  ConsumerState<CustomFoodScreen> createState() => _CustomFoodScreenState();
}

class _CustomFoodScreenState extends ConsumerState<CustomFoodScreen> {
  /// True once the user has attempted Save with invalid fields. Drives
  /// the inline error rows in the section widgets and the footer copy.
  bool _showErrors = false;

  /// True while a `createCustom` / `updateCustom` is in flight. Disables
  /// the footer button and shows a skeleton state on it (T-08).
  bool _saving = false;

  /// True iff `widget.existing != null` — the screen flips between
  /// create and edit mode based on this. Stored as a getter so the rest
  /// of the screen reads top-down.
  bool get _isEditing => widget.existing != null;

  /// Snapshot of the draft taken after the seed-from-existing step
  /// completes. The "Save changes" button stays disabled while the
  /// current draft equals this snapshot — mirrors LU-002's
  /// `_isUnchanged()` predicate.
  CustomFoodDraft? _seedSnapshot;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    if (existing != null) {
      // Edit mode: seed the draft from the food on first build. Like
      // the barcode prefill below, run after the first frame so the
      // notifier mutation happens outside `initState`'s build-time
      // constraints. Edit mode takes precedence over create-mode
      // prefills — a barcode query param on an edit URL would be
      // surprising and is out of scope here.
      assert(
        existing.source == FoodSource.user,
        'CustomFoodScreen.existing must be a user-source food; got '
        '${existing.source.wire}',
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(customFoodDraftProvider.notifier).seedFromFood(existing);
        // Snapshot taken after the seed so `_isUnchanged()` compares
        // against the "just-seeded" baseline, not the prior draft.
        setState(() {
          _seedSnapshot = ref.read(customFoodDraftProvider);
        });
      });
      return;
    }
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

  /// True iff the current draft equals the post-seed snapshot. Used in
  /// edit mode to disable the Save button until the user actually
  /// changes something. Returns `false` when the snapshot hasn't been
  /// taken yet (the first-frame seed-and-snapshot is still in flight)
  /// so the button isn't accidentally enabled mid-seed.
  bool _isUnchanged() {
    if (!_isEditing) return false;
    final snapshot = _seedSnapshot;
    if (snapshot == null) return true;
    return ref.read(customFoodDraftProvider) == snapshot;
  }

  /// Build the sparse [FoodPatch] from the current draft state vs.
  /// [widget.existing]. Mirrors LU-002's `_buildLogPatch()` — fields
  /// that match the original are omitted; fields that were
  /// previously-non-null and are now empty set the corresponding
  /// `clear*` flag. Servings are always sent as a full-list replace
  /// when the list changed at all (per FoodPatch class docs).
  FoodPatch _buildFoodPatch() {
    assert(_isEditing, '_buildFoodPatch called outside edit mode');
    final original = widget.existing!;
    final draft = ref.read(customFoodDraftProvider);

    final trimmedName = draft.name.trim();
    final String? name = trimmedName != original.name ? trimmedName : null;

    final trimmedBrand =
        (draft.brand?.trim().isEmpty ?? true) ? null : draft.brand!.trim();
    final String? brand;
    final bool clearBrand;
    if (trimmedBrand != original.brand) {
      if (trimmedBrand == null) {
        brand = null;
        clearBrand = original.brand != null;
      } else {
        brand = trimmedBrand;
        clearBrand = false;
      }
    } else {
      brand = null;
      clearBrand = false;
    }

    final trimmedBarcode =
        (draft.barcode?.trim().isEmpty ?? true) ? null : draft.barcode!.trim();
    final String? barcode;
    final bool clearBarcode;
    if (trimmedBarcode != original.barcode) {
      if (trimmedBarcode == null) {
        barcode = null;
        clearBarcode = original.barcode != null;
      } else {
        barcode = trimmedBarcode;
        clearBarcode = false;
      }
    } else {
      barcode = null;
      clearBarcode = false;
    }

    final draftNutrition = draft.toNutrition();
    final NutritionPer100g? nutrition =
        draftNutrition == original.nutritionPer100g ? null : draftNutrition;

    final originalUserServings = <DraftServing>[
      for (final s in original.servings)
        if (s.source != ServingSource.system)
          DraftServing(label: s.name, grams: s.grams),
    ];
    final List<DraftServing>? servings =
        _draftServingsEqual(draft.userServings, originalUserServings)
            ? null
            : draft.userServings;

    return FoodPatch(
      name: name,
      brand: brand,
      barcode: barcode,
      nutritionPer100g: nutrition,
      servings: servings,
      clearBrand: clearBrand,
      clearBarcode: clearBarcode,
    );
  }

  Future<void> _onSave() async {
    if (_isEditing) {
      return _onEditSave();
    }
    return _onCreateSave();
  }

  Future<void> _onCreateSave() async {
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

  /// Edit-mode submit. Builds a sparse [FoodPatch] from the current
  /// draft vs. [widget.existing] and calls
  /// `FoodRepository.updateCustom`. On success, invalidates the four
  /// providers the architect specified (food detail, my foods list,
  /// custom-food count, me) and pops with the updated food. On
  /// failure, surfaces a SnackBar and leaves the draft intact so the
  /// user can retry.
  Future<void> _onEditSave() async {
    final draft = ref.read(customFoodDraftProvider);
    if (!draft.isValid) {
      setState(() => _showErrors = true);
      return;
    }
    final patch = _buildFoodPatch();
    if (patch.isEmpty) {
      // Nothing actually changed — short-circuit. The footer button is
      // disabled in this state, but a stale state.read race could in
      // theory land us here. Treat as a successful no-op and pop.
      context.pop(widget.existing);
      return;
    }

    setState(() => _saving = true);
    final repo = ref.read(foodRepositoryProvider);
    try {
      final updated = await repo.updateCustom(widget.existing!.id, patch);

      // Side-effects per arch §9 / the edit ticket: invalidate the
      // detail provider (the just-edited food), the my-foods list (the
      // name change may have reordered rows), the count (defensive —
      // edit shouldn't change the count, but cheaper than tracking
      // which mutations affect it), and `meProvider` (which carries
      // the count via `customFoodCount`).
      ref.invalidate(foodDetailProvider(updated.id));
      ref.invalidate(myFoodsProvider);
      ref.invalidate(customFoodCountProvider);
      ref.invalidate(meProvider);

      // The draft was used for editing — reset so a subsequent
      // "Create" doesn't pre-fill with the edited food's values.
      ref.read(customFoodDraftProvider.notifier).reset();

      if (!mounted) return;
      context.pop(updated);
    } on Object catch (err) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't save changes: $err")),
      );
    }
  }

  Future<void> _onCancel() async {
    final draft = ref.read(customFoodDraftProvider);
    final bool isDirty;
    if (_isEditing) {
      // Edit mode dirty check: compare the current draft to the
      // post-seed snapshot. If the snapshot hasn't been taken yet (the
      // first-frame seed is still in flight), treat as not-dirty —
      // there's nothing the user could have changed in one frame.
      final snapshot = _seedSnapshot;
      isDirty = snapshot != null && draft != snapshot;
    } else {
      isDirty = draft.name.isNotEmpty ||
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
    }

    if (!isDirty) {
      // Edit mode: on cancel, drop any seeded values so the draft
      // doesn't leak the just-edited food into a future "Create" tap.
      if (_isEditing) {
        ref.read(customFoodDraftProvider.notifier).reset();
      }
      context.pop();
      return;
    }

    // T-11: destructive confirmation is the only legal use of an
    // AlertDialog. The Discard branch clears the draft; Keep editing
    // leaves it alone (so a re-open continues the form).
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_isEditing ? 'Discard changes?' : 'Discard this food?'),
        content: Text(
          _isEditing
              ? 'You have unsaved changes. Discard them or keep editing?'
              : 'You have unsaved changes. Discard them or keep editing?',
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

    // In edit mode the Save button stays disabled until the draft
    // differs from the post-seed snapshot — mirrors LU-002's
    // disabled-until-changed footer. `_isUnchanged()` returns true
    // until the first edit; combined with the invalid-form gate above,
    // a button that's both unchanged-and-invalid still reads as
    // disabled.
    final unchanged = _isUnchanged();
    final canSave = !_saving && draft.isValid && !unchanged;

    return Scaffold(
      backgroundColor: colors.bg,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            _TopBar(
              title: _isEditing ? 'Edit food' : 'New food',
              onCancel: _saving ? null : _onCancel,
              onSave: canSave ? _onSave : null,
              saveLabel: _isEditing ? 'Save changes' : 'Save',
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
              // Footer stays tappable when invalid so the user can
              // surface inline errors via T-11. In edit mode we add an
              // extra gate: when the draft is valid AND unchanged the
              // footer button itself is disabled (nothing to save).
              onTap: _saving || (_isEditing && draft.isValid && unchanged)
                  ? null
                  : _onSave,
              label: _isEditing ? 'Save changes' : 'Save',
              isEditing: _isEditing,
              unchanged: unchanged,
            ),
          ],
        ),
      ),
    );
  }
}

/// Structural equality for two `List<DraftServing>`s. Walked in order —
/// reordering a row counts as a change, which matches what the user sees
/// in the editor. Lives top-level so widget tests can use it.
bool _draftServingsEqual(List<DraftServing> a, List<DraftServing> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.onCancel,
    required this.onSave,
    this.title = 'New food',
    this.saveLabel = 'Save',
  });

  final VoidCallback? onCancel;
  final VoidCallback? onSave;
  final String title;
  final String saveLabel;

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
          Text(title, style: context.text.title),
          const Spacer(),
          _TextAction(
            label: saveLabel,
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
    this.label = 'Save',
    this.isEditing = false,
    this.unchanged = false,
  });

  final int errorCount;
  final bool saving;
  final VoidCallback? onTap;

  /// Default save-button copy. Edit mode overrides to "Save changes".
  final String label;

  /// Edit mode adds an extra disabled state: when the draft equals the
  /// post-seed snapshot ([unchanged] = true) the button is greyed out.
  /// Create mode never sets these flags.
  final bool isEditing;
  final bool unchanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = context.radius;
    final space = context.space;

    // The button has three visual states (per mock) but stays tappable
    // when invalid so the user can surface inline errors via T-11. We
    // only hard-disable the gesture while saving (and, in edit mode,
    // when the draft is unchanged — there's nothing to save).
    final invalid = errorCount > 0;
    final editUnchanged = isEditing && unchanged && !invalid;
    final greyed = invalid || saving || editUnchanged;
    final String renderedLabel;
    if (saving) {
      renderedLabel = 'Saving…';
    } else if (errorCount > 0) {
      renderedLabel = 'Fix $errorCount ${errorCount == 1 ? 'error' : 'errors'} to save';
    } else {
      renderedLabel = label;
    }

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
          label: renderedLabel,
          child: Material(
            color: greyed ? colors.accentDisabled : colors.accent,
            borderRadius: BorderRadius.circular(radius.r3),
            child: InkWell(
              onTap: saving ? null : onTap,
              borderRadius: BorderRadius.circular(radius.r3),
              child: Center(
                child: saving
                    ? const _ButtonSkeleton()
                    : Text(
                        renderedLabel,
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

