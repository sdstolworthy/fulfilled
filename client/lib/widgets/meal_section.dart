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
import 'icon_button_36.dart';
import 'motion.dart';

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
    this.isPendingSync,
    this.onCopyMeal,
    this.canCopyMeal,
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

  /// Optional predicate the day view threads through to each `_EntryRow`
  /// so the row can render the "Pending sync" badge and pulse it on a
  /// rejected tap (QL-108 / T-22). Returns `true` when the entry's POST
  /// hasn't ack'd yet (consults `LogRepository.isPendingSync` upstream).
  /// Null = "no entries are pending" (used by tests + the expanded form
  /// factor's no-outbox path).
  final bool Function(LogEntry entry)? isPendingSync;

  /// `true` slims the vertical padding for the expanded 2×2 grid.
  final bool dense;

  /// UX-106 F1 — per-meal copy-day entry surface. When non-null, the
  /// `_Header` renders a 36-px `IconButton36` (`Icons.more_horiz_outlined`)
  /// to the right of the kcal subtotal whose `showMenu` exposes a single
  /// "Copy <Meal> from…" item. Selecting that item invokes
  /// `onCopyMeal(meal)` — the day view threads `(m) => showCopyDaySheet(
  /// context, targetDate: date, preselectMeals: [m])`. Null = the overflow
  /// icon is not rendered (back-compat for test fixtures that don't opt
  /// in). Architect §3.4 (A).
  final void Function(Meal meal)? onCopyMeal;

  /// Optional predicate that gates the overflow icon's enabled state
  /// (greyed when false). Null = always enabled. UX-106 ships without
  /// the predicate wired from the day views (architect §3.4 (A) deferred);
  /// the parameter is part of the public API so future tickets can
  /// flip a 14-day-window-by-meal predicate in without a constructor
  /// change.
  final bool Function(Meal meal)? canCopyMeal;

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
          _Header(
            meal: subtotal.meal,
            kcal: subtotal.kcal,
            isEmpty: isEmpty,
            onCopyMeal: onCopyMeal,
            canCopyMeal: canCopyMeal,
          ),
          for (final entry in entries)
            _EntryRow(
              entry: entry,
              onTap: onEntryTap == null ? null : () => onEntryTap!(entry),
              dense: dense,
              isPendingSync: isPendingSync?.call(entry) ?? false,
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
    this.onCopyMeal,
    this.canCopyMeal,
  });

  final Meal meal;
  final Decimal kcal;
  final bool isEmpty;

  /// UX-106 — when non-null the header renders the trailing overflow
  /// icon. The icon's `showMenu` is rooted on its render box; selecting
  /// "Copy <Meal> from…" calls this back.
  final void Function(Meal meal)? onCopyMeal;

  /// Optional predicate gating the overflow icon's enabled state.
  /// Null = enabled.
  final bool Function(Meal meal)? canCopyMeal;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final dotColor = isEmpty ? colors.emptyDot : colors.accent;
    final kcalText = formatKcal(kcal);
    final canCopy = canCopyMeal?.call(meal) ?? true;

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
          if (onCopyMeal != null) ...<Widget>[
            SizedBox(width: context.space.x2),
            _CopyMealOverflow(
              meal: meal,
              canCopy: canCopy,
              onCopyMeal: onCopyMeal!,
            ),
          ],
        ],
      ),
    );
  }
}

/// UX-106 F1 — the trailing 36-px overflow icon on a `_Header` whose
/// `showMenu` opens a single-item popup: "Copy <Meal> from…". Tapping
/// the menu item invokes [onCopyMeal] with the section's [meal] — the
/// day view threads that to `showCopyDaySheet(context, targetDate: date,
/// preselectMeals: [meal])` (architect §3.4 (A)). The icon greys when
/// [canCopy] is false, but the tap still fires (the predicate is a hint
/// — the sheet's empty-source state is the fallback UX, per architect
/// §3.4 (A) deferral notes). T-06 honoured via `IconButton36`'s 44-px
/// hit slop; T-20 honoured via the per-meal tooltip.
class _CopyMealOverflow extends StatelessWidget {
  const _CopyMealOverflow({
    required this.meal,
    required this.canCopy,
    required this.onCopyMeal,
  });

  final Meal meal;
  final bool canCopy;
  final void Function(Meal meal) onCopyMeal;

