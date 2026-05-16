import 'package:flutter/material.dart';

import '../theme/context_extensions.dart';

/// Canonical empty-state composition.
///
/// Architecture appendix names this widget; it lives here so every
/// "no results / nothing logged yet / first run" surface picks up the
/// same icon size, text scale, and `ink2`/`ink3` token wash. T-08 says
/// loading is a skeleton; this widget owns the *empty* half of the
/// loading/empty/error trichotomy.
///
/// Required `icon`, `title`, `body`. The optional `action` slot accepts
/// any widget (typically a `PrimaryButton` — e.g. "Log your first food"
/// on the day view, "Browse foods" on /foods/mine) so this widget stays
/// neutral to the action type. T-13 owns the migration of the four
/// `CircularProgressIndicator` violations to use `Skeleton` + this
/// `EmptyState` together.
///
/// Source: extracted from `features/search/search_screen.dart`'s
/// `_EmptyState` (the closest existing shape). The icon and action
/// slot are new — search rendered text-only.
///
/// **Tenants honored**: T-01 (no raw hex / padding), T-13 (empty != spinner).
class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
    super.key,
  });

  /// Leading glyph. Sized 32 px against the `ink3` token — neutral, not
  /// macro-colored (T-03).
  final IconData icon;

  /// One-line headline; `bodyStrong` over `ink`.
  final String title;

  /// One- to two-line explanation; `meta` over `ink2`. Wraps freely.
  final String body;

  /// Optional CTA — typically a `PrimaryButton`. Renders below `body`
  /// with `space.x4` separation when non-null.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final space = context.space;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: space.x5,
        vertical: space.x6,
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 32, color: colors.ink3),
            SizedBox(height: space.x3),
            Text(
              title,
              textAlign: TextAlign.center,
              style: text.bodyStrong.copyWith(color: colors.ink),
            ),
            SizedBox(height: space.x1),
            Text(
              body,
              textAlign: TextAlign.center,
              style: text.meta.copyWith(color: colors.ink2),
            ),
            if (action != null) ...<Widget>[
              SizedBox(height: space.x4),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
