import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:fulfilled/widgets/empty_state.dart';
import 'package:fulfilled/widgets/primary_button.dart';
import 'package:fulfilled/widgets/serving_list.dart';
import 'package:fulfilled/widgets/skeleton.dart';

import '../../domain/enums.dart';
import '../../domain/food.dart';
import '../../features/log_entry/log_entry_sheet.dart';
import '../../form_factor/form_factor.dart';
import '../../providers/food_providers.dart';
import '../../repositories/food_repository.dart';
import '../../theme/context_extensions.dart';
import 'widgets/food_detail_hero.dart';
import 'widgets/food_summary_card.dart';
import 'widgets/nutrition_table.dart';

/// Local debug flag — flip to `true` to inspect the loading or error
/// branches against the mock provider, then revert before committing.
/// Compile-time const so the dead branch is tree-shaken in release.
/// T-013 — pattern shared across the screens this ticket touches.
const bool _kDebugForceError = false;

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

    // T-11 — transient transport errors get a SnackBar in addition to the
    // inline empty-state, so the user sees the failure even if they were
    // looking away from the body. The error-state EmptyState is the
    // persistent half; the snackbar is the attention half.
    ref.listen<AsyncValue<Food>>(foodDetailProvider(foodId), (prev, next) {
      if (next.hasError && (prev == null || !prev.hasError)) {
        if (next.error is FoodNotFoundError) return;
        final messenger = ScaffoldMessenger.maybeOf(context);
        messenger?.showSnackBar(
          SnackBar(
            content: Text("Couldn't load food: ${next.error}"),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    });

    if (_kDebugForceError) {
      return _DetailError(
        error: Exception('forced'),
        foodId: foodId,
        onRetry: () => ref.invalidate(foodDetailProvider(foodId)),
      );
    }

    return async.when(
      loading: () => const _DetailLoading(),
      error: (e, _) => _DetailError(
        error: e,
        foodId: foodId,
        onRetry: () => ref.invalidate(foodDetailProvider(foodId)),
      ),
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
    final isEditable = food.source == FoodSource.user;

    return Scaffold(
      backgroundColor: context.colors.bg,
      appBar: _DetailAppBar(
        showAddToLog: !isCompact,
        onAddToLog: () => openLogEntry(context, food: food),
        // The Edit affordance only paints for `source == user` foods —
        // the OFF / USDA rows are read-only (their data is upstream and
        // shared across users). The button pushes
        // `/foods/$id/edit` which lands on `CustomFoodScreen` in edit
        // mode via the resolver in `app_router.dart`.
        onEdit: isEditable ? () => context.push('/foods/${food.id}/edit') : null,
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
    this.onEdit,
  });

  final bool showAddToLog;
  final VoidCallback onAddToLog;

  /// Non-null only for `source == user` foods. When set, the app bar
  /// renders an "Edit" text button between the Save and Add-to-log
  /// affordances. Tapping it navigates to the edit route.
  final VoidCallback? onEdit;

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
        // QL-106 — the `Icons.bookmark_border` "Save" icon used to live
        // here as a no-op until favorites ship. PM audit QL-006 ruled it
        // a trust eroder; the icon is deleted for v1. Restore when the
        // favorites feature lands (architect §7.2 — tracking note here
        // so the restoration is cleanly slotted).
        if (onEdit != null)
          Padding(
            padding: EdgeInsets.only(left: context.space.x1),
            child: TextButton(
              onPressed: onEdit,
              style: TextButton.styleFrom(
                foregroundColor: context.colors.accent,
                textStyle: context.text.bodyStrong,
                padding: EdgeInsets.symmetric(
                  horizontal: context.space.x3,
                  vertical: context.space.x2,
                ),
              ),
              child: const Text('Edit'),
            ),
          ),
        // UX-111 (Theme C dead-affordance sweep) — the trailing
        // `more_horiz` overflow `IconButton` used to render here with a
        // no-op `onPressed: () {}` when the Add-to-log CTA was hidden
        // (expanded form factor sticky bottom CTA). Architect §8 / PM
        // doc §2 Theme C: delete in v1, restore when wired to a real
        // menu (e.g., "Share food", "Edit serving"). Tracked as a v1.1
        // ticket.
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

/// Loading state — T-08: shape mirrors the eventual hero + summary +
/// servings + nutrition rhythm so the layout doesn't jump when data
/// lands. The skeleton blocks pick up the `line2` tint via the lifted
/// [Skeleton] primitive; no centered spinner.
class _DetailLoading extends StatelessWidget {
  const _DetailLoading();

  @override
  Widget build(BuildContext context) {
    final space = context.space;
    final radius = context.radius;
    return Scaffold(
      backgroundColor: context.colors.bg,
      appBar: _DetailAppBar(showAddToLog: false, onAddToLog: () {}),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(space.x5, space.x4, space.x5, space.x6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // Hero — eyebrow + title lines.
              const Skeleton(height: 10, width: 120),
              SizedBox(height: space.x2),
              const Skeleton(height: 22),
              SizedBox(height: space.x1),
              const Skeleton(height: 22, width: 220),
              SizedBox(height: space.x5),
              // Summary card silhouette.
              Skeleton(
                height: 120,
                borderRadius: BorderRadius.circular(radius.r3),
              ),
              SizedBox(height: space.x5),
              // Servings eyebrow + three rows.
              const Skeleton(height: 10, width: 80),
              SizedBox(height: space.x3),
              for (var i = 0; i < 3; i++) ...<Widget>[
                const SkeletonRow(),
                if (i < 2) SizedBox(height: space.x1),
              ],
              SizedBox(height: space.x5),
              // Nutrition eyebrow + table block.
              const Skeleton(height: 10, width: 96),
              SizedBox(height: space.x3),
              Skeleton(
                height: 220,
                borderRadius: BorderRadius.circular(radius.r3),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Error state — renders the lifted [EmptyState] with a retry CTA. For
/// the not-found path the retry is replaced with a "Go back" affordance
/// (re-invalidating won't unstuck a 404).
class _DetailError extends StatelessWidget {
  const _DetailError({
    required this.error,
    required this.foodId,
    required this.onRetry,
  });

  final Object error;
  final String foodId;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final isNotFound = error is FoodNotFoundError;
    final title = isNotFound ? 'Food not found' : "Couldn't load food details";
    final body = isNotFound
        ? "We don't have a record for $foodId."
        : 'Pull to refresh or tap retry.';

    return Scaffold(
      backgroundColor: context.colors.bg,
      appBar: _DetailAppBar(showAddToLog: false, onAddToLog: () {}),
      body: SafeArea(
        top: false,
        child: Center(
          child: EmptyState(
            icon: isNotFound ? Icons.no_food_outlined : Icons.cloud_off,
            title: title,
            body: body,
            action: SizedBox(
              width: 200,
              child: isNotFound
                  ? PrimaryButton(
                      label: 'Go back',
                      onPressed: () => _DetailAppBar._popOrFallback(context),
                    )
                  : PrimaryButton(
                      label: 'Retry',
                      onPressed: onRetry,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
