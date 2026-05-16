import 'package:flutter/material.dart';

import '../theme/context_extensions.dart';

/// A neutral placeholder rendered at every route the foundation defines.
///
/// Screen agents replace these one-by-one with real implementations under
/// `lib/features/<screen>/`. Until then, the placeholder gives the running
/// shell a visible label and the current route — enough to verify
/// navigation works without pretending a screen has been built.
///
/// It is deliberately ugly: a screen agent should be embarrassed to leave
/// it in place. Don't dress it up.
class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({
    required this.screenName,
    required this.routePath,
    this.detail,
    super.key,
  });

  /// Display name (e.g. "01 Day view").
  final String screenName;

  /// The concrete URL we're rendering at (post-substitution).
  final String routePath;

  /// Optional extra line — e.g. a path parameter value, the active step
  /// number, the food id. Helpful for the agent who follows you.
  final String? detail;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(context.space.x6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'PLACEHOLDER',
              style: context.text.eyebrow.copyWith(color: context.colors.accent),
            ),
            SizedBox(height: context.space.x2),
            Text(screenName, style: context.text.pageTitle),
            SizedBox(height: context.space.x3),
            Text(routePath, style: context.text.metaNumeric),
            if (detail != null) ...<Widget>[
              SizedBox(height: context.space.x1),
              Text(detail!, style: context.text.meta),
            ],
            SizedBox(height: context.space.x4),
            Text(
              'Replace this with the real screen under lib/features/.\n'
              'See client/README.md for the screen-agent contract.',
              style: context.text.meta,
            ),
          ],
        ),
      ),
    );
  }
}
