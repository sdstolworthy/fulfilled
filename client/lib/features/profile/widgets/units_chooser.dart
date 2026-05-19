import 'package:flutter/material.dart';

import '../../../domain/enums.dart';
import '../../../form_factor/form_factor.dart';
import '../../../theme/context_extensions.dart';
import '../../../widgets/activity_option.dart';
import '../../../widgets/primary_button.dart';
import 'height_unit_chooser.dart';
import 'weight_unit_chooser.dart';

/// Profile → Preferences → Units. Joined chooser for all display-unit
/// axes (QL-104).
///
/// **Compact**: a [showModalBottomSheet] with two stacked sections —
/// Weight (three [ActivityOption]s — kg, lb, st) above Height (two
/// [ActivityOption]s — cm, ft·in). The user can tap any row in either
/// section without dismissing the sheet — selection PATCHes the
/// corresponding `weight_unit` / `height_unit` field individually and
/// updates the local section's selected state in place. The sheet only
/// dismisses on swipe-down, tap-outside, or an explicit "Done" footer
/// button. PM acceptance §2.1: "editing one preference doesn't dismiss
/// the other" — implemented by the sheet staying open across
/// in-section selections (architect §5.8 + §10.2).
///
/// **Medium / expanded**: an anchored popup, max-width 360 px, two
/// sections stacked vertically (architect §5.8 — explicit: stacked,
/// not side-by-side). Same multi-select-in-place behaviour.
///
/// **Pure presentation leaf** (see `specs/testing_guide.md` §4.4). The
/// row handlers await container-supplied [onWeightSave] /
/// [onHeightSave] callbacks; the container reads
/// `profileRepositoryProvider` and `meProvider` and performs the
/// PATCH + invalidate cycle there.
///
/// **T-24 Case 1** — the row handlers PATCH then update local
/// `selected*` state. `/me` is the source; the sheet is the editor; it
/// pops on the "Done" footer (or swipe-down). The underlying Units row
/// re-renders with the freshly persisted units the moment
/// `meProvider` invalidates.
///
/// **Failure path**: only the just-tapped row rolls back, and a
/// SnackBar surfaces the error through the parent's
/// `ScaffoldMessenger`. The other section is unaffected — which is
/// what PM's "editing one preference doesn't dismiss the other" rule
/// encodes.
Future<void> showUnitsChooser(
  BuildContext context, {
  required WeightUnit initialWeight,
  required HeightUnit initialHeight,
  required Future<void> Function(WeightUnit value) onWeightSave,
  required Future<void> Function(HeightUnit value) onHeightSave,
}) {
  final formFactor = FormFactor.of(context);
  if (formFactor.isCompact) {
    return _showCompactSheet(
      context,
      initialWeight: initialWeight,
      initialHeight: initialHeight,
      onWeightSave: onWeightSave,
      onHeightSave: onHeightSave,
    );
  }
  return _showExpandedPopup(
    context,
    initialWeight: initialWeight,
    initialHeight: initialHeight,
    onWeightSave: onWeightSave,
    onHeightSave: onHeightSave,
  );
}

// ---------------------------------------------------------------------------
// Compact — modal bottom sheet with two stacked sections.
// ---------------------------------------------------------------------------

