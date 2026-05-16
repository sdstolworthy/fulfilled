import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/custom_food/custom_food_screen.dart';
import '../features/food_detail/food_detail_screen.dart';
import '../features/goals/goals_screen.dart';
import '../features/goals/widgets/new_goal_dialog.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/profile/profile_screen.dart';
import '../features/search/search_screen.dart';
import '../features/today/today_screen.dart';
import '../features/weight/weight_screen.dart';
import '../providers/repository_providers.dart';
import '../repositories/food_repository.dart';
import '../theme/context_extensions.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/keyboard_shortcuts.dart';
import '../widgets/placeholder_screen.dart';
import 'routes.dart';

/// The `go_router` configuration. Shape per architecture §4:
///
/// - A `ShellRoute` wraps the four authenticated tabs (Today / Foods /
///   Weight / Me) so nav chrome is persistent and the child keeps its
///   state across tab switches.
/// - Outside the shell: onboarding, food detail, food new, barcode resolve.
///   These have no nav chrome — they are full-page contexts.
/// - The router itself is provided as a Riverpod provider so nav
///   highlighting can observe the active route (T-15-adjacent: shell
///   decides chrome from route, not from a parallel selection state).
///
/// Each leaf binds to its real `<Name>Screen` from `lib/features/<name>/`.
/// `/foods/mine` is still `PlaceholderScreen` pending a dedicated
/// implementation. `/foods/barcode/:barcode` is a resolver
/// (`_BarcodeResolveScreen`, defined below) that calls
/// `FoodRepository.byBarcode` and `pushReplacement`s to either the food
/// detail (hit) or `/foods/new?barcode=…` (404) per T-021.

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: Routes.todayPath,
    debugLogDiagnostics: false,
    routes: <RouteBase>[
      ShellRoute(
        // T-015: wrap the shell in `KeyboardShortcuts`. The wrapper itself
        // reads `FormFactor.of(context)` via `MediaQuery` and is a
        // passthrough on compact/medium, so the bindings only fire on
        // desktop-class widths where they're useful.
        builder: (context, state, child) => KeyboardShortcuts(
          child: AppScaffold(child: child),
        ),
        routes: <RouteBase>[
          GoRoute(
            name: Routes.todayName,
            path: Routes.todayPath,
            builder: (_, __) => const TodayScreen(),
            routes: <RouteBase>[
              GoRoute(
                name: Routes.todayDateName,
                path: ':date',
                builder: (_, state) {
                  final raw = state.pathParameters['date'];
                  final parsed = raw == null ? null : DateTime.tryParse(raw);
                  return TodayScreen(date: parsed);
                },
              ),
            ],
          ),
          GoRoute(
            name: Routes.foodsName,
            path: Routes.foodsPath,
            builder: (_, __) => const SearchScreen(),
            routes: <RouteBase>[
              GoRoute(
                name: Routes.foodsSearchName,
                path: 'search',
                builder: (_, state) => SearchScreen(
                  initialQuery: state.uri.queryParameters['q'] ?? '',
                ),
              ),
              GoRoute(
                name: Routes.myFoodsName,
                path: 'mine',
                builder: (_, __) => const PlaceholderScreen(
                  screenName: 'My foods',
                  routePath: Routes.myFoodsPath,
                  detail: 'Pending dedicated implementation.',
                ),
              ),
            ],
          ),
          GoRoute(
            name: Routes.weightName,
            path: Routes.weightPath,
            builder: (_, __) => const WeightScreen(),
          ),
          GoRoute(
            name: Routes.meName,
            path: Routes.mePath,
            builder: (_, __) => const ProfileScreen(),
          ),
          GoRoute(
            name: Routes.goalsName,
            path: Routes.goalsPath,
            builder: (_, __) => const GoalsScreen(),
            routes: <RouteBase>[
              GoRoute(
                name: Routes.goalsNewName,
                path: 'new',
                builder: (_, __) => const NewGoalDialog(),
              ),
            ],
          ),
        ],
      ),

      // Outside the shell — full-page contexts. No nav chrome.
      GoRoute(
        name: Routes.foodDetailName,
        path: Routes.foodDetailPath,
        builder: (_, state) => FoodDetailScreen(
          foodId: state.pathParameters['foodId']!,
        ),
      ),
      GoRoute(
        name: Routes.foodNewName,
        path: Routes.foodNewPath,
        builder: (_, state) => CustomFoodScreen(
          // T-021 — 404 path of the barcode resolver lands here with
          // `?barcode=…`; the screen prefills the draft barcode field
          // on first build.
          initialBarcode: state.uri.queryParameters['barcode'],
        ),
      ),
      GoRoute(
        name: Routes.foodBarcodeName,
        path: Routes.foodBarcodePath,
        builder: (_, state) => _BarcodeResolveScreen(
          barcode: state.pathParameters['barcode']!,
        ),
      ),
      GoRoute(
        name: Routes.onboardingName,
        path: Routes.onboardingPath,
        builder: (_, state) {
          final raw = state.pathParameters['step'] ?? '1';
          final step = int.tryParse(raw) ?? 1;
          return OnboardingScreen(step: step);
        },
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(
        child: PlaceholderScreen(
          screenName: 'Route not found',
          routePath: state.uri.toString(),
          detail: state.error?.toString(),
        ),
      ),
    ),
  );
});

