import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../domain/food.dart';
import '../../../domain/units/energy.dart';
import '../../../routing/routes.dart';
import '../../../theme/context_extensions.dart';
import '../../../widgets/empty_state.dart';
import '../../../widgets/primary_button.dart';

/// The right-rail "Quick add" card on screen 01-W. Renders recents +
/// frequents as a wrap of chips; tapping a chip launches the log-entry
/// dialog with the food preselected.
///
/// **Why this lives in the today/ folder.** The chip row is shaped like
/// `QuickChipRow` from the component inventory, but the *card wrapper*
/// (with the "Quick add" eyebrow and section subheaders) only appears
/// here. When `QuickChipRow` lands in `lib/widgets/` for screen 02 it
/// will own only the row of chips; this card composes it. Until then the
/// chip itself lives here to keep the right rail self-contained.
class QuickAddChips extends StatelessWidget {
  const QuickAddChips({
    required this.recents,
    required this.frequents,
    required this.onTapFood,
    super.key,
  });

  final List<Food> recents;
  final List<Food> frequents;
  final void Function(Food food) onTapFood;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final recentChips = _take(recents, 4);
    final frequentChips = _take(frequents, 4);

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

    return Material(
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
    );
  }
}