Future<void> _showCompactSheet(
  BuildContext context, {
  required WeightUnit initialWeight,
  required HeightUnit initialHeight,
  required Future<void> Function(WeightUnit value) onWeightSave,
  required Future<void> Function(HeightUnit value) onHeightSave,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.colors.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(context.radius.r4),
      ),
    ),
    builder: (sheetContext) => SafeArea(
      top: false,
      child: UnitsChooserBody(
        initialWeight: initialWeight,
        initialHeight: initialHeight,
        showGrabber: true,
        onWeightSave: onWeightSave,
        onHeightSave: onHeightSave,
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Medium / expanded — anchored popup (uses showDialog with a small
// constrained ConstrainedBox so the popup is a stacked sheet on
// wider viewports without rendering a full-screen dialog).
// ---------------------------------------------------------------------------

Future<void> _showExpandedPopup(
  BuildContext context, {
  required WeightUnit initialWeight,
  required HeightUnit initialHeight,
  required Future<void> Function(WeightUnit value) onWeightSave,
  required Future<void> Function(HeightUnit value) onHeightSave,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      backgroundColor: context.colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(context.radius.r3),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: UnitsChooserBody(
          initialWeight: initialWeight,
          initialHeight: initialHeight,
          showGrabber: false,
          onWeightSave: onWeightSave,
          onHeightSave: onHeightSave,
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Body — shared between the compact sheet and the expanded popup.
// ---------------------------------------------------------------------------

/// Stateful presentation body shared by the compact sheet and the
/// expanded dialog. Owns the locally-mirrored selection per axis and a
/// global `_saving` lock that prevents two PATCHes racing the same
/// `meProvider`. On failure, only the just-tapped axis rolls back; the
/// other section is left alone (PM acceptance §2.1).
class UnitsChooserBody extends StatefulWidget {
  const UnitsChooserBody({
    required this.initialWeight,
    required this.initialHeight,
    required this.showGrabber,
    required this.onWeightSave,
    required this.onHeightSave,
    super.key,
  });

  final WeightUnit initialWeight;
  final HeightUnit initialHeight;
  final bool showGrabber;
  final Future<void> Function(WeightUnit value) onWeightSave;
  final Future<void> Function(HeightUnit value) onHeightSave;

  @override
  State<UnitsChooserBody> createState() => _UnitsChooserBodyState();
}

class _UnitsChooserBodyState extends State<UnitsChooserBody> {
  late WeightUnit _selectedWeight = widget.initialWeight;
  late HeightUnit _selectedHeight = widget.initialHeight;

  /// `true` while a per-row PATCH is in flight. The whole sheet locks
  /// (no second PATCH can fire) so we never race two writes against
  /// the same `meProvider`. Releases on success or failure.
  bool _saving = false;

  /// T-24 Case 1 — per-row save handler. The sheet stays open after
  /// the PATCH so the user can keep editing the other axis (PM
  /// acceptance §2.1). `meProvider` invalidation is what flips the
  /// downstream `weightUnitProvider` / `heightUnitProvider` on the
  /// next frame — both happen inside [UnitsChooserBody.onWeightSave].
  Future<void> _selectWeight(WeightUnit picked) async {
    if (_saving) return;
    if (picked == _selectedWeight) return;
    final previous = _selectedWeight;
    setState(() {
      _selectedWeight = picked;
      _saving = true;
    });
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await widget.onWeightSave(picked);
      if (!mounted) return;
      setState(() => _saving = false);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _selectedWeight = previous;
        _saving = false;
      });
      messenger?.showSnackBar(
        const SnackBar(
          content: Text("Couldn't update unit. Try again."),
        ),
      );
    }
  }

  /// T-24 Case 1 — see [_selectWeight].
  Future<void> _selectHeight(HeightUnit picked) async {
    if (_saving) return;
    if (picked == _selectedHeight) return;
    final previous = _selectedHeight;
    setState(() {
      _selectedHeight = picked;
      _saving = true;
    });
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await widget.onHeightSave(picked);
      if (!mounted) return;
      setState(() => _saving = false);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _selectedHeight = previous;
        _saving = false;
      });
      messenger?.showSnackBar(
        const SnackBar(
          content: Text("Couldn't update unit. Try again."),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final space = context.space;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (widget.showGrabber)
          Padding(
            padding: EdgeInsets.only(top: space.x2),
            child: Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: context.colors.line,
                  borderRadius:
                      BorderRadius.circular(context.radius.rPill),
                ),
              ),
            ),
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            space.x5,
            space.x4,
            space.x5,
            space.x2,
          ),
          child: Text('Units', style: context.text.title),
        ),
        // Weight section.
        const _SectionLabel('Weight'),
        for (final unit in WeightUnit.values)
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: space.x5,
              vertical: space.x1,
            ),
            child: ActivityOption(
              key: ValueKey<String>('weight-unit-${unit.wire}'),
              title: weightUnitTitle(unit),
              subtitle: weightUnitSubtitle(unit),
              selected: _selectedWeight == unit,
              onTap: _saving ? null : () => _selectWeight(unit),
            ),
          ),
        SizedBox(height: space.x2),
        // Height section.
        const _SectionLabel('Height'),
        for (final unit in HeightUnit.values)
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: space.x5,
              vertical: space.x1,
            ),
            child: ActivityOption(
              key: ValueKey<String>('height-unit-${unit.wire}'),
              title: heightUnitTitle(unit),
              subtitle: heightUnitSubtitle(unit),
              selected: _selectedHeight == unit,
              onTap: _saving ? null : () => _selectHeight(unit),
            ),
          ),
        SizedBox(height: space.x3),
        // "Done" footer — the accent affordance the sheet pops through.
        // T-04: primary action == accent.
        Padding(
          padding: EdgeInsets.fromLTRB(space.x5, 0, space.x5, space.x4),
          child: PrimaryButton(
            key: const Key('units-chooser-done'),
            label: 'Done',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.space.x5,
        context.space.x2,
        context.space.x5,
        context.space.x1,
      ),
      child: Text(
        text.toUpperCase(),
        style: context.text.eyebrow.copyWith(color: context.colors.ink3),
      ),
    );
  }
}
