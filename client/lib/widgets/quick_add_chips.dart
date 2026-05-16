import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../domain/food.dart';
import '../domain/units/energy.dart';
import '../routing/routes.dart';
import '../theme/context_extensions.dart';
import '../widgets/empty_state.dart';
import '../widgets/primary_button.dart';

/// The right-rail "Quick add" card on screen 01-W. Renders recents +
/// frequents as a wrap of chips; tapping a chip launches the log-entry
/// dialog with the food preselected.
///
/// **Why this lives in `lib/widgets/`.** Lifted from
/// `lib/features/today/widgets/` per T-23 (UX-101) so the F2 compact
/// strip (UX-107) can mount the same widget without a feature-local
/// import. The chip row is shaped like `QuickChipRow` from the
/// component inventory; the *card wrapper* (with the "Quick add"
/// eyebrow and section subheaders) is composed here. The rename
/// `QuickAddChips → QuickChipRow` is deferred to a v1.1 spec-vs-code
/// reconciliation sweep (architect §2.2).
class QuickAddChips extends StatelessWidget {
  const QuickAddChips({
    required this.recents,
    required this.frequents,
    required this.onTapFood,
    this.compact = false,
    this.maxChips,
    super.key,
  });

  final List<Food> recents;
  final List<Food> frequents;
  final void Function(Food food) onTapFood;

  /// Render shape:
  ///   - `compact: false` (default; the existing right-rail card).
  ///     Card-shaped, eyebrow "Quick add", "Recent" + "Frequent"
  ///     sections, ≤ `maxChips ?? 4` chips per section, vertical
  ///     wrap, full empty-state with CTA.
  ///   - `compact: true` (the F2 today-compact strip — UX-107).
  ///     No card chrome, no eyebrow, no section headers, recents-only
  ///     (`frequents` ignored), ≤ `maxChips ?? 6` chips,
  ///     horizontal-scroll. Renders `SizedBox.shrink()` when recents
  ///     is empty — the empty state is the caller's responsibility
  ///     (the day view's existing `_EmptyDayPill` covers the
  ///     "no food yet" surface).
  final bool compact;

  /// Cap on how many chips render. Defaults to 4 in card mode (per
  /// section), 6 in compact mode (the strip). The wrapper widget on
  /// Today compact (`_TodayRecentChipsRow`) is the one that owns the
  /// "≥ 4 recents" gate — the widget itself short-circuits only when
  /// the post-`_take` list is empty.
  final int? maxChips;

  @override
  Widget build(BuildContext context) {
    if (compact) return _buildCompactStrip(context);
    return _buildCardWithSections(context);
  }

  Widget _buildCardWithSections(BuildContext context) {
    final colors = context.colors;
    final recentChips = _take(recents, maxChips ?? 4);
    final frequentChips = _take(frequents, maxChips ?? 4);

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(context.radius.r3),
      ),
      padding: EdgeInsets.all(context.space.x4 + 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            'Quick add',
            style: context.text.eyebrow.copyWith(color: colors.ink3),
          ),
          SizedBox(height: context.space.x3 + 2),
          if (recentChips.isNotEmpty) ...<Widget>[
            _SectionHeader(label: 'Recent'),
            SizedBox(height: context.space.x2),
            _ChipWrap(foods: recentChips, onTap: onTapFood),
          ],
          if (recentChips.isNotEmpty && frequentChips.isNotEmpty)
            SizedBox(height: context.space.x3 + 2),
          if (frequentChips.isNotEmpty) ...<Widget>[
            _SectionHeader(label: 'Frequent'),
            SizedBox(height: context.space.x2),
            _ChipWrap(foods: frequentChips, onTap: onTapFood),
          ],
          // T-013 (B9 absorbed): both providers empty → the lifted
          // `EmptyState` with a "Find a food" CTA routing to the search
          // screen. Partial-empty paths render only the populated
          // section above; the fallback Text used to read "Log a food
          // and it will show up here" and had no CTA.
          if (recentChips.isEmpty && frequentChips.isEmpty)
            EmptyState(
              icon: Icons.search,
              title: 'No recents yet',
              body: "Log your first food and it'll show up here.",
              action: SizedBox(
                width: 220,
                child: PrimaryButton(
                  label: 'Find a food',
                  onPressed: () => context.push(Routes.foodsSearchPath),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// UX-107 / architect §4.2 — the horizontal-scroll compact strip mode.
  ///
  /// Renders the first `maxChips ?? 6` recents as a horizontal-scrollable
  /// row of `_QuickAddChip`s — no card chrome, no eyebrow, no section
  /// headers, recents-only. Suitable for inline mount inside a sliver
  /// list between the ring summary card and the meal grid.
  ///
  /// Defensive short-circuit: returns `SizedBox.shrink()` when the
  /// post-`_take` list is empty. The wrapper widget on Today compact
  /// (`_TodayRecentChipsRow`) is the one that owns the higher
  /// "≥ 4 recents" PM floor; this widget keeps the empty short-circuit
  /// minimal so a future caller that wants the strip on fewer chips
  /// can pass `maxChips: 3` without the gate.
  Widget _buildCompactStrip(BuildContext context) {
    final shown = _take(recents, maxChips ?? 6);
    if (shown.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: context.space.x5),
        itemCount: shown.length,
        separatorBuilder: (_, __) => SizedBox(width: context.space.x2),
        itemBuilder: (_, i) => Center(
          child: _QuickAddChip(
            food: shown[i],
            onTap: () => onTapFood(shown[i]),
          ),
        ),
      ),
    );
  }

  List<Food> _take(List<Food> source, int max) =>
      source.length <= max ? source : source.sublist(0, max);
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: context.text.meta.copyWith(
        color: context.colors.ink2,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.04 * 12,
        fontSize: 12,
      ),
    );
  }
}

class _ChipWrap extends StatelessWidget {
  const _ChipWrap({required this.foods, required this.onTap});
  final List<Food> foods;
  final void Function(Food food) onTap;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: context.space.x1 + 2,
      runSpacing: context.space.x1 + 2,
      children: <Widget>[
        for (final f in foods) _QuickAddChip(food: f, onTap: () => onTap(f)),
      ],
    );
  }
}

class _QuickAddChip extends StatelessWidget {
  const _QuickAddChip({required this.food, required this.onTap});
  final Food food;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final kcal = food.caloriesPerDefaultServing;
    final kcalLabel = kcal == null ? null : formatKcal(kcal);

    // T-20: composed chip label — `name, N kilocalories`. The visible
    // text reads "Greek yogurt · 130", but a screen reader gets the
    // unit-aware phrase. Leaves are excluded below so the announcement
    // is one phrase per chip.
    final semantic = StringBuffer(food.name);
    if (kcalLabel != null) {
      semantic..write(', ')..write(kcalLabel)..write(' kilocalories');
    }

    return Semantics(
      container: true,
      button: true,
      label: semantic.toString(),
      excludeSemantics: true,
      child: Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(context.radius.rPill),
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: context.space.x2 + 2,
            vertical: context.space.x1 + 2,
          ),
          decoration: BoxDecoration(
            color: colors.bg,
            border: Border.all(color: colors.line),
            borderRadius: BorderRadius.circular(context.radius.rPill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Text(
                  food.name,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: context.text.meta.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w500,
                    fontSize: 12,
                  ),
                ),
              ),
              if (kcalLabel != null) ...<Widget>[
                SizedBox(width: context.space.x1 + 2),
                Text(
                  '· $kcalLabel',
                  style: context.text.metaNumeric.copyWith(
                    color: colors.ink2,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      ),
    );
  }
}
