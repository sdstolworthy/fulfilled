import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:fulfilled/widgets/empty_state.dart';
import 'package:fulfilled/widgets/primary_button.dart';
import 'package:fulfilled/widgets/skeleton.dart';

import '../../domain/food.dart';
import '../../domain/meal.dart';
import '../../form_factor/form_factor.dart';
import '../../providers/food_providers.dart';
import '../../theme/context_extensions.dart';
import 'widgets/barcode_scan_button.dart';
import 'widgets/quick_chip_row.dart';
import 'widgets/search_field.dart';
import 'widgets/search_result_row.dart';

/// Screen 02 — Food search. Architecture §9 "Screen 02 — Search".
///
/// Composition (mobile + web):
/// 1. Top bar: back chevron + [SearchField] + [BarcodeScanButton]
/// 2. Body: "Recent" + [QuickChipRow] + "Frequent" + [QuickChipRow]
///    when the query is empty.
/// 3. Results section header (with live `N foods` count) + a
///    [SearchResultRow] list when the query is non-empty.
///
/// Debounce lives **in `foodSearchProvider`**, not here — see the
/// docstring on that provider. The widget watches the family with the
/// raw query string on every keystroke; the provider absorbs the
/// 250 ms throttle.
///
/// **Desktop ⌘K** — `showCommandPaletteSearch` mounts the same body in a
/// centered `Dialog`. Other agents (the global shortcuts handler) call
/// it. The dialog wraps `SearchScreenBody` directly.
class SearchScreen extends StatelessWidget {
  const SearchScreen({this.initialQuery, this.initialMeal, super.key});

  /// Optional seed from the `?q=` query parameter. Passed straight to
  /// `SearchScreenBody`.
  final String? initialQuery;

  /// Optional meal hint from the `?meal=<wire>` query parameter. Set
  /// when the user reached the search screen via a meal-section
  /// "Add food" tap; forwarded to `/foods/<id>?meal=<wire>` on row
  /// tap so the log-entry sheet seeds its meal picker to match.
  final Meal? initialMeal;

  @override
  Widget build(BuildContext context) {
    return SearchScreenBody(
      initialQuery: initialQuery,
      initialMeal: initialMeal,
    );
  }
}

/// The body without an outer scaffold — exported so the command palette
/// dialog can wrap it.
///
/// Renders its own top bar (back / search / scan), so it slots into the
/// shell content area without depending on `AppBar`. On compact phones
/// the back chevron pops the navigator; on expanded the dialog closes
/// via `Navigator.pop` from the dialog wrapper instead.
class SearchScreenBody extends ConsumerStatefulWidget {
  const SearchScreenBody({
    this.initialQuery,
    this.initialMeal,
    this.onClose,
    this.autofocus = true,
    super.key,
  });

  final String? initialQuery;

  /// Meal hint forwarded when pushing a result row to the food-detail
  /// route. Null = no hint (the sheet falls back to `mealForLocalTime`).
  final Meal? initialMeal;

  /// Optional close hook. The dialog wrapper passes a function that pops
  /// the dialog; the route variant lets `context.pop()` happen via the
  /// default back-chevron path.
  final VoidCallback? onClose;

  /// Autofocus the search field on first paint. True from the route
  /// entry; the dialog uses true too.
  final bool autofocus;

  @override
  ConsumerState<SearchScreenBody> createState() => _SearchScreenBodyState();
}

class _SearchScreenBodyState extends ConsumerState<SearchScreenBody> {
  late final TextEditingController _controller;
  late final ScrollController _scrollController;
  String _query = '';

  /// Pixels from `maxScrollExtent` at which we start prefetching the
  /// next page. ~3 rows of slack so the spinner appears before the
  /// user actually hits the bottom edge.
  static const double _loadMorePrefetchPx = 240;

