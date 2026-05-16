import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/food.dart';
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
  const SearchScreen({this.initialQuery, super.key});

  /// Optional seed from the `?q=` query parameter. Passed straight to
  /// `SearchScreenBody`.
  final String? initialQuery;

  @override
  Widget build(BuildContext context) {
    return SearchScreenBody(initialQuery: initialQuery);
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
    this.onClose,
    this.autofocus = true,
    super.key,
  });

  final String? initialQuery;

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
  String _query = '';

  @override
  void initState() {
    super.initState();
    _query = widget.initialQuery?.trim() ?? '';
    _controller = TextEditingController(text: _query);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    final next = value;
    if (next == _query) return;
    setState(() => _query = next);

    // Web barcode-paste path: if the user pastes an 8–14 all-digit string
    // into the search field on web desktop, route to the barcode
    // resolver. (PM Risk 3 / `pm_decisions_flutter_ui.md`.) The route
    // owner handles 404 → `/foods/new?barcode=...`.
    if (FormFactor.isWeb && !context.formFactor.isCompact) {
      final trimmed = next.trim();
      final isAllDigits = RegExp(r'^\d+$').hasMatch(trimmed);
      if (isAllDigits && trimmed.length >= 8 && trimmed.length <= 14) {
        // Defer until after the frame so the controller settles first.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          context.push('/foods/barcode/$trimmed');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isQueryActive = _query.trim().isNotEmpty;
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
            ),
            Expanded(
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.only(bottom: context.space.x8),
                children: <Widget>[
                  if (!isQueryActive) ...<Widget>[
                    _ChipsSection(
                      provider: recentFoodsProvider,
                      title: 'Recent',
                      dotColor: context.colors.accent,
                    ),
                    _ChipsSection(
                      provider: frequentFoodsProvider,
                      title: 'Frequent',
                      // T-03: Frequent uses ink3 instead of the macro
                      // protein color from the mock — see QuickChipRow.
                      dotColor: context.colors.ink3,
                    ),
                  ],
                  if (isQueryActive)
                    _ResultsSection(query: _query)
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
// Top bar — back / search field / scan button.
// ---------------------------------------------------------------------------

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.controller,
    required this.onQueryChanged,
    required this.onClose,
    required this.autofocus,
  });

  final TextEditingController controller;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback? onClose;
  final bool autofocus;

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
              autofocus: autofocus,
              hintText: 'Search foods or paste a barcode…',
            ),
          ),
          SizedBox(width: context.space.x2),
          BarcodeScanButton(
            onScan: (code) => context.push('/foods/barcode/$code'),
          ),
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
  });

  final FutureProvider<List<Food>> provider;
  final String title;
  final Color dotColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(provider);
    return async.when(
      // T-13: don't replace populated content with a spinner. Loading
      // here means we have no chip data yet — render an empty
      // placeholder of the same height so the page doesn't jump.
      loading: () => SizedBox(height: 72, width: double.infinity),
      error: (_, __) => const SizedBox.shrink(),
      data: (foods) => QuickChipRow(
        title: title,
        foods: foods,
        dotColor: dotColor,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Results section — header (with count) + skeleton rows during load +
// empty/error states.
// ---------------------------------------------------------------------------

class _ResultsSection extends ConsumerWidget {
  const _ResultsSection({required this.query});

  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final results = ref.watch(foodSearchProvider(query));
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
                  style: context.text.eyebrow
                      .copyWith(color: context.colors.ink3),
                ),
              ),
              Text(
                results.maybeWhen(
                  data: (rows) => _countLabel(rows.length),
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
            // T-11: transient error → snackbar. The list area shows the
            // empty state so the user has something to act on.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!context.mounted) return;
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                SnackBar(
                  content: Text('Search failed — $err'),
                  duration: const Duration(seconds: 3),
                ),
              );
            });
            return _EmptyState(message: 'Could not load results. Try again.');
          },
          data: (rows) {
            if (rows.isEmpty) {
              return _EmptyState(
                message: 'No foods match "${query.trim()}".',
              );
            }
            return _ResultsList(query: query, rows: rows);
          },
        ),
      ],
    );
  }

  String _countLabel(int n) =>
      n == 1 ? '1 food' : '$n foods';
}

class _ResultsList extends StatelessWidget {
  const _ResultsList({required this.query, required this.rows});

  final String query;
  final List<Food> rows;

  @override
  Widget build(BuildContext context) {
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
          for (var i = 0; i < rows.length; i++) ...<Widget>[
            SearchResultRow(food: rows[i], query: query),
            if (i < rows.length - 1)
              Divider(
                height: 1,
                thickness: 1,
                color: context.colors.line2,
                indent: context.space.x5,
                endIndent: 0,
              ),
          ],
        ],
      ),
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
            const _SkeletonRow(),
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

class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.space.x5,
        vertical: context.space.x3 + 2,
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: context.colors.line2,
              borderRadius: BorderRadius.circular(context.radius.r1 + 2),
            ),
          ),
          SizedBox(width: context.space.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  height: 12,
                  width: double.infinity,
                  color: context.colors.line2,
                ),
                SizedBox(height: context.space.x1 + 2),
                Container(
                  height: 10,
                  width: 140,
                  color: context.colors.line2,
                ),
              ],
            ),
          ),
          SizedBox(width: context.space.x3),
          Container(
            height: 14,
            width: 36,
            color: context.colors.line2,
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.space.x5,
        vertical: context.space.x6,
      ),
      child: Center(
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: context.text.meta.copyWith(color: context.colors.ink2),
        ),
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
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.black.withValues(alpha: 0.32),
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
