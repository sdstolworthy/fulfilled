import 'package:flutter/material.dart';

import '../../../theme/context_extensions.dart';

/// Section card on screen 08. Holds an eyebrow header above a rounded
/// surface with N `SettingsRow`s. Inner separators are 1 px `line2`,
/// matching the mock; outer border is 1 px `line` per the v1 card spec
/// in architecture §2.4 (no shadow).
///
/// The card itself does not know about the rows' content — it just
/// stacks them with `Divider`s between. Tap handling lives on the rows
/// themselves so the card can mix tappable + non-tappable entries (the
/// Units row is informational in v1; see screen brief).
class SettingsCard extends StatelessWidget {
  const SettingsCard({
    required this.title,
    required this.rows,
    super.key,
  });

  /// Eyebrow header rendered above the card — e.g. "Body", "Preferences".
  final String title;

  /// Rendered top-to-bottom. Dividers (1 px `line2`) are inserted between
  /// adjacent rows by this widget; callers do not provide them.
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(
            context.space.x5,
            context.space.x4,
            context.space.x5,
            context.space.x2,
          ),
          child: Text(
            title.toUpperCase(),
            style: context.text.eyebrow.copyWith(color: context.colors.ink3),
          ),
        ),
        Container(
          margin: EdgeInsets.symmetric(horizontal: context.space.x5),
          decoration: BoxDecoration(
            color: context.colors.surface,
            border: Border.all(color: context.colors.line),
            borderRadius: BorderRadius.circular(context.radius.r3),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: <Widget>[
              for (var i = 0; i < rows.length; i++) ...<Widget>[
                rows[i],
                if (i < rows.length - 1)
                  Divider(
                    height: 1,
                    thickness: 1,
                    color: context.colors.line2,
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
