import 'package:flutter/material.dart';

import '../../../domain/enums.dart';
import '../../../form_factor/form_factor.dart';
import '../../../theme/context_extensions.dart';
import '../../../widgets/activity_option.dart';

/// Profile → Preferences → Units chooser (LU-010).
///
/// Tapping the Units row opens this chooser:
/// - On `compact`, a [showModalBottomSheet] with three
///   [ActivityOption]-shaped rows — kilograms, pounds, stones & pounds.
/// - On `medium` / `expanded`, an anchored popup menu (T-15).
///
/// **Pure presentation leaf** (see `specs/testing_guide.md` §4.4). The
/// leaf imports no providers; on selection it awaits the container's
/// [onSave] callback, which PATCHes `weight_unit` via
/// `profileRepositoryProvider` and invalidates `meProvider`. The
/// downstream [weightUnitProvider] flips on the next frame so every
/// weight-rendering widget refreshes (T-18).
///
/// T-24 Case 1 — pop-to-source (both form-factor branches). `/me` is
/// the source; the compact sheet calls `navigator.pop()` after the
/// PATCH lands, and the expanded `showMenu` flow pops itself when the
/// user taps an item.
///
/// Failure path: keep the chooser open and surface a SnackBar
/// (`"Couldn't update unit. Try again."`).
///
/// **Feature-private**: lives under `lib/features/profile/widgets/`,
/// not `lib/widgets/`, because nothing outside the profile screen
/// uses it (T-23 — the lifted-widget inventory is the architect's
/// component list; this chooser isn't in it).
Future<void> showWeightUnitChooser(
  BuildContext context, {
  required WeightUnit initial,
  required Future<void> Function(WeightUnit value) onSave,
}) {
  final formFactor = FormFactor.of(context);
  if (formFactor.isCompact) {
    return _showCompactSheet(context, initial: initial, onSave: onSave);
  }
  return _showExpandedMenu(context, initial: initial, onSave: onSave);
}

// ---------------------------------------------------------------------------
// Compact — modal bottom sheet with ActivityOption-shaped rows.
// ---------------------------------------------------------------------------

Future<void> _showCompactSheet(
  BuildContext context, {
  required WeightUnit initial,
  required Future<void> Function(WeightUnit value) onSave,
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
      child: WeightUnitChooserBody(initial: initial, onSave: onSave),
    ),
  );
}

/// Stateful presentation body for the compact-form bottom sheet.
/// Owns the in-flight `_saving` flag + the locally-mirrored selection.
/// On failure rolls back and surfaces a SnackBar; on success pops to
/// source.
class WeightUnitChooserBody extends StatefulWidget {
  const WeightUnitChooserBody({
    required this.initial,
    required this.onSave,
    super.key,
  });

  final WeightUnit initial;
  final Future<void> Function(WeightUnit value) onSave;

  @override
  State<WeightUnitChooserBody> createState() => _WeightUnitChooserBodyState();
}

class _WeightUnitChooserBodyState extends State<WeightUnitChooserBody> {
  late WeightUnit _value = widget.initial;
  bool _saving = false;

  Future<void> _select(WeightUnit picked) async {
    if (_saving) return;
    final previous = _value;
    setState(() {
      _value = picked;
      _saving = true;
    });
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await widget.onSave(picked);
      if (!mounted) return;
      navigator.pop();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _value = previous;
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // Grabber — matches the rest of the profile editor shells.
        Padding(
          padding: EdgeInsets.only(top: context.space.x2),
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
            context.space.x5,
            context.space.x4,
            context.space.x5,
            context.space.x2,
          ),
          child: Text('Units', style: context.text.title),
        ),
        for (final unit in WeightUnit.values)
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: context.space.x5,
              vertical: context.space.x1,
            ),
            child: ActivityOption(
              key: ValueKey<String>('weight-unit-${unit.wire}'),
              title: _title(unit),
              subtitle: _subtitle(unit),
              selected: _value == unit,
              onTap: _saving ? null : () => _select(unit),
            ),
          ),
        SizedBox(height: context.space.x3),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Medium / expanded — anchored popup menu.
// ---------------------------------------------------------------------------

Future<void> _showExpandedMenu(
  BuildContext context, {
  required WeightUnit initial,
  required Future<void> Function(WeightUnit value) onSave,
}) async {
  final overlay =
      Overlay.of(context).context.findRenderObject() as RenderBox?;
  final button = context.findRenderObject() as RenderBox?;
  if (overlay == null || button == null) return;
  final topLeft =
      button.localToGlobal(Offset.zero, ancestor: overlay);
  final bottomRight = button.localToGlobal(
    button.size.bottomRight(Offset.zero),
    ancestor: overlay,
  );
  final position = RelativeRect.fromRect(
    Rect.fromPoints(topLeft, bottomRight),
    Offset.zero & overlay.size,
  );
  final colors = context.colors;
  final messenger = ScaffoldMessenger.maybeOf(context);

  final picked = await showMenu<WeightUnit>(
    context: context,
    position: position,
    color: colors.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(context.radius.r2),
    ),
    items: <PopupMenuEntry<WeightUnit>>[
      for (final unit in WeightUnit.values)
        PopupMenuItem<WeightUnit>(
          key: ValueKey<String>('weight-unit-menu-${unit.wire}'),
          value: unit,
          child: _MenuRow(
            title: _title(unit),
            subtitle: _subtitle(unit),
            selected: unit == initial,
          ),
        ),
    ],
  );
  if (picked == null || picked == initial) return;
  try {
    await onSave(picked);
  } catch (_) {
    messenger?.showSnackBar(
      const SnackBar(
        content: Text("Couldn't update unit. Try again."),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.title,
    required this.subtitle,
    required this.selected,
  });

  final String title;
  final String subtitle;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SizedBox(
      width: 260,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(title, style: context.text.bodyStrong),
                SizedBox(height: context.space.x05),
                Text(subtitle, style: context.text.meta),
              ],
            ),
          ),
          if (selected)
            Icon(Icons.check, size: 18, color: colors.accent),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Labels.
// ---------------------------------------------------------------------------

String _title(WeightUnit unit) => weightUnitTitle(unit);

String _subtitle(WeightUnit unit) => weightUnitSubtitle(unit);

/// Public title for a weight unit row. Exposed (no underscore) so the
/// joined `UnitsChooser` (architect §5.8) can re-use the exact same
/// label strings the per-axis chooser uses — keeps drift from creeping
/// in the two composition sites.
String weightUnitTitle(WeightUnit unit) {
  switch (unit) {
    case WeightUnit.kg:
      return 'Kilograms (kg)';
    case WeightUnit.lb:
      return 'Pounds (lb)';
    case WeightUnit.st:
      return 'Stones & pounds (st)';
  }
}

/// Public subtitle for a weight unit row. See [weightUnitTitle].
String weightUnitSubtitle(WeightUnit unit) {
  switch (unit) {
    case WeightUnit.kg:
      return 'Common worldwide';
    case WeightUnit.lb:
      return 'Common in the US';
    case WeightUnit.st:
      return 'Common in the UK';
  }
}
