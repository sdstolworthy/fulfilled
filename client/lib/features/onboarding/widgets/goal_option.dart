import 'package:flutter/material.dart';

import '../../../theme/context_extensions.dart';

/// Big tappable card used for the screen-09 step-3 goal-direction picker
/// (architecture §3 — `GoalOption`). One per direction (lose / maintain /
/// gain) with a leading icon chip + title + meta line.
///
/// Mock contract: 14 px radius card, accent-soft fill when selected, the
/// 42 px icon chip flips from accent-soft/accent-text to accent/white
/// when selected. Title is bodyStrong, meta is `12px` ink2 (we use the
/// `meta` style — close enough; the mock's 12 px is well within the
/// architectural tolerance for the meta family).
class GoalOption extends StatelessWidget {
  const GoalOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

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
        borderRadius: BorderRadius.circular(context.radius.r3),
        child: Container(
          padding: EdgeInsets.all(context.space.x3 + 2),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(context.radius.r3),
            border: Border.all(color: border),
          ),
          child: Row(
            children: <Widget>[
              _IconChip(icon: icon, selected: selected),
              SizedBox(width: context.space.x3),
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
            ],
          ),
        ),
      ),
    );
  }
}

class _IconChip extends StatelessWidget {
  const _IconChip({required this.icon, required this.selected});

  final IconData icon;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final bg = selected ? context.colors.accent : context.colors.accentSoft;
    final fg = selected ? Colors.white : context.colors.accent;
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: bg,
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 18, color: fg),
    );
  }
}
