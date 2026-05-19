import 'package:flutter/material.dart';

import '../../../domain/enums.dart';
import '../../../form_factor/form_factor.dart';
import '../../../theme/context_extensions.dart';
import '../../../widgets/activity_option.dart';

/// Profile → Preferences → Units chooser — height axis (QL-104).
///
/// Mirror of `showWeightUnitChooser`. Tapping a height-axis row in the
/// joined `showUnitsChooser` is the canonical compositional path; this
/// standalone entry point is kept for source-compat with any caller
/// that wants a height-only chooser (none today; architect §5.7 reserves
/// the seam as a per-axis primitive).
///
/// - On `compact`, a [showModalBottomSheet] with two [ActivityOption]
///   rows — Centimeters and Feet & inches.
/// - On `medium` / `expanded`, an anchored popup menu (T-15).
///
/// **Pure presentation leaf** (see `specs/testing_guide.md` §4.4).
/// The leaf imports no providers. On selection it awaits the
/// container-supplied [onSave] callback, which performs the PATCH
/// against `profileRepositoryProvider` and `ref.invalidate(meProvider)`
/// — the downstream [heightUnitProvider] flips on the next frame so
/// every height-rendering widget refreshes (T-18).
///
/// **T-24 Case 1 — pop-to-source.** `/me` is the source; the compact
/// sheet calls `navigator.pop()` after the PATCH lands, and the
/// expanded `showMenu` flow pops itself when the user taps an item.
///
/// Failure path: keep the chooser open and surface a SnackBar
/// (`"Couldn't update unit. Try again."`).
Future<void> showHeightUnitChooser(
  BuildContext context, {
  required HeightUnit initial,
  required Future<void> Function(HeightUnit value) onSave,
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
  required HeightUnit initial,
  required Future<void> Function(HeightUnit value) onSave,
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
      child: HeightUnitChooserBody(initial: initial, onSave: onSave),
    ),
  );
}

/// Stateful presentation body for the compact-form bottom sheet.
/// Owns the in-flight `_saving` flag + the locally-mirrored selection
/// (the visual selection updates eagerly on tap so the chooser feels
/// responsive while the PATCH is in flight). On failure rolls back
/// and surfaces a SnackBar; on success pops to source.
class HeightUnitChooserBody extends StatefulWidget {
  const HeightUnitChooserBody({
    required this.initial,
    required this.onSave,
    super.key,
  });

  final HeightUnit initial;
  final Future<void> Function(HeightUnit value) onSave;

  @override
  State<HeightUnitChooserBody> createState() => _HeightUnitChooserBodyState();
}

class _HeightUnitChooserBodyState extends State<HeightUnitChooserBody> {
  late HeightUnit _value = widget.initial;
  bool _saving = false;

  /// T-24 Case 1 — pop-to-source. The container's `onSave` callback
  /// PATCHes `height_unit` + invalidates `meProvider`; we then pop so
  /// the underlying Units row re-renders with the freshly persisted
  /// unit.
  Future<void> _select(HeightUnit picked) async {
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
        for (final unit in HeightUnit.values)
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: context.space.x5,
              vertical: context.space.x1,
            ),
            child: ActivityOption(
              key: ValueKey<String>('height-unit-${unit.wire}'),
              title: heightUnitTitle(unit),
              subtitle: heightUnitSubtitle(unit),
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
  required HeightUnit initial,
  required Future<void> Function(HeightUnit value) onSave,
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

  final picked = await showMenu<HeightUnit>(
    context: context,
    position: position,
    color: colors.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(context.radius.r2),
    ),
    items: <PopupMenuEntry<HeightUnit>>[
      for (final unit in HeightUnit.values)
        PopupMenuItem<HeightUnit>(
          key: ValueKey<String>('height-unit-menu-${unit.wire}'),
          value: unit,
          child: _MenuRow(
            title: heightUnitTitle(unit),
            subtitle: heightUnitSubtitle(unit),
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
// Labels. Exposed for composition by `units_chooser.dart` (architect
// §5.8 — the joined sheet composes the same row labels).
// ---------------------------------------------------------------------------

String heightUnitTitle(HeightUnit unit) {
  switch (unit) {
    case HeightUnit.cm:
      return 'Centimeters (cm)';
    case HeightUnit.ftIn:
      return 'Feet & inches (ft, in)';
  }
}

String heightUnitSubtitle(HeightUnit unit) {
  switch (unit) {
    case HeightUnit.cm:
      return 'Common worldwide';
    case HeightUnit.ftIn:
      return 'Common in the US and UK';
  }
}
