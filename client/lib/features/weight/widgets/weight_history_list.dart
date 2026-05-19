import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../domain/enums.dart';
import '../../../domain/units/weight.dart';
import '../../../domain/weight.dart';
import '../../../form_factor/form_factor.dart';
import '../../../theme/context_extensions.dart';
import '../../../widgets/empty_state.dart';
import '../../../widgets/primary_button.dart';
import '../../../widgets/skeleton.dart';
import 'log_weight_sheet.dart';

/// "Recent entries" card on screen 06. Renders the last ~10 entries
/// from `weightHistoryProvider` newest-first with date / weight / delta.
///
/// **Pure presentation widget** — takes its data via constructor
/// parameters (see `specs/testing_guide.md` §4.4). The container
/// (`WeightScreen`) does the `ref.watch` against `weightHistoryProvider`
/// and `weightUnitProvider`, branches on the AsyncValue, and renders
/// [WeightHistoryListSkeleton] or [WeightHistoryListError] on the
/// loading / error arms.
///
/// **Delta logic.** Delta is the difference between this entry and the
/// next-older entry (signed, kg). Negative → accent (losing); positive →
/// danger color (gaining). Zero shows as `±0.0`.
///
/// Tenants: T-02 tabular figures, T-08 skeleton when loading (lifted
/// `Skeleton` primitive — T-23 shared widgets), T-11 errors render an
/// `EmptyState` + a SnackBar shim (not modal — fired by the container),
/// T-17 Decimal math, T-21 weight rendered via `formatWeight` /
/// `formatWeightWithUnit`.
class WeightHistoryList extends StatelessWidget {
  const WeightHistoryList({
    super.key,
    required this.entries,
    required this.unit,
  });

  final List<WeightEntry> entries;
  final WeightUnit unit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.space.x5),
      child: _List(entries: entries, unit: unit),
    );
  }
}

/// Loading placeholder for [WeightHistoryList].
class WeightHistoryListSkeleton extends StatelessWidget {
  const WeightHistoryListSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.space.x5),
      child: const _Skeleton(),
    );
  }
}

/// Error placeholder for [WeightHistoryList]. `onRetry` is wired by the
/// container — typically `() => ref.invalidate(weightHistoryProvider)`.
class WeightHistoryListError extends StatelessWidget {
  const WeightHistoryListError({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.space.x5),
      child: _Error(onRetry: onRetry),
    );
  }
}

class _List extends StatelessWidget {
  const _List({required this.entries, required this.unit});

  final List<WeightEntry> entries;
  final WeightUnit unit;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return _Card(
        child: EmptyState(
          icon: Icons.monitor_weight_outlined,
          title: 'No weight logged yet',
          body: 'Track your first entry to start the trend line.',
          action: SizedBox(
            width: 220,
            child: PrimaryButton(
              label: 'Log your first weight',
              onPressed: () => _openLogWeightSheet(context),
            ),
          ),
        ),
      );
    }
    return _Card(
      child: Column(
        children: <Widget>[
          for (var i = 0; i < entries.length; i++)
            _Row(
              entry: entries[i],
              previous: i + 1 < entries.length ? entries[i + 1] : null,
              isLast: i == entries.length - 1,
              unit: unit,
            ),
        ],
      ),
    );
  }
}

