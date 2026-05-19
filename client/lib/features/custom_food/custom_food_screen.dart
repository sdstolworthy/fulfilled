import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/drafts.dart';
import '../../domain/enums.dart';
import '../../domain/food.dart';
import '../../domain/food_patch.dart';
import '../../providers/draft_providers.dart';
import '../../providers/food_providers.dart';
import '../../providers/repository_providers.dart';
import '../../theme/context_extensions.dart';
import 'widgets/basics_section.dart';
import 'widgets/servings_section.dart';

/// Screen 05 — Create custom food. Per Ask 10 nutrition lives **per
/// serving**, so the form is now:
///   1. Identity (name / brand / barcode) — [BasicsSection].
///   2. Servings — [ServingsSection]. Each row carries label?,
///      amount, unit, kcal, optional macros, isDefault.
///
/// There is no longer a top-level NutritionSection — the standalone
/// "nutrition per 100 g" panel was removed when the per-100g anchor
/// went away.
class CustomFoodScreen extends ConsumerStatefulWidget {
  const CustomFoodScreen({this.initialBarcode, this.existing, super.key});

  final String? initialBarcode;
  final Food? existing;

  @override
  ConsumerState<CustomFoodScreen> createState() => _CustomFoodScreenState();
}

class _CustomFoodScreenState extends ConsumerState<CustomFoodScreen> {
  bool _showErrors = false;
  bool _saving = false;

  bool get _isEditing => widget.existing != null;

