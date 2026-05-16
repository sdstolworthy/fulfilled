import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/enums.dart';
import '../../domain/food.dart';
import '../../providers/food_providers.dart';
import '../../routing/routes.dart';
import '../../theme/context_extensions.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/icon_button_36.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/skeleton.dart';
import '../search/widgets/search_result_row.dart';

/// Screen — My foods at `/foods/mine` (T-006 / PM A2).
///
/// The one architecturally-named screen that was never built. Lists every
/// `source == user` food in the catalog as a `SearchResultRow`. The
/// in-list filter is plain local state — no provider, no debounce, per
/// keystroke `String.contains`.
///
/// **Composition** (compact + medium + expanded share the same body —
/// chrome differences are handled by the parent shell):
///
/// 1. Top bar with title "My foods" and a "+" affordance routing to
///    `Routes.foodNewPath`. On compact this top bar is rendered by this
///    screen so the "+" sits next to the title; on expanded the same bar
///    renders inline (the sidebar shell already covers the back affordance).
/// 2. A pinned `TextField` filter that narrows the list case-insensitively.
/// 3. The body is one of three states:
///    - **loading** — four [SkeletonRow]s of [kSkeletonRowHeight] (T-08).
///    - **populated** — `ListView.builder` of [SearchResultRow]s, with
///      thin row dividers. Tap → `context.push('/foods/${food.id}')`.
///    - **empty (no custom foods)** — [EmptyState] with a "Create custom
///      food" CTA routing to `Routes.foodNewPath`.
///    - **empty (after filter)** — [EmptyState] titled "No customs match
///      '$query'", no action.
///    - **error** — [EmptyState] titled "Couldn't load custom foods" with
///      a retry CTA that re-invalidates [myFoodsProvider].
///
/// **Tenants honored**: T-08 (skeleton matches final row height), T-13
/// (no spinner over a populated list — loading is skeleton, error is the
/// empty-state composition + SnackBar), T-15 (form-factor branch at root
/// — though compact/expanded share the body, the chrome differs), T-23
/// (uses the lifted primitives `EmptyState`, `SkeletonRow`,
/// `PrimaryButton`, `IconButton36`).
///
/// **Empty-state debug flag**. Flip [_kEmptyStateDebugFlag] to `true`
/// locally to force the populated → empty path without temporarily
/// editing the fixture. Architect ruling — do **not** wire a runtime
/// toggle (the flag is a `const` so the dead branch is tree-shaken in
/// release builds).
const bool _kEmptyStateDebugFlag = false;

class MyFoodsScreen extends ConsumerStatefulWidget {
  const MyFoodsScreen({super.key});

  @override
  ConsumerState<MyFoodsScreen> createState() => _MyFoodsScreenState();
}

