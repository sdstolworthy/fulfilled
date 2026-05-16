import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:fulfilled/widgets/serving_list.dart';

import '../../domain/food.dart';
import '../../features/log_entry/log_entry_sheet.dart';
import '../../form_factor/form_factor.dart';
import '../../providers/food_providers.dart';
import '../../repositories/food_repository.dart';
import '../../theme/context_extensions.dart';
import 'widgets/food_detail_hero.dart';
import 'widgets/food_summary_card.dart';
import 'widgets/nutrition_table.dart';

/// Signature for the log-entry sheet entry point. Matches
/// `package:fulfilled/features/log_entry/log_entry_sheet.dart`'s
/// `showLogEntrySheet`. Declared here for type clarity; the production
/// default is the imported function. Tests inject a fake.
typedef ShowLogEntrySheet = void Function(
  BuildContext context, {
  required Food food,
});

/// Screen 03 — Food detail. URL-addressable route (`/foods/:foodId`),
/// rendered **outside** the app shell — no nav chrome, so we own the
/// `Scaffold` and top bar ourselves (architecture §4, §9.3).
///
/// **Tenants enforced here**
/// - **T-10**: synthetic 100 g serving is always visible with a
///   `Synthetic` badge (`ServingList` does it; we always pass the
///   complete `food.servings`).
/// - **T-11**: errors render inline. `FoodNotFoundError` shows a "Food not
///   found · Go back" empty state, not a crash.
/// - **T-14**: this is a route, not a sheet → sticky bottom CTA on
///   compact; on expanded we drop the sticky CTA and surface "Add to log"
///   in the top bar (architecture §9.3 web transform).
/// - **T-21**: every numeric leaf flows through `lib/domain/units/`. No
///   inline conversions live in this file.
class FoodDetailScreen extends ConsumerWidget {
  const FoodDetailScreen({
    required this.foodId,
    this.showLogEntrySheetOverride,
    super.key,
  });

  final String foodId;

  /// Test-only seam — production code leaves this null and uses the
  /// real `showLogEntrySheet` imported above. Letting tests inject a
  /// fake keeps the screen self-contained while we wait on the parallel
  /// agent's sheet to land.
  final ShowLogEntrySheet? showLogEntrySheetOverride;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(foodDetailProvider(foodId));
    final open = showLogEntrySheetOverride ?? showLogEntrySheet;

    return async.when(
      loading: () => const _DetailLoading(),
      error: (e, _) => _DetailError(error: e, foodId: foodId),
      data: (food) => _DetailLoaded(food: food, openLogEntry: open),
    );
  }
}

class _DetailLoaded extends StatelessWidget {
  const _DetailLoaded({required this.food, required this.openLogEntry});

  final Food food;
  final ShowLogEntrySheet openLogEntry;