  Future<void> _open(BuildContext context) async {
    final overlay =
        Overlay.of(context, rootOverlay: true).context.findRenderObject()
            as RenderBox?;
    final button = context.findRenderObject() as RenderBox?;
    if (overlay == null || button == null) {
      // Fallback: fire the copy callback directly so the affordance is
      // still actionable when the test harness doesn't render an
      // Overlay (defensive — production always has one).
      onCopyMeal(meal);
      return;
    }
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset.zero, ancestor: overlay),
        button.localToGlobal(button.size.bottomRight(Offset.zero),
            ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );
    final colors = context.colors;
    final selected = await showMenu<_CopyMealAction>(
      context: context,
      position: position,
      items: <PopupMenuEntry<_CopyMealAction>>[
        PopupMenuItem<_CopyMealAction>(
          key: Key('copy-meal-menu-item-${meal.wire}'),
          value: _CopyMealAction.copyFrom,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.content_copy_outlined,
                size: 16,
                color: colors.ink2,
              ),
              const SizedBox(width: 12),
              Text('Copy ${meal.label} from…'),
            ],
          ),
        ),
      ],
    );
    if (selected == _CopyMealAction.copyFrom) {
      onCopyMeal(meal);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return IconButton36(
      key: Key('copy-meal-overflow-${meal.wire}'),
      icon: Icons.more_horiz_outlined,
      tooltip: 'Copy ${meal.label} from…',
      onPressed: () => _open(context),
      color: canCopy ? colors.ink2 : colors.ink2.withValues(alpha: 0.5),
    );
  }
}

/// One-action enum for the per-meal copy overflow's `showMenu`. A single
/// member today; defining a typed enum keeps `showMenu<T>` typed and
/// makes a v1.1 "Copy from yesterday" / "Pick a different day" split
/// purely additive.
enum _CopyMealAction { copyFrom }

/// A single logged-entry row inside a `MealSection`.
///
/// Stateful because of QL-108's "pulse the pending badge on a rejected
/// tap": tapping the row when `isPendingSync == true` schedules a
/// 200 ms `AnimatedScale` from 1.0 → 1.08 → 1.0 on the badge so the
/// user sees what's blocking their edit (the row's existing SnackBar
/// from `editLogEntry` still fires). The `motion()` helper collapses
/// the duration to zero when `MediaQuery.disableAnimations` is on so
/// reduce-motion users get the badge without the pulse.
class _EntryRow extends StatefulWidget {
  const _EntryRow({
    required this.entry,
    required this.onTap,
    required this.dense,
    required this.isPendingSync,
  });

  final LogEntry entry;
  final VoidCallback? onTap;
  final bool dense;

  /// When `true`, render the "Pending sync" badge and pulse it on tap.
  /// Threaded through `MealSection` from the day view's
  /// `LogRepository.isPendingSync(entry.id)` lookup.
  final bool isPendingSync;

  @override
  State<_EntryRow> createState() => _EntryRowState();
}

class _EntryRowState extends State<_EntryRow> {
  /// Drives the "Pending sync" badge's `AnimatedScale`. Toggles
  /// `false → true` on a pending-row tap, then back to `false` after
  /// 200 ms (or the reduce-motion-collapsed equivalent). The
  /// `AnimatedScale` interpolates between `1.0` (rest) and `_pulseScale`
  /// during the 200 ms window, so the user sees a single soft pulse.
  bool _pulsing = false;

  /// Peak scale of the rejected-tap pulse. 1.08 reads as a deliberate
  /// nudge without overshoot — the same magnitude as the architect's
  /// "soft visual cue" callout.
  static const double _pulseScale = 1.08;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final entry = widget.entry;

    // LU-005 / T-20: announce the row as a tappable "edit" target so
    // screen readers don't read the food name + serving + kcal as three
    // independent strings. `ExcludeSemantics` collapses the inner Text
    // nodes — the merged label below is the single announcement.
    final servingPart = entry.servingName ?? '';
    final pendingSuffix =
        widget.isPendingSync ? ', still syncing, edit unavailable' : '';
    final semanticsLabel =
        '${entry.foodName}, $servingPart, ${formatKcal(entry.kcal)} '
        'kilocalories, edit$pendingSuffix';