// ---------------------------------------------------------------------------
// T-021 — Barcode resolver screen.
// ---------------------------------------------------------------------------

/// `/foods/barcode/:barcode` resolver. Runs `FoodRepository.byBarcode`
/// once on first build:
///
/// - On success → `pushReplacement('/foods/${food.id}')`. The user's
///   back button lands wherever they were before they pasted the
///   barcode, not on this transient screen.
/// - On `FoodNotFoundError` → `pushReplacement('/foods/new?barcode=…')`
///   so the custom-food form picks the barcode up via the `?barcode=`
///   query param (T-021).
/// - On any other error → an inline "Couldn't look up …" message with
///   a Retry button. The retry simply re-runs `byBarcode`. (Matches
///   T-013's inline error pattern; we keep the affordance lightweight
///   because the user is one tap away from going back to search.)
///
/// While the lookup is in flight we render a centered spinner. The
/// screen is intentionally chrome-less (full-page, no nav).
class _BarcodeResolveScreen extends ConsumerStatefulWidget {
  const _BarcodeResolveScreen({required this.barcode});

  final String barcode;

  @override
  ConsumerState<_BarcodeResolveScreen> createState() =>
      _BarcodeResolveScreenState();
}

class _BarcodeResolveScreenState extends ConsumerState<_BarcodeResolveScreen> {
  // null = in flight; non-null = transient/unknown error (we then show
  // the inline "Couldn't look up …" affordance). Success/404 paths
  // navigate away and never reach a second render.
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // Defer the navigation side-effect so `context.pushReplacement` runs
    // after the first build settles (and after the route is registered).
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolve());
  }

  Future<void> _resolve() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final repo = ref.read(foodRepositoryProvider);
    try {
      final food = await repo.byBarcode(widget.barcode);
      if (!mounted) return;
      context.pushReplacement('/foods/${food.id}');
    } on FoodNotFoundError {
      if (!mounted) return;
      context.pushReplacement('/foods/new?barcode=${widget.barcode}');
    } on Object catch (err) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.bg,
      body: SafeArea(
        child: Center(
          child: _loading
              ? const CircularProgressIndicator()
              : _BarcodeResolveError(
                  barcode: widget.barcode,
                  onRetry: _resolve,
                ),
        ),
      ),
    );
  }
}

class _BarcodeResolveError extends StatelessWidget {
  const _BarcodeResolveError({
    required this.barcode,
    required this.onRetry,
  });

  final String barcode;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final space = context.space;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: space.x6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Icon(Icons.qr_code_2, size: 36, color: colors.ink3),
          SizedBox(height: space.x3),
          Text(
            "Couldn't look up $barcode",
            textAlign: TextAlign.center,
            style: context.text.title,
          ),
          SizedBox(height: space.x1),
          Text(
            'Check your connection and try again.',
            textAlign: TextAlign.center,
            style: context.text.meta,
          ),
          SizedBox(height: space.x4),
          Center(
            child: TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                foregroundColor: colors.accent,
                textStyle: context.text.bodyStrong,
              ),
              child: const Text('Retry'),
            ),
          ),
        ],
      ),
    );
  }
}
