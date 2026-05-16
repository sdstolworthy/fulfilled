import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../domain/enums.dart';
import '../../../domain/units/weight.dart';
import '../../../domain/weight.dart';
import '../../../form_factor/form_factor.dart';
import '../../../providers/weight_providers.dart';
import '../../../theme/context_extensions.dart';
import '../../../widgets/empty_state.dart';
import '../../../widgets/primary_button.dart';
import '../../../widgets/skeleton.dart';
import 'log_weight_sheet.dart';

/// "Recent entries" card on screen 06. Renders the last ~10 entries
/// from `weightHistoryProvider` newest-first with date / weight / delta.
///
/// **Delta logic.** Delta is the difference between this entry and the
/// next-older entry (signed, kg). Negative → accent (losing); positive →
/// danger color (gaining). Zero shows as `±0.0`.
///
/// Tenants: T-02 tabular figures, T-08 skeleton when loading (lifted
/// `Skeleton` primitive — T-23 shared widgets), T-11 errors render an
/// `EmptyState` + a SnackBar shim (not modal), T-17 Decimal math, T-21
/// weight rendered via `formatWeightKg`.
class WeightHistoryList extends ConsumerWidget {
  const WeightHistoryList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final historyAsync = ref.watch(weightHistoryProvider);

    // T-11 — SnackBar fires on transition into the error state so the
    // user notices even if scrolled away from the inline EmptyState.
    ref.listen<AsyncValue<List<WeightEntry>>>(weightHistoryProvider,
        (prev, next) {
      if (next.hasError && (prev == null || !prev.hasError)) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text("Couldn't load weight history: ${next.error}"),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    });

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.space.x5),
      child: historyAsync.when(
        data: (entries) => _List(entries: entries),
        loading: () => const _Skeleton(),
        error: (_, __) => _Error(
          onRetry: () => ref.invalidate(weightHistoryProvider),
        ),
      ),
    );
  }
}

class _List extends StatelessWidget {
  const _List({required this.entries});

  final List<WeightEntry> entries;

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
        child: LogWeightSheet(currentRange: range, asDialog: true),
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
  });

  final WeightEntry entry;
  final WeightEntry? previous;
  final bool isLast;

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

    return Container(
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
              Semantics(
                label: '${formatWeightKg(entry.weightKg)} kilograms on '
                    '${dayFmt.format(entry.recordedOn)}',
                child: Text(
                  '${formatWeightKg(entry.weightKg)} kg',
                  style: context.text.bodyStrongNumeric,
                ),
              ),
              SizedBox(height: context.space.x05),
              if (delta != null) _DeltaText(delta: delta),
            ],
          ),
        ],
      ),
    );
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
  const _DeltaText({required this.delta});

  final Decimal delta;

  @override
  Widget build(BuildContext context) {
    final isZero = delta == Decimal.zero;
    final negative = delta < Decimal.zero;
    final color = isZero
        ? context.colors.ink3
        : (negative ? context.colors.accent : context.colors.danger);
    final magnitude = delta.abs();
    final sign = isZero ? '±' : (negative ? '−' : '+');
    final label = '$sign${formatWeightKg(magnitude)}';

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