    // UX-112 a11y — declare the row's Semantics as a `liveRegion` when
    // the entry is pending sync so the screen reader announces the
    // state change on flush. The badge widget itself also carries a
    // `LiveRegion` declaration so it satisfies the inline a11y contract
    // even if the row's ExcludeSemantics evolves; in the current tree
    // shape the row's Semantics is the surface that actually reaches
    // the screen reader.
    return Semantics(
      button: true,
      label: semanticsLabel,
      liveRegion: widget.isPendingSync,
      child: ExcludeSemantics(
        child: InkWell(
          onTap: widget.onTap == null
              ? null
              : () {
                  // QL-108: when the row is pending sync, schedule the
                  // badge pulse alongside the existing handler call.
                  // The handler short-circuits at the pending-sync gate
                  // and fires the "Still syncing" SnackBar — the pulse
                  // is the second half of the belt-and-braces feedback.
                  if (widget.isPendingSync) {
                    _triggerPulse();
                  }
                  widget.onTap!();
                },
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
              vertical: widget.dense
                  ? context.space.x2 + 1
                  : context.space.x2 + 2,
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
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              _metaLine(entry),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.text.meta,
                            ),
                          ),
                          if (widget.isPendingSync) ...<Widget>[
                            SizedBox(width: context.space.x2),
                            _PendingSyncBadge(
                              pulsing: _pulsing,
                              pulseScale: _pulseScale,
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                SizedBox(width: context.space.x3),
                _KcalCell(entry: entry, dense: widget.dense),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Schedule a one-shot 200 ms pulse. The state mutation drives the
  /// outer `AnimatedScale`'s `scale` prop from 1.0 → 1.08 in the first
  /// 100 ms (the `AnimatedScale.duration` below), and the matching
  /// `Future.delayed` flips back to 1.0 for the trailing 100 ms — net
  /// effect: a 1.0 → 1.08 → 1.0 there-and-back pulse that resolves to
  /// rest in 200 ms (or 0 ms with reduce-motion).
  ///
  /// Guarded against re-entry: if the user taps a pending row twice
  /// quickly, the second tap is a no-op while a pulse is in flight.
  /// Tests can therefore assert "first tap sets `_pulsing = true`,
  /// 200 ms later it's `false`" without flake from rapid double-taps.
  void _triggerPulse() {
    if (_pulsing) return;
    setState(() => _pulsing = true);
    final halfPulse = motion(context, const Duration(milliseconds: 100));
    Future.delayed(halfPulse, () {
      if (!mounted) return;
      setState(() => _pulsing = false);
    });
  }

  String _metaLine(LogEntry entry) {
    // Quick-add entries carry the synthetic `food_quick_add` food id and
    // a `kcal` serving. The serving label is a unit-of-measure, not a
    // food descriptor — printing "kcal · 105 kcal" reads as a typo, so
    // suppress the meta line entirely for these rows. The `_KcalCell`
    // already renders the numeric value; the row therefore reads as
    // "Quick add ... 105 kcal" — title + trailing kcal — which is the
    // designed shape for a raw-calorie entry.
    if (entry.foodId == _quickAddFoodId) return '';
    final parts = <String>[];
    final serving = entry.servingName;
    if (serving != null && serving.isNotEmpty) parts.add(serving);
    // The wire doesn't give us brand on a log entry — the food name is
    // already denormalized. Keep the meta line to the serving label so we
    // never invent a brand string. The expanded mock matches the compact.
    return parts.join(' · ');
  }
}

/// Mirror of `quickAddFoodId` from `repositories/_fixtures.dart`. Kept
/// inline here so the widget layer doesn't import the mock-data file
/// (which is documented as deletable once the real API lands). When the
/// API ships, the synthetic food's id is stable across mock and live.
const String _quickAddFoodId = 'food_quick_add';

/// "Pending sync" badge next to the meta line. Rendered only when the
/// entry's POST hasn't ack'd. The outer `AnimatedScale` is what QL-108
/// pulses on a rejected tap: the parent flips `pulsing` `false → true →
/// false` over a 200 ms window (100 ms up, 100 ms down), and the
/// `AnimatedScale.duration` of 100 ms interpolates each leg. Net effect:
/// a 1.0 → 1.08 → 1.0 there-and-back pulse. The `motion()` helper
/// collapses the duration to zero when `MediaQuery.disableAnimations`
/// is on so reduce-motion users still get the badge and the SnackBar,
/// just without the scale tween.
///
/// Tenants honored: T-20 (the badge participates in semantics through a
/// LiveRegion announcement; the parent row's Semantics label carries
/// the "still syncing" suffix as the persistent announcement, and the
/// LiveRegion here surfaces the transient state change to the screen
/// reader on mount/unmount — UX-112 a11y accept).
///
/// **A11y (UX-112, PM UX pack §6 — LiveRegion on pending-sync badge).**
/// Wrapping in `Semantics(liveRegion: true, ...)` means the screen
/// reader is notified when this widget mounts (entry is queued for
/// sync) and again when its label changes — closing the T-22 loop for
/// the assistive-tech user. The inner content is kept semantically
/// quiet via `ExcludeSemantics` so the badge's text glyph doesn't
/// double-announce alongside the LiveRegion label.
class _PendingSyncBadge extends StatelessWidget {
  const _PendingSyncBadge({
    required this.pulsing,
    required this.pulseScale,
  });

  final bool pulsing;
  final double pulseScale;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Semantics(
      liveRegion: true,
      label: 'Pending sync',
      child: ExcludeSemantics(
        child: AnimatedScale(
          scale: pulsing ? pulseScale : 1.0,
          duration: motion(context, const Duration(milliseconds: 100)),
          curve: Curves.easeOut,
          child: Container(
            key: const Key('pending-sync-badge'),
            padding: EdgeInsets.symmetric(
              horizontal: context.space.x2,
              vertical: context.space.x05,
            ),
            decoration: BoxDecoration(
              color: colors.line2,
              borderRadius: BorderRadius.circular(context.radius.rPill),
            ),
            child: Text(
              'Pending sync',
              style: context.text.meta.copyWith(
                color: colors.ink2,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
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
