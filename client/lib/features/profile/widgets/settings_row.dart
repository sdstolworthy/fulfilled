import 'package:flutter/material.dart';

import '../../../theme/context_extensions.dart';

/// A single row in a `SettingsCard`. Layout: 30 px accent-soft icon chip
/// (left) → label (mid) → value + chevron (right). The whole row is
/// tappable when [onTap] is non-null; an informational row (Units in v1)
/// passes `onTap: null` and renders without a chevron.
///
/// T-06 minimum: the InkWell expands to fill the row, with vertical
/// padding picked so the visual height clears 44 px on `compact`.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    required this.icon,
    required this.label,
    this.value,
    this.onTap,
    this.semanticsLabel,
    super.key,
  });

  final IconData icon;
  final String label;

  /// The trailing value text. Optional — leave null for an "action" row
  /// like Export data where the chevron implies "go".
  final String? value;

  /// Null disables the tap + chevron. Used for the Units informational
  /// row in v1.
  final VoidCallback? onTap;

  /// Optional override for the semantic announcement. If null, we
  /// concatenate label + value.
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final space = context.space;

    final row = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: space.x4,
        vertical: space.x3 + 2,
      ),
      child: Row(
        children: <Widget>[
          _IconChip(icon: icon),
          SizedBox(width: space.x3),
          Expanded(
            child: Text(
              label,
              style: context.text.body,
            ),
          ),
          if (value != null)
            Padding(
              padding: EdgeInsets.only(right: space.x1),
              child: Text(
                value!,
                style: context.text.body.copyWith(color: colors.ink2),
              ),
            ),
          if (onTap != null)
            Icon(
              Icons.chevron_right,
              size: 18,
              color: colors.ink3,
            ),
        ],
      ),
    );

    return Semantics(
      label: semanticsLabel ??
          (value == null ? label : '$label, ${value!}'),
      button: onTap != null,
      child: Material(
        color: colors.surface,
        child: InkWell(
          onTap: onTap,
          child: row,
        ),
      ),
    );
  }
}

class _IconChip extends StatelessWidget {
  const _IconChip({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: context.colors.accentSoft,
        borderRadius: BorderRadius.circular(context.radius.r1),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: 16, color: context.colors.accent),
    );
  }
}