  @override
  void initState() {
    super.initState();
    _query = widget.initialQuery?.trim() ?? '';
    _controller = TextEditingController(text: _query);
    _scrollController = ScrollController()..addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Trigger a `loadMore()` on the active query's paginator when the
  /// list nears its bottom. The notifier short-circuits redundant
  /// calls, so a noisy stream of scroll callbacks is safe.
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels < position.maxScrollExtent - _loadMorePrefetchPx) {
      return;
    }
    final trimmed = _query.trim();
    if (trimmed.isEmpty) return;
    final firstPage =
        ref.read(foodSearchProvider(trimmed)).asData?.value ?? const <Food>[];
    if (firstPage.isEmpty) return;
    final pageState = ref.read(foodSearchPaginationProvider(trimmed));
    if (!pageState.hasMore || pageState.isLoadingMore) return;
    final currentTotal = firstPage.length + pageState.extra.length;
    ref
        .read(foodSearchPaginationProvider(trimmed).notifier)
        .loadMore(currentTotal: currentTotal);
  }

  void _onQueryChanged(String value) {
    final next = value;
    if (next == _query) return;
    setState(() => _query = next);
  }

  /// T-021 — when the input is 8–14 digits and we're on expanded, show
  /// the "Look up barcode …" affordance row. Returns null otherwise so
  /// callers can render nothing. Centralised so the build method and
  /// the Enter-key handler agree on what counts as a barcode.
  static final RegExp _barcodeRegex = RegExp(r'^\d{8,14}$');

  String? _barcodeCandidate(BuildContext context) {
    if (!context.formFactor.isExpanded) return null;
    final trimmed = _query.trim();
    return _barcodeRegex.hasMatch(trimmed) ? trimmed : null;
  }

  @override
  Widget build(BuildContext context) {
    final isQueryActive = _query.trim().isNotEmpty;
    final barcode = _barcodeCandidate(context);
    return ColoredBox(
      color: context.colors.bg,
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _TopBar(
              controller: _controller,
              onQueryChanged: _onQueryChanged,
              onClose: widget.onClose,
              autofocus: widget.autofocus,
              // T-021 — Enter on the field while the input looks like a
              // barcode routes the same as tapping the affordance row.
              onSubmitted: (_) {
                final code = _barcodeCandidate(context);
                if (code != null) context.push('/foods/barcode/$code');
              },
            ),
            Expanded(
              child: ListView(
                controller: _scrollController,
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.only(bottom: context.space.x8),
                children: <Widget>[
                  // T-021 affordance row — expanded only, shown whenever
                  // the input matches `^\d{8,14}$`. Sits above the
                  // chip/result body so the user sees it on first paint
                  // after pasting.
                  if (barcode != null)
                    _BarcodeAffordanceRow(
                      barcode: barcode,
                      onTap: () => context.push('/foods/barcode/$barcode'),
                    ),
                  if (!isQueryActive) ...<Widget>[
                    _ChipsSection(
                      provider: recentFoodsProvider,
                      title: 'Recent',
                      dotColor: context.colors.accent,
                      mealHint: widget.initialMeal,
                    ),
                    _ChipsSection(
                      provider: frequentFoodsProvider,
                      title: 'Frequent',
                      // T-03: Frequent uses ink3 instead of the macro
                      // protein color from the mock — see QuickChipRow.
                      dotColor: context.colors.ink3,
                      mealHint: widget.initialMeal,
                    ),
                  ],
                  if (isQueryActive)
                    _ResultsSection(query: _query, mealHint: widget.initialMeal)
                  else
                    SizedBox(height: context.space.x3),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// T-021 — Desktop "paste a barcode" affordance row.
// ---------------------------------------------------------------------------

/// Compact row rendered below the search input on `expanded` whenever the
/// input value matches `^\d{8,14}$`. Tapping (or pressing Enter on the
/// field, handled by `_TopBar`) routes to `/foods/barcode/$value`, where
/// the route resolver in `app_router.dart` redirects to the food detail
/// on a hit or to the "create custom food" form prefilled with the
/// barcode on a 404. The route owner is the source of truth for the
/// success/404 split; this widget only emits the navigation.
///
/// Visual: small leading `qr_code_2` icon, `ink2` text
/// `"Look up barcode {value} →"`, accent-tinted hover background.
/// Honours T-06 (tap target ≥ 44 px).
class _BarcodeAffordanceRow extends StatefulWidget {
  const _BarcodeAffordanceRow({required this.barcode, required this.onTap});

  final String barcode;
  final VoidCallback onTap;

  @override
  State<_BarcodeAffordanceRow> createState() => _BarcodeAffordanceRowState();
}

class _BarcodeAffordanceRowState extends State<_BarcodeAffordanceRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final space = context.space;
    return Semantics(
      button: true,
      label: 'Look up barcode ${widget.barcode}',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: InkWell(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            constraints: const BoxConstraints(minHeight: 44),
            margin: EdgeInsets.fromLTRB(space.x5, space.x2, space.x5, space.x1),
            padding: EdgeInsets.symmetric(
              horizontal: space.x3,
              vertical: space.x2,
            ),
            decoration: BoxDecoration(
              color: _hovered
                  ? colors.accent.withValues(alpha: 0.08)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(context.radius.r2),
              border: Border.all(color: colors.line),
            ),
            child: Row(
              children: <Widget>[
                Icon(Icons.qr_code_2, size: 18, color: colors.ink2),
                SizedBox(width: space.x2),
                Expanded(
                  child: Text(
                    'Look up barcode ${widget.barcode} →',
                    style: context.text.body.copyWith(color: colors.ink2),
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

// ---------------------------------------------------------------------------
// Top bar — back / search field / scan button.
// ---------------------------------------------------------------------------

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.controller,
    required this.onQueryChanged,
    required this.onClose,
    required this.autofocus,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback? onClose;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.space.x3,
        context.space.x2,
        context.space.x3,
        context.space.x3,
      ),
      child: Row(
        children: <Widget>[
          _BackButton(onClose: onClose),
          SizedBox(width: context.space.x2),
          Expanded(
            child: SearchField(
              controller: controller,
              onChanged: onQueryChanged,
              onSubmitted: onSubmitted,
              autofocus: autofocus,
              // No explicit `hintText` — `SearchField` picks the
              // compact / expanded variant by form factor (T-021).
            ),
          ),
          SizedBox(width: context.space.x2),
          const BarcodeScanButton(),
        ],
      ),
    );
  }
}

class _BackButton extends StatelessWidget {
  const _BackButton({required this.onClose});

  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Back',
      child: InkResponse(
        radius: 24,
        onTap: () {
          if (onClose != null) {
            onClose!();
          } else if (Navigator.of(context).canPop()) {
            context.pop();
          } else {
            context.go('/today');
          }
        },
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(
            Icons.chevron_left,
            size: 24,
            color: context.colors.ink,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Chips sections — wrap the QuickChipRow widget with AsyncValue handling.
// ---------------------------------------------------------------------------

class _ChipsSection extends ConsumerWidget {
  const _ChipsSection({
    required this.provider,
    required this.title,
    required this.dotColor,
    this.mealHint,
  });

  final FutureProvider<List<Food>> provider;
  final String title;
  final Color dotColor;

  /// Forwarded to [QuickChipRow] so chip taps land on
  /// `/foods/<id>?meal=<wire>` when the user entered the search via a
  /// meal-section "Add food".
  final Meal? mealHint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(provider);
    return async.when(
      // T-13: don't replace populated content with a spinner. Loading
      // here means we have no chip data yet — render an empty
      // placeholder of the same height so the page doesn't jump.
      loading: () => const SizedBox(height: 72, width: double.infinity),
      error: (_, __) => const SizedBox.shrink(),
      data: (foods) => QuickChipRow(
        title: title,
        foods: foods,
        dotColor: dotColor,
        mealHint: mealHint,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Results section — header (with count) + skeleton rows during load +
// empty/error states.
// ---------------------------------------------------------------------------

class _ResultsSection extends ConsumerWidget {
  const _ResultsSection({required this.query, this.mealHint});

  final String query;

  /// Forwarded down to [_ResultsList] so row taps preserve the meal
  /// hint when the user came in from a meal-section "Add food".
  final Meal? mealHint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // QL-109 — defense in depth against the empty-query flash. The
    // parent `SearchScreenBody` already gates the render on
    // `isQueryActive = _query.trim().isNotEmpty`, but if a caller ever
    // mounts `_ResultsSection` with an empty query (or a query that
    // becomes empty between frames), short-circuit before consulting
    // the debounced search future. Reading `foodSearchProvider('')`
    // returns an empty list synchronously today — but a stale cached
    // value for a prior key could otherwise paint for a frame.
    if (query.trim().isEmpty) {
      return const SizedBox.shrink();
    }
    final results = ref.watch(foodSearchProvider(query));
    final pagination = ref.watch(foodSearchPaginationProvider(query));
    // Seed the paginator the first time the first page lands. We do it
    // in a post-frame callback because `seedFromFirstPage` mutates the
    // paginator's state, and `build()` must stay side-effect-free.
    results.whenData((rows) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        ref
            .read(foodSearchPaginationProvider(query).notifier)
            .seedFromFirstPage(rows.length);
      });
    });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(
            context.space.x5,
            context.space.x4 - 2,
            context.space.x5,
            context.space.x2,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Expanded(
                child: Text(
                  'RESULTS',
                  style:
                      context.text.eyebrow.copyWith(color: context.colors.ink3),
                ),
              ),
              Text(
                results.maybeWhen(
                  data: (rows) =>
                      _countLabel(rows.length + pagination.extra.length),
                  orElse: () => '',
                ),
                style: context.text.metaNumeric.copyWith(
                  color: context.colors.ink3,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        results.when(
          loading: () => const _ResultsSkeleton(),
          error: (err, _) {
            // T-11: transient error → snackbar (attention) + inline
            // EmptyState (persistence + retry CTA). The retry
            // re-invalidates the family entry for this query.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!context.mounted) return;
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                SnackBar(
                  content: Text('Search failed — $err'),
                  duration: const Duration(seconds: 3),
                ),
              );
            });
            return EmptyState(
              icon: Icons.cloud_off,
              title: "Couldn't load results",
              body: 'Pull to refresh or tap retry.',
              action: SizedBox(
                width: 200,
                child: PrimaryButton(
                  label: 'Retry',
                  onPressed: () => ref.invalidate(foodSearchProvider(query)),
                ),
              ),
            );
          },
          data: (rows) {
            if (rows.isEmpty) {
              return const EmptyState(
                icon: Icons.search_off,
                title: 'No matches',
                body: 'Try a different name.',
              );
            }
            return _ResultsList(
              query: query,
              rows: <Food>[...rows, ...pagination.extra],
              mealHint: mealHint,
              isLoadingMore: pagination.isLoadingMore,
            );
          },
        ),
      ],
    );
  }

  String _countLabel(int n) => n == 1 ? '1 food' : '$n foods';
}

class _ResultsList extends StatelessWidget {
  const _ResultsList({
    required this.query,
    required this.rows,
    this.mealHint,
    this.isLoadingMore = false,
  });

  final String query;
  final List<Food> rows;

  /// When non-null, row taps push `/foods/<id>?meal=<wire>` so the
  /// food-detail route can seed the log-entry sheet's default meal.
  /// Null preserves the route's stock behaviour (no query param).
  final Meal? mealHint;

  /// `true` while the next page is being fetched. Renders a trailing
  /// progress indicator row so the user knows more rows are arriving.
  final bool isLoadingMore;

  @override
  Widget build(BuildContext context) {
    // F5-T4 — partition into "YOUR FOODS" (logged) + "ALL FOODS" (cold).
    // Sort the logged bucket by `lastLoggedAt desc`, breaking ties by
    // `logCount desc` and then `id asc` (uuid string compare is stable +
    // total). The cold bucket keeps the BE search-rank order. A new
    // logged row arriving on a later page jumps to the top of "YOUR
    // FOODS" after the next sort — mildly jarring but rare; see FE
    // plan §6.
    final logged = <Food>[];
    final cold = <Food>[];
    for (final f in rows) {
      if (f.wasLoggedByCaller) {
        logged.add(f);
      } else {
        cold.add(f);
      }
    }
    logged.sort((a, b) {
      final cmp = b.lastLoggedAt!.compareTo(a.lastLoggedAt!);
      if (cmp != 0) return cmp;
      final logCmp = (b.logCount ?? 0).compareTo(a.logCount ?? 0);
      if (logCmp != 0) return logCmp;
      return a.id.compareTo(b.id);
    });

    // Collapse rules:
    //   logged.isEmpty && cold.isNotEmpty → just the cold list, no
    //     section headers (visually identical to pre-F5).
    //   logged.isNotEmpty && cold.isEmpty → only "YOUR FOODS" section.
    //   both non-empty → both sections, both headers.
    //
    // Pagination spinner sits at the bottom of whichever section is
    // last on screen (the cold one when present, otherwise the logged
    // one). It does NOT move into the YOUR FOODS section when both are
    // rendered — the user is paginating the catalog, not their personal
    // history.
    final loggedEmpty = logged.isEmpty;
    final coldEmpty = cold.isEmpty;
    if (loggedEmpty) {
      // Flat list — matches pre-F5 rendering exactly.
      return _SectionContainer(
        child: _RowListColumn(
          rows: cold,
          query: query,
          mealHint: mealHint,
          isLoadingMore: isLoadingMore,
        ),
      );
    }
    if (coldEmpty) {
      // Only "YOUR FOODS" — header serves as the explainer for the sub-
      // line copy on the rows.
      return _SectionContainer(
        headerLabel: 'YOUR FOODS',
        headerCount: logged.length,
        child: _RowListColumn(
          rows: logged,
          query: query,
          mealHint: mealHint,
          isLoadingMore: isLoadingMore,
        ),
      );
    }
    // Both sections render.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _SectionContainer(
          headerLabel: 'YOUR FOODS',
          headerCount: logged.length,
          child: _RowListColumn(
            rows: logged,
            query: query,
            mealHint: mealHint,
            // Spinner lives at the bottom of "ALL FOODS" when both
            // sections are present (FE plan §6).
            isLoadingMore: false,
          ),
        ),
        _SectionContainer(
          headerLabel: 'ALL FOODS',
          headerCount: cold.length,
          child: _RowListColumn(
            rows: cold,
            query: query,
            mealHint: mealHint,
            isLoadingMore: isLoadingMore,
          ),
        ),
      ],
    );
  }
}

/// F5-T4 — wraps a section (optional header + bordered surface body) so
/// the partition logic above stays declarative. The container border +
/// surface bg mirror the pre-F5 single-section chrome.
class _SectionContainer extends StatelessWidget {
  const _SectionContainer({
    required this.child,
    this.headerLabel,
    this.headerCount,
  });

  final Widget child;
  final String? headerLabel;
  final int? headerCount;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (headerLabel != null)
          _SearchSectionHeader(label: headerLabel!, count: headerCount),
        Container(
          margin: EdgeInsets.only(top: context.space.x1),
          decoration: BoxDecoration(
            color: context.colors.surface,
            border: Border(
              top: BorderSide(color: context.colors.line),
              bottom: BorderSide(color: context.colors.line),
            ),
          ),
          child: child,
        ),
      ],
    );
  }
}

/// F5-T4 — local section header for the "YOUR FOODS" / "ALL FOODS"
/// split. Mirrors the existing eyebrow + count badge in
/// `_ResultsSection` so the visual language is consistent.
///
/// TODO: lift _SearchSectionHeader to shared (post-F5) — `quick_add_chips.dart`
/// has a near-identical `_SectionHeader`; the lift refactor is deliberately
/// out of F5 scope per the PM brief.
class _SearchSectionHeader extends StatelessWidget {
  const _SearchSectionHeader({required this.label, required this.count});

  final String label;
  final int? count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.space.x5,
        context.space.x4 - 2,
        context.space.x5,
        context.space.x2,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: context.text.eyebrow.copyWith(color: context.colors.ink3),
            ),
          ),
          if (count != null)
            Text(
              '($count)',
              style: context.text.metaNumeric.copyWith(
                color: context.colors.ink3,
                fontSize: 12,
              ),
            ),
        ],
      ),
    );
  }
}