/// Open the log-weight sheet (compact: bottom sheet, medium/expanded:
/// centered dialog). Mirrors `WeightScreen._openLogSheet` so the list's
/// empty-state CTA can reach the same flow without threading a callback
/// from the screen — the empty state needs a CTA per T-013, and the
/// list is the surface that owns "no entries".
Future<void> _openLogWeightSheet(BuildContext context) async {
  // Default to the 1M range; the empty case has no series so the chosen
  // range is cosmetic for the first save.
  const range = WeightRange.oneMonth;
  if (FormFactor.of(context).isCompact) {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const LogWeightSheet(currentRange: range),
    );
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (dialogCtx) => Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(dialogCtx.radius.r4),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: const LogWeightSheet(currentRange: range, asDialog: true),
      ),
    ),
  );
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(context.radius.r3),
      child: Container(
        decoration: BoxDecoration(
          color: context.colors.surface,
          borderRadius: BorderRadius.circular(context.radius.r3),
          border: Border.all(color: context.colors.line),
        ),
        child: child,
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.entry,
    required this.previous,
    required this.isLast,
    required this.unit,
  });

  final WeightEntry entry;
  final WeightEntry? previous;
  final bool isLast;
  final WeightUnit unit;

  @override
  Widget build(BuildContext context) {
    final dayFmt = DateFormat('MMM d');
    final weekdayFmt = DateFormat('EEEE');
    final today = _today();
    final daysAgo = today.difference(_dayOf(entry.recordedOn)).inDays;
    final relative = _relativeDay(daysAgo);
    final weekday = weekdayFmt.format(entry.recordedOn);
    final subtitle = relative == null ? weekday : '$weekday · $relative';

    final delta = previous == null
        ? null
        : entry.weightKg - previous!.weightKg;

    // T-20 composed row label — date, weight, plus the delta (with
    // direction so color isn't the sole signal for "gained" vs "lost"). One
    // announcement per row; the visual leaves are excluded.
    final rowSemantics = _composeRowSemantics(
      dayLabel: dayFmt.format(entry.recordedOn),
      subtitle: subtitle,
      weightKg: entry.weightKg,
      delta: delta,
    );

    return Semantics(
      container: true,
      label: rowSemantics,
      excludeSemantics: true,
      child: Container(
        decoration: BoxDecoration(
          border: isLast
              ? null
              : Border(
                  bottom: BorderSide(color: context.colors.line2),
                ),
        ),
        padding: EdgeInsets.symmetric(
          horizontal: context.space.x4,
          vertical: context.space.x3,
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    dayFmt.format(entry.recordedOn),
                    style: context.text.bodyNumeric,
                  ),
                  SizedBox(height: context.space.x05),
                  Text(
                    subtitle,
                    style: context.text.meta.copyWith(fontSize: 11),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Text(
                  formatWeightWithUnit(entry.weightKg, unit),
                  style: context.text.bodyStrongNumeric,
                ),
                SizedBox(height: context.space.x05),
                if (delta != null) _DeltaText(delta: delta, unit: unit),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _composeRowSemantics({
    required String dayLabel,
    required String subtitle,
    required Decimal weightKg,
    required Decimal? delta,
  }) {
    final parts = <String>[
      dayLabel,
      subtitle,
      '${formatWeight(weightKg, unit)} ${unit.longLabel}',
    ];
    if (delta != null && delta != Decimal.zero) {
      final losing = delta < Decimal.zero;
      final magnitude = delta.abs();
      // "down 0.4 kilograms" / "up 0.4 kilograms" — direction words so a
      // screen-reader user gets the signal sighted users get from color.
      parts.add(
        '${losing ? 'down' : 'up'} ${formatWeight(magnitude, unit)} '
        '${unit.longLabel}',
      );
    }
    return parts.join(', ');
  }

  String? _relativeDay(int daysAgo) {
    if (daysAgo == 0) return 'today';
    if (daysAgo == 1) return 'yesterday';
    return null;
  }

  DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  DateTime _dayOf(DateTime t) => DateTime(t.year, t.month, t.day);
}

class _DeltaText extends StatelessWidget {
  const _DeltaText({required this.delta, required this.unit});

  final Decimal delta;
  final WeightUnit unit;

  @override
  Widget build(BuildContext context) {
    final isZero = delta == Decimal.zero;
    final negative = delta < Decimal.zero;
    final color = isZero
        ? context.colors.ink3
        : (negative ? context.colors.accent : context.colors.danger);
    final magnitude = delta.abs();
    final sign = isZero ? '±' : (negative ? '−' : '+');
    final label = '$sign${formatWeight(magnitude, unit)}';

    return Text(
      label,
      style: context.text.metaNumeric.copyWith(
        color: color,
        fontWeight: FontWeight.w600,
        fontSize: 11,
      ),
    );
  }
}

/// Loading skeleton — three rows that match the eventual entry-row
/// rhythm (date + weight + delta). Built from the lifted [Skeleton]
/// primitive (T-23) so the block fill, radius, and color all flow from
/// the single source of truth in `lib/widgets/skeleton.dart`.
class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    final space = context.space;
    final radius = context.radius;
    return _Card(
      child: Column(
        children: <Widget>[
          for (var i = 0; i < 3; i++)
            Container(
              decoration: BoxDecoration(
                border: i == 2
                    ? null
                    : Border(
                        bottom: BorderSide(color: context.colors.line2),
                      ),
              ),
              padding: EdgeInsets.symmetric(
                horizontal: space.x4,
                vertical: space.x3,
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Skeleton(
                          height: 14,
                          width: 56,
                          borderRadius: BorderRadius.circular(radius.r1),
                        ),
                        SizedBox(height: space.x1),
                        Skeleton(
                          height: 11,
                          width: 92,
                          borderRadius: BorderRadius.circular(radius.r1),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      Skeleton(
                        height: 15,
                        width: 56,
                        borderRadius: BorderRadius.circular(radius.r1),
                      ),
                      SizedBox(height: space.x1),
                      Skeleton(
                        height: 11,
                        width: 28,
                        borderRadius: BorderRadius.circular(radius.r1),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Error state — wraps the lifted [EmptyState] in the same bordered
/// card the rest of the list lives in, so the card silhouette stays
/// stable across data / loading / error branches. The retry CTA
/// re-invalidates `weightHistoryProvider`.
class _Error extends StatelessWidget {
  const _Error({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: EmptyState(
        icon: Icons.cloud_off,
        title: "Couldn't load weight history",
        body: 'Pull to refresh or tap retry.',
        action: SizedBox(
          width: 200,
          child: PrimaryButton(
            label: 'Retry',
            onPressed: onRetry,
          ),
        ),
      ),
    );
  }
}
