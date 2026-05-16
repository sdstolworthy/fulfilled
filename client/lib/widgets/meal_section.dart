// Empty-meal exception: the meal header renders at 0 kcal with
// colors.emptyDot — it does NOT delegate to EmptyState. See
// flutter_ui_architecture.md §9 and dev_tickets.md T-013.
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../domain/day_summary.dart';
import '../domain/log_entry.dart';
import '../domain/meal.dart';
import '../domain/units/energy.dart';
import '../theme/context_extensions.dart';

/// One meal section card: header (dot + name + kcal total) → list of food
/// rows → "Add food" footer.
///
/// **Empty-meal rule (architect §9 screen-01 gotcha).** When the subtotal
/// has zero entries the card still renders, the total shows `0 kcal`, and
/// the dot color is `AppColors.emptyDot` (the deliberate per-empty color,
/// defined once in `lib/theme/tokens/colors.dart`). The accent dot only
/// appears on populated meals.
///
/// The same widget renders on compact and expanded. Per T-15 the leaves
/// are form-factor-blind; the parent picks `dense` to tighten paddings on
/// the desktop 2×2 grid. The mocks differ only on inner padding + entry
/// type size, so a single boolean threads the difference.
class MealSection extends StatelessWidget {
  const MealSection({
    required this.subtotal,
    required this.entries,
    required this.onAddTap,
    this.dense = false,
    this.onEntryTap,
    super.key,
  });

  /// Per-meal totals from the day summary. Drives the header and the
  /// empty-state branch — T-09 keeps numbers single-source.
  final MealSubtotal subtotal;

  /// Entries for *this meal only*. Caller filters from
  /// `logEntriesProvider(date)` by `entry.meal`.
  final List<LogEntry> entries;

  /// Tapped on the "Add food" footer. Caller pushes the search route with
  /// the meal pre-selected.
  final VoidCallback onAddTap;

  /// Optional handler for tapping an entry row (future: edit / delete).
  /// Null = the row is read-only.
  final void Function(LogEntry entry)? onEntryTap;

  /// `true` slims the vertical padding for the expanded 2×2 grid.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final isEmpty = entries.isEmpty;

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(context.radius.r3),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _Header(meal: subtotal.meal, kcal: subtotal.kcal, isEmpty: isEmpty),
          for (final entry in entries)
            _EntryRow(
              entry: entry,
              onTap: onEntryTap == null ? null : () => onEntryTap!(entry),
              dense: dense,
            ),
          _AddFootRow(onTap: onAddTap, dense: dense, drawTopBorder: !isEmpty),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.meal,
    required this.kcal,
    required this.isEmpty,
  });

  final Meal meal;
  final Decimal kcal;
  final bool isEmpty;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dotColor = isEmpty ? colors.emptyDot : colors.accent;
    final kcalText = formatKcal(kcal);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.space.x4,
        context.space.x3 + 2,
        context.space.x4,
        context.space.x2 + 2,
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: dotColor,
              shape: BoxShape.circle,
            ),
          ),
          SizedBox(width: context.space.x2),
          Expanded(
            child: Text(
              meal.label,
              style: context.text.bodyStrong,
            ),
          ),
          Text.rich(
            TextSpan(
              style: context.text.metaNumeric.copyWith(color: colors.ink2),
              children: <InlineSpan>[
                TextSpan(
                  text: kcalText,
                  style: context.text.metaNumeric.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const TextSpan(text: ' kcal'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.entry,
    required this.onTap,
    required this.dense,
  });

  final LogEntry entry;
  final VoidCallback? onTap;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;

    return InkWell(
      onTap: onTap,
      // T-018 / §7: rows tint to `line2` on hover; never accent, never
      // elevation. Pin Material's hover paint to the token so the
      // primitive matches `Hoverable`.
      hoverColor: colors.line2,
      child: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: colors.line2)),
        ),
        padding: EdgeInsets.symmetric(
          horizontal: context.space.x4,
          vertical: dense ? context.space.x2 + 1 : context.space.x2 + 2,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    entry.foodName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.body,
                  ),
                  SizedBox(height: context.space.x05),
                  Text(
                    _metaLine(entry),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.meta,
                  ),
                ],
              ),
            ),
            SizedBox(width: context.space.x3),
            _KcalCell(entry: entry, dense: dense),
          ],
        ),
      ),
    );
  }

  String _metaLine(LogEntry entry) {
    final parts = <String>[];
    final serving = entry.servingName;
    if (serving != null && serving.isNotEmpty) parts.add(serving);
    // The wire doesn't give us brand on a log entry — the food name is
    // already denormalized. Keep the meta line to the serving label so we
    // never invent a brand string. The expanded mock matches the compact.
    return parts.join(' · ');
  }
}

class _KcalCell extends StatelessWidget {
  const _KcalCell({required this.entry, required this.dense});
  final LogEntry entry;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final kcal = formatKcal(entry.kcal);

    // Mobile mock: kcal number above a tiny "KCAL" caption.
    // Web mock: a single 13-px bold kcal value, no caption.
    if (dense) {
      return Text(
        kcal,
        style: context.text.metaNumeric.copyWith(
          color: colors.ink,
          fontWeight: FontWeight.w600,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          kcal,
          style: context.text.metaNumeric.copyWith(
            color: colors.ink,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
        Text(
          'KCAL',
          style: context.text.eyebrow.copyWith(
            color: colors.ink2,
            fontSize: 10,
          ),
        ),
      ],
    );
  }
}

class _AddFootRow extends StatelessWidget {
  const _AddFootRow({
    required this.onTap,
    required this.dense,
    required this.drawTopBorder,
  });

  final VoidCallback onTap;
  final bool dense;

  /// True on populated meals (the divider sits between the last entry and
  /// the footer). On empty meals there's no preceding entry — skip the
  /// border for visual cleanliness, matching the web mock's
  /// `border-top:0` override on the empty Dinner card.
  final bool drawTopBorder;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: onTap,
      // T-018 / §7 — the "Add food" footer is interactive; tint to
      // `line2` on hover so the affordance reads alongside `_EntryRow`.
      hoverColor: colors.line2,
      child: Container(
        decoration: BoxDecoration(
          border: drawTopBorder
              ? Border(top: BorderSide(color: colors.line2))
              : null,
        ),
        padding: EdgeInsets.symmetric(
          horizontal: context.space.x4,
          vertical: dense ? context.space.x2 + 1 : context.space.x3 - 1,
        ),
        child: Row(
          children: <Widget>[
            Icon(Icons.add, size: 14, color: colors.accent),
            SizedBox(width: context.space.x1 + 2),
            Text(
              'Add food',
              style: context.text.meta.copyWith(
                color: colors.accent,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
