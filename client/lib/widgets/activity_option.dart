import 'package:flutter/material.dart';

import '../theme/context_extensions.dart';

/// Radio-style large list option used by the onboarding step-2 activity
/// picker and the profile activity-level editor (architecture §3 —
/// `ActivityOption`).
///
/// Mock contract: 12 px radius card, surface bg unselected / accentSoft
/// bg selected, 18 px circular indicator with a 9 px accent dot when
/// selected. Title (bodyStrong) + subtitle (meta) inline.
///
/// **Canonical rendering** for both screens: the architect ruled the
/// onboarding shape (custom radio dot, ink-coloured title) is the design
/// of record. The profile picker's old `_ActivityRow` (filled radio icon
/// with accent-tinted title) was a drift; both now go through this
/// widget.
class ActivityOption extends StatelessWidget {
  const ActivityOption({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final bg = selected ? context.colors.accentSoft : context.colors.surface;
    final border = selected ? context.colors.accent : context.colors.line;
    return Semantics(
      button: true,
      selected: selected,
      label: '$title. $subtitle',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(context.radius.r2),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: context.space.x3,
            vertical: context.space.x3,
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(context.radius.r2),
            border: Border.all(color: border),
          ),
          child: Row(
            children: <Widget>[
              _RadioDot(selected: selected),
              SizedBox(width: context.space.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      title,
                      style: context.text.bodyStrong,
                    ),
                    SizedBox(height: context.space.x05),
                    Text(
                      subtitle,
                      style: context.text.meta,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RadioDot extends StatelessWidget {
  const _RadioDot({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final ring = selected ? context.colors.accent : context.colors.ink3;
    return SizedBox(
      width: 18,
      height: 18,
      child: Center(
        child: Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: ring, width: 1.5),
          ),
          child: selected
              ? Center(
                  child: Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: context.colors.accent,
                    ),
                  ),
                )
              : null,
        ),
      ),
    );
  }
}