  CustomFoodDraft? _seedSnapshot;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    if (existing != null) {
      assert(
        existing.source == FoodSource.user,
        'CustomFoodScreen.existing must be a user-source food; got '
        '${existing.source.wire}',
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(customFoodDraftProvider.notifier).seedFromFood(existing);
        setState(() {
          _seedSnapshot = ref.read(customFoodDraftProvider);
        });
      });
      return;
    }
    final seed = widget.initialBarcode?.trim();
    if (seed != null && seed.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final draft = ref.read(customFoodDraftProvider);
        if (draft.barcode == null || draft.barcode!.isEmpty) {
          ref.read(customFoodDraftProvider.notifier).setBarcode(seed);
        }
      });
    }
  }

  bool _isUnchanged() {
    if (!_isEditing) return false;
    final snapshot = _seedSnapshot;
    if (snapshot == null) return true;
    return ref.read(customFoodDraftProvider) == snapshot;
  }

  /// Atomic single-default flip for the servings list: clear
  /// `isDefault` on every row, set it on the picked one. Keeps the
  /// invariant the wire enforces. Lives here (not on the
  /// [ServingsSection] leaf) per the §4.4 passive-view rule — the
  /// leaf only emits the index, the container owns the rewrite.
  void _markServingDefaultAt(int i) {
    final servings = ref.read(customFoodDraftProvider).servings;
    final next = <DraftServing>[
      for (var k = 0; k < servings.length; k++)
        servings[k].copyWith(isDefault: k == i),
    ];
    ref.read(customFoodDraftProvider.notifier).setServings(next);
  }

  /// Map a DraftServing onto the wire-shaped ServingCreate. Asserts
  /// that required fields are present — the caller gates on
  /// `draft.isValid` first.
  ServingCreate _toServingCreate(DraftServing s) {
    return ServingCreate(
      label: s.label,
      amount: s.amount!,
      unit: s.unit,
      kcal: s.kcal!,
      proteinG: s.proteinG,
      carbsG: s.carbsG,
      fatG: s.fatG,
      fiberG: s.fiberG,
      sugarG: s.sugarG,
      sodiumMg: s.sodiumMg,
      saturatedFatG: s.saturatedFatG,
      isDefault: s.isDefault,
    );
  }

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

    final originalDraftServings = <DraftServing>[
      for (final s in original.servings)
        DraftServing(
          label: s.label,
          amount: s.amount,
          unit: s.unit,
          kcal: s.kcal,
          proteinG: s.proteinG,
          carbsG: s.carbsG,
          fatG: s.fatG,
          fiberG: s.fiberG,
          sugarG: s.sugarG,
          sodiumMg: s.sodiumMg,
          saturatedFatG: s.saturatedFatG,
          isDefault: s.isDefault,
        ),
    ];
    final List<DraftServing>? servings =
        _draftServingsEqual(draft.servings, originalDraftServings)
            ? null
            : draft.servings;

    return FoodPatch(
      name: name,
      brand: brand,
      barcode: barcode,
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
        brand: (draft.brand?.trim().isEmpty ?? true)
            ? null
            : draft.brand!.trim(),
        barcode: (draft.barcode?.trim().isEmpty ?? true)
            ? null
            : draft.barcode!.trim(),
        servings: <ServingCreate>[
          for (final s in draft.servings) _toServingCreate(s),
        ],
      );

      final food = await repo.createCustom(payload);

      ref.read(customFoodDraftProvider.notifier).reset();
      // `customFoodCountProvider` is the source for the profile's
      // "My foods · N" row — invalidate it directly. No
      // cross-tier `meProvider` invalidate is required now that
      // `User` no longer carries `customFoodCount`.
      ref.invalidate(customFoodCountProvider);
      ref.invalidate(foodDetailProvider(food.id));

      if (!mounted) return;
      context.pop(food);
    } on Object catch (err) {
      if (!mounted) return;
      setState(() => _saving = false);
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text("Couldn't save food: $err"),
          action: SnackBarAction(
            label: 'Retry',
            onPressed: () {
              if (!mounted) return;
              _onCreateSave();
            },
          ),
        ),
      );
    }
  }

  Future<void> _onEditSave() async {
    final draft = ref.read(customFoodDraftProvider);
    if (!draft.isValid) {
      setState(() => _showErrors = true);
      return;
    }
    final patch = _buildFoodPatch();
    if (patch.isEmpty) {
      context.pop(widget.existing);
      return;
    }

    setState(() => _saving = true);
    final repo = ref.read(foodRepositoryProvider);
    try {
      final updated = await repo.updateCustom(widget.existing!.id, patch);

      ref.invalidate(foodDetailProvider(updated.id));
      ref.invalidate(myFoodsProvider);
      ref.invalidate(customFoodCountProvider);

      ref.read(customFoodDraftProvider.notifier).reset();

      if (!mounted) return;
      context.pop(updated);
    } on Object catch (err) {
      if (!mounted) return;
      setState(() => _saving = false);
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text("Couldn't save changes: $err"),
          action: SnackBarAction(
            label: 'Retry',
            onPressed: () {
              if (!mounted) return;
              _onEditSave();
            },
          ),
        ),
      );
    }
  }

  Future<void> _onCancel() async {
    final draft = ref.read(customFoodDraftProvider);
    final bool isDirty;
    if (_isEditing) {
      final snapshot = _seedSnapshot;
      isDirty = snapshot != null && draft != snapshot;
    } else {
      isDirty = draft.name.isNotEmpty ||
          draft.brand != null ||
          draft.barcode != null ||
          draft.servings.isNotEmpty;
    }

    if (!isDirty) {
      if (_isEditing) {
        ref.read(customFoodDraftProvider.notifier).reset();
      }
      context.pop();
      return;
    }

    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_isEditing ? 'Discard changes?' : 'Discard this food?'),
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
                    BasicsSection(
                      name: draft.name,
                      brand: draft.brand,
                      barcode: draft.barcode,
                      showNameError: _showErrors,
                      autofocusName: !_isEditing,
                      onNameChanged: ref
                          .read(customFoodDraftProvider.notifier)
                          .setName,
                      onBrandChanged: ref
                          .read(customFoodDraftProvider.notifier)
                          .setBrand,
                      onBarcodeChanged: ref
                          .read(customFoodDraftProvider.notifier)
                          .setBarcode,
                    ),
                    SizedBox(height: space.x5 - 2),
                    ServingsSection(
                      servings: draft.servings,
                      showErrors: _showErrors,
                      onAddServing: () => ref
                          .read(customFoodDraftProvider.notifier)
                          .addServing(),
                      onUpdateServingAt: (i, next) => ref
                          .read(customFoodDraftProvider.notifier)
                          .updateServingAt(i, next),
                      onRemoveServingAt: (i) => ref
                          .read(customFoodDraftProvider.notifier)
                          .removeServingAt(i),
                      onMarkDefaultAt: _markServingDefaultAt,
                    ),
                  ],
                ),
              ),
            ),
            _FooterButton(
              errorCount: errors.length,
              saving: _saving,
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

enum _Step { details, servings }

class _StepIndicator extends StatelessWidget {
  const _StepIndicator({required this.activeStep});
  final _Step activeStep;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final space = context.space;

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
  final String label;
  final bool isEditing;
  final bool unchanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = context.radius;
    final space = context.space;

    final invalid = errorCount > 0;
    final editUnchanged = isEditing && unchanged && !invalid;
    final greyed = invalid || saving || editUnchanged;
    final String renderedLabel;
    if (saving) {
      renderedLabel = 'Saving…';
    } else if (errorCount > 0) {
      renderedLabel =
          'Fix $errorCount ${errorCount == 1 ? 'error' : 'errors'} to save';
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
                          color: colors.surface,
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

class _ButtonSkeleton extends StatelessWidget {
  const _ButtonSkeleton();

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