class _MyFoodsScreenState extends ConsumerState<MyFoodsScreen> {
  // Filter state is local — per-keystroke `String.contains` doesn't need
  // a provider seam (T-15: the screen owns trivial leaf state, providers
  // own cross-screen data). No debounce — the list is fully local.
  final TextEditingController _filterController = TextEditingController();
  String _filter = '';

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  void _onFilterChanged(String value) {
    if (value == _filter) return;
    setState(() => _filter = value);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(myFoodsProvider);
    return ColoredBox(
      color: context.colors.bg,
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _TopBar(
              onAdd: () => context.push(Routes.foodNewPath),
            ),
            _FilterField(
              controller: _filterController,
              onChanged: _onFilterChanged,
            ),
            Expanded(
              child: async.when(
                loading: () => const _LoadingBody(),
                error: (err, _) => _ErrorBody(
                  onRetry: () => ref.invalidate(myFoodsProvider),
                ),
                data: (foods) {
                  final visible = _kEmptyStateDebugFlag
                      ? const <Food>[]
                      : _applyFilter(foods, _filter);
                  if (foods.isEmpty || _kEmptyStateDebugFlag) {
                    return _NoCustomsEmpty(
                      onCreate: () => context.push(Routes.foodNewPath),
                    );
                  }
                  if (visible.isEmpty) {
                    return _NoMatchesEmpty(query: _filter.trim());
                  }
                  return _PopulatedList(foods: visible, query: _filter);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Filter helpers — kept top-level so the unit test can exercise the same
// function the screen uses.
// ---------------------------------------------------------------------------

/// Case-insensitive substring match on `name`. Empty / whitespace-only
/// queries pass everything through.
@visibleForTesting
List<Food> applyMyFoodsFilter(List<Food> foods, String query) =>
    _applyFilter(foods, query);

List<Food> _applyFilter(List<Food> foods, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return foods;
  return foods.where((f) => f.name.toLowerCase().contains(q)).toList();
}

// ---------------------------------------------------------------------------
// Top bar — title + "+" affordance.
// ---------------------------------------------------------------------------

class _TopBar extends StatelessWidget {
  const _TopBar({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final space = context.space;
    return Padding(
      padding: EdgeInsets.fromLTRB(space.x5, space.x3, space.x3, space.x2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Text(
              'My foods',
              style: context.text.pageTitle,
            ),
          ),
          IconButton36(
            icon: Icons.add,
            tooltip: 'Create custom food',
            onPressed: onAdd,
            color: context.colors.accent,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Filter field — plain `TextField`, no debounce. The visible chrome
// matches the search bar so the screen reads as part of the same family.
// ---------------------------------------------------------------------------

class _FilterField extends StatelessWidget {
  const _FilterField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final space = context.space;
    return Padding(
      padding: EdgeInsets.fromLTRB(space.x5, 0, space.x5, space.x3),
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border.all(color: colors.line),
          borderRadius: BorderRadius.circular(context.radius.r3),
        ),
        padding: EdgeInsets.symmetric(horizontal: space.x3),
        child: Row(
          children: <Widget>[
            Icon(Icons.search, size: 18, color: colors.ink2),
            SizedBox(width: space.x2),
            Expanded(
              child: TextField(
                key: const Key('my-foods-filter'),
                controller: controller,
                onChanged: onChanged,
                textInputAction: TextInputAction.search,
                style: context.text.body.copyWith(
                  color: colors.ink,
                  fontSize: 15,
                ),
                decoration: InputDecoration(
                  isCollapsed: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  contentPadding: EdgeInsets.zero,
                  hintText: 'Filter your foods…',
                  hintStyle: context.text.body.copyWith(color: colors.ink3),
                ),
              ),
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) {
                if (value.text.isEmpty) return const SizedBox.shrink();
                return Semantics(
                  button: true,
                  label: 'Clear filter',
                  child: InkResponse(
                    onTap: () {
                      controller.clear();
                      onChanged('');
                    },
                    radius: 22,
                    containedInkWell: false,
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        color: colors.line,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.close,
                        size: 12,
                        color: colors.ink2,
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Populated list — ListView.builder of SearchResultRows + thin dividers.
// ---------------------------------------------------------------------------

class _PopulatedList extends StatelessWidget {
  const _PopulatedList({required this.foods, required this.query});

  final List<Food> foods;
  final String query;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(
          top: BorderSide(color: colors.line),
          bottom: BorderSide(color: colors.line),
        ),
      ),
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: foods.length,
        separatorBuilder: (_, __) => Divider(
          height: 1,
          thickness: 1,
          color: colors.line2,
          indent: context.space.x5,
        ),
        // User-source rows route straight into the edit form — the
        // architectural intent for "My foods" is that every row here is
        // owned by the caller and is therefore editable in place. The
        // `source == user` guard is defence-in-depth; in practice
        // `myFoodsProvider` only returns user-source rows so the else
        // branch never fires.
        itemBuilder: (context, i) {
          final food = foods[i];
          final isUser = food.source == FoodSource.user;
          return SearchResultRow(
            food: food,
            query: query,
            onTap: () => context.push(
              isUser ? '/foods/${food.id}/edit' : '/foods/${food.id}',
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Loading body — four skeleton rows. Height matches the populated row
// height (T-08).
// ---------------------------------------------------------------------------

class _LoadingBody extends StatelessWidget {
  const _LoadingBody();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(
          top: BorderSide(color: colors.line),
          bottom: BorderSide(color: colors.line),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (var i = 0; i < 4; i++) ...<Widget>[
            const SkeletonRow(),
            if (i < 3)
              Divider(
                height: 1,
                thickness: 1,
                color: colors.line2,
                indent: context.space.x5,
              ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Empty states — "no customs at all" and "no matches for $query".
// ---------------------------------------------------------------------------

class _NoCustomsEmpty extends StatelessWidget {
  const _NoCustomsEmpty({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.bookmark_outline,
      title: 'No custom foods yet',
      body: 'Tap + to create one',
      action: SizedBox(
        width: 240,
        child: PrimaryButton(
          label: 'Create custom food',
          onPressed: onCreate,
        ),
      ),
    );
  }
}

class _NoMatchesEmpty extends StatelessWidget {
  const _NoMatchesEmpty({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.search_off,
      title: "No customs match '$query'",
      body: 'Try a different name, or clear the filter.',
    );
  }
}

// ---------------------------------------------------------------------------
// Error body — empty-state composition + retry that re-invalidates the
// provider. T-13: error is not a spinner; it's the same empty-state
// surface with an action.
// ---------------------------------------------------------------------------

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.cloud_off,
      title: "Couldn't load custom foods",
      body: 'Try again in a moment.',
      action: SizedBox(
        width: 200,
        child: PrimaryButton(
          label: 'Retry',
          onPressed: onRetry,
        ),
      ),
    );
  }
}