/// F5-T4 — inner column of `SearchResultRow`s + dividers + optional
/// pagination spinner. Lifted out of `_ResultsList.build` so the
/// section-split branches can share one render path.
class _RowListColumn extends StatelessWidget {
  const _RowListColumn({
    required this.rows,
    required this.query,
    required this.mealHint,
    required this.isLoadingMore,
  });

  final List<Food> rows;
  final String query;
  final Meal? mealHint;
  final bool isLoadingMore;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        for (var i = 0; i < rows.length; i++) ...<Widget>[
          SearchResultRow(
            food: rows[i],
            query: query,
            onTap: () => context.push(
              _detailPathWithMealHint(rows[i].id, mealHint),
            ),
          ),
          if (i < rows.length - 1 || isLoadingMore)
            Divider(
              height: 1,
              thickness: 1,
              color: context.colors.line2,
              indent: context.space.x5,
              endIndent: 0,
            ),
        ],
        if (isLoadingMore)
          Padding(
            padding: EdgeInsets.symmetric(vertical: context.space.x4),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: context.colors.ink3,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ResultsSkeleton extends StatelessWidget {
  const _ResultsSkeleton();

  @override
  Widget build(BuildContext context) {
    // T-08 — skeleton rows that match SearchResultRow's height (~60 px).
    // Four rows fit nicely without scrolling on most phones.
    return Container(
      margin: EdgeInsets.only(top: context.space.x1),
      decoration: BoxDecoration(
        color: context.colors.surface,
        border: Border(
          top: BorderSide(color: context.colors.line),
          bottom: BorderSide(color: context.colors.line),
        ),
      ),
      child: Column(
        children: <Widget>[
          for (var i = 0; i < 4; i++) ...<Widget>[
            const SkeletonRow(),
            if (i < 3)
              Divider(
                height: 1,
                thickness: 1,
                color: context.colors.line2,
                indent: context.space.x5,
              ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Command palette helper. Architecture brief: "Export a second helper
// `Future<void> showCommandPaletteSearch(BuildContext context)` that
// pushes the same SearchScreen body inside a Dialog."
// ---------------------------------------------------------------------------

/// Open the search experience as a centered command-palette-style dialog.
/// Architect's contract: max-width 640, max-height 70 vh on `expanded`.
/// The global keyboard-shortcuts handler binds `⌘K` / `Ctrl-K` to this.
///
/// Esc closes the dialog (Material's default `barrierDismissible: true`
/// + an explicit `Shortcuts`/`Actions` mapping inside).
Future<void> showCommandPaletteSearch(BuildContext context) {
  // FX-006 / T-01: dialog barrier routes through the `scrim` token (the
  // alpha-black scrim authored in `colors.dart`) rather than authoring
  // `Colors.black.withValues(...)` at the call site. The token's alpha
  // already encodes the canonical scrim weight.
  final barrier = context.colors.scrim;
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierColor: barrier,
    builder: (dialogContext) {
      final maxH = MediaQuery.sizeOf(dialogContext).height * 0.70;
      return _CommandPaletteShell(maxHeight: maxH);
    },
  );
}

class _CommandPaletteShell extends StatelessWidget {
  const _CommandPaletteShell({required this.maxHeight});

  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.escape): _DismissDialogIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _DismissDialogIntent: CallbackAction<_DismissDialogIntent>(
            onInvoke: (_) {
              Navigator.of(context).pop();
              return null;
            },
          ),
        },
        child: Dialog(
          insetPadding: EdgeInsets.symmetric(
            horizontal: context.space.x5,
            vertical: context.space.x8,
          ),
          backgroundColor: context.colors.bg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(context.radius.r4),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 640,
              maxHeight: maxHeight,
            ),
            child: SearchScreenBody(
              autofocus: true,
              onClose: () => Navigator.of(context).pop(),
            ),
          ),
        ),
      ),
    );
  }
}

class _DismissDialogIntent extends Intent {
  const _DismissDialogIntent();
}

/// Build the food-detail URL with an optional `?meal=<wire>` suffix.
/// The suffix is forwarded by the food-detail route into the
/// log-entry sheet so the meal picker defaults to the section the
/// user came from. When [hint] is null the stock path is returned.
String _detailPathWithMealHint(String foodId, Meal? hint) {
  if (hint == null) return '/foods/$foodId';
  return '/foods/$foodId?meal=${hint.wire}';
}
