import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../domain/units/weight.dart';
import '../../../domain/weight.dart';
import '../../../providers/weight_providers.dart';
import '../../../theme/context_extensions.dart';

/// "Recent entries" card on screen 06. Renders the last ~10 entries
/// from `weightHistoryProvider` newest-first with date / weight / delta.
///
/// **Delta logic.** Delta is the difference between this entry and the
/// next-older entry (signed, kg). Negative → accent (losing); positive →
/// danger color (gaining). Zero shows as `±0.0`.
///
/// Tenants: T-02 tabular figures, T-08 skeleton when loading, T-17 Decimal
/// math, T-21 weight rendered via `formatWeightKg`.
class WeightHistoryList extends ConsumerWidget {
  const WeightHistoryList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final historyAsync = ref.watch(weightHistoryProvider);

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.space.x5),
      child: historyAsync.when(
        data: (entries) => _List(entries: entries),
        loading: () => const _Skeleton(),
        error: (_, __) => const _Error(),
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
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: context.space.x4,
            vertical: context.space.x4,
          ),
          child: Text(
            'No entries yet. Tap "Log weight" to record your first.',
            style: context.text.meta,
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

class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.colors.surface,
        borderRadius: BorderRadius.circular(context.radius.r3),
        border: Border.all(color: context.colors.line),
      ),
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
                horizontal: context.space.x4,
                vertical: context.space.x3,
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        _bar(context, 56, 14),
                        SizedBox(height: context.space.x1),
                        _bar(context, 92, 11),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      _bar(context, 56, 15),
                      SizedBox(height: context.space.x1),
                      _bar(context, 28, 11),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _bar(BuildContext context, double w, double h) {
    return Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: context.colors.line2,
        borderRadius: BorderRadius.circular(context.radius.r1),
      ),
    );
  }
}

class _Error extends StatelessWidget {
  const _Error();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.colors.dangerSoft,
        borderRadius: BorderRadius.circular(context.radius.r3),
        border: Border.all(color: context.colors.danger),
      ),
      padding: EdgeInsets.all(context.space.x4),
      child: Text(
        'Couldn\'t load weight history.',
        style: context.text.meta.copyWith(color: context.colors.danger),
      ),
    );
  }
}
