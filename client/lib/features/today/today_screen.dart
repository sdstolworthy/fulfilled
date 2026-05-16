import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../form_factor/form_factor.dart';
import 'day_view_compact.dart';
import 'day_view_expanded.dart';

/// Screen 01 — the Today day view.
///
/// Public widget the router mounts. Branches on form factor at the root
/// (T-15: every form-factor branch lives at the screen root, never deep
/// in a leaf widget) and delegates to the matching variant.
///
/// **Date resolution.** The widget owns "what day are we showing" so the
/// rest of the tree never reaches for `DateTime.now()` (T-16 wants the
/// local-calendar value computed in one place). When the router lands on
/// `/today/:date` the integration layer should construct
/// `TodayScreen(date: parsed)` directly; the default constructor resolves
/// to the user's local now.
class TodayScreen extends ConsumerWidget {
  const TodayScreen({this.date, super.key});

  /// Override for the day to render. Null = local-now (the default the
  /// router uses for `/today`).
  final DateTime? date;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = _resolveDate();
    final formFactor = FormFactor.of(context);

    // T-15 — form-factor branch lives at the root. Medium and compact
    // share the same body (architect §1 says the right rail "folds into a
    // stacked secondary card row" on medium, and v1 collapses to the
    // compact stack until that medium-specific composition lands).
    switch (formFactor) {
      case FormFactor.compact:
      case FormFactor.medium:
        return DayViewCompact(date: today);
      case FormFactor.expanded:
        return DayViewExpanded(date: today);
    }
  }

  DateTime _resolveDate() {
    final override = date;
    if (override != null) {
      return DateTime(override.year, override.month, override.day);
    }
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }
}