  @override
  Widget build(BuildContext context) {
    final isCompact = FormFactor.of(context).isCompact;

    return Scaffold(
      backgroundColor: context.colors.bg,
      appBar: _DetailAppBar(
        showAddToLog: !isCompact,
        onAddToLog: () => openLogEntry(context, food: food),
      ),
      body: SafeArea(
        top: false,
        child: Stack(
          children: <Widget>[
            _DetailBody(food: food, bottomPadding: isCompact ? 130 : 24),
            if (isCompact)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _BottomCta(
                  onPressed: () => openLogEntry(context, food: food),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DetailBody extends StatelessWidget {
  const _DetailBody({required this.food, required this.bottomPadding});

  final Food food;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.only(bottom: bottomPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FoodDetailHero(food: food),
          FoodSummaryCard(food: food),
          _Section(
            title: 'Servings',
            child: ServingList(
              servings: food.servings,
              nutritionPer100g: food.nutritionPer100g,
            ),
          ),
          _Section(
            title: 'Nutrition',
            child: NutritionTable(
              nutrition: food.nutritionPer100g,
              source: food.source,
              qualityScore: food.qualityScore,
            ),
          ),
          SizedBox(height: context.space.x6),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.space.x5,
        context.space.x5,
        context.space.x5,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.only(bottom: context.space.x2 + 2),
            child: Text(
              title.toUpperCase(),
              style: context.text.eyebrow.copyWith(
                color: context.colors.ink3,
                fontSize: 11,
                letterSpacing: 0.10 * 11,
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _DetailAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _DetailAppBar({
    required this.showAddToLog,
    required this.onAddToLog,
  });

  final bool showAddToLog;
  final VoidCallback onAddToLog;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      backgroundColor: context.colors.bg,
      elevation: 0,
      scrolledUnderElevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.chevron_left),
        tooltip: 'Back',
        onPressed: () => _popOrFallback(context),
      ),
      actions: <Widget>[
        IconButton(
          icon: const Icon(Icons.bookmark_border),
          tooltip: 'Save',
          onPressed: () {
            // Save-to-favorites lives on a parallel agent's surface; this
            // screen owns the entry point only. No-op until that lands.
          },
        ),
        if (showAddToLog)
          Padding(
            padding: EdgeInsets.only(
              right: context.space.x3,
              left: context.space.x1,
            ),
            child: TextButton.icon(
              onPressed: onAddToLog,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add to log'),
              style: TextButton.styleFrom(
                foregroundColor: context.colors.accent,
                textStyle: context.text.bodyStrong,
                padding: EdgeInsets.symmetric(
                  horizontal: context.space.x3,
                  vertical: context.space.x2,
                ),
              ),
            ),
          )
        else
          IconButton(
            icon: const Icon(Icons.more_horiz),
            tooltip: 'More',
            onPressed: () {},
          ),
      ],
    );
  }

  static void _popOrFallback(BuildContext context) {
    final router = GoRouter.of(context);
    if (router.canPop()) {
      router.pop();
    } else {
      router.go('/foods');
    }
  }
}

/// Sticky bottom CTA for compact. The mock paints a soft top-fade behind
/// the button so the body content peeks through; we replicate that with
/// a vertical gradient.
class _BottomCta extends StatelessWidget {
  const _BottomCta({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final bg = context.colors.bg;
    return Container(
      padding: EdgeInsets.fromLTRB(
        context.space.x5,
        context.space.x3 + 2,
        context.space.x5,
        context.space.x6 + 4,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[bg.withValues(alpha: 0), bg],
          stops: const <double>[0.0, 0.6],
        ),
      ),
      child: SizedBox(
        height: 54,
        child: FilledButton.icon(
          onPressed: onPressed,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add to log'),
          style: FilledButton.styleFrom(
            backgroundColor: context.colors.accent,
            foregroundColor: context.colors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(context.radius.r3),
            ),
            textStyle: context.text.bodyStrong.copyWith(
              fontSize: 16,
              color: context.colors.surface,
            ),
          ),
        ),
      ),
    );
  }
}

class _DetailLoading extends StatelessWidget {
  const _DetailLoading();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.bg,
      appBar: _DetailAppBar(showAddToLog: false, onAddToLog: () {}),
      body: Center(
        child: CircularProgressIndicator(color: context.colors.accent),
      ),
    );
  }
}

class _DetailError extends StatelessWidget {
  const _DetailError({required this.error, required this.foodId});

  final Object error;
  final String foodId;

  @override
  Widget build(BuildContext context) {
    final isNotFound = error is FoodNotFoundError;
    final title = isNotFound ? 'Food not found' : 'Couldn’t load this food';
    final detail = isNotFound
        ? 'We don’t have a record for $foodId.'
        : 'Check your connection and try again.';

    return Scaffold(
      backgroundColor: context.colors.bg,
      appBar: _DetailAppBar(showAddToLog: false, onAddToLog: () {}),
      body: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.space.x6),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Icon(
                  Icons.no_food_outlined,
                  size: 36,
                  color: context.colors.ink3,
                ),
                SizedBox(height: context.space.x3),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: context.text.title,
                ),
                SizedBox(height: context.space.x1),
                Text(
                  detail,
                  textAlign: TextAlign.center,
                  style: context.text.meta,
                ),
                SizedBox(height: context.space.x4),
                Center(
                  child: TextButton(
                    onPressed: () => _DetailAppBar._popOrFallback(context),
                    style: TextButton.styleFrom(
                      foregroundColor: context.colors.accent,
                      textStyle: context.text.bodyStrong,
                    ),
                    child: const Text('Go back'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
