import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/auth_token.dart';
import '../domain/enums.dart';
import '../domain/user.dart';
import '../features/custom_food/custom_food_screen.dart';
import '../features/food_detail/food_detail_screen.dart';
import '../features/goals/goals_screen.dart';
import '../features/goals/widgets/new_goal_dialog.dart';
import '../features/login/login_screen.dart';
import '../features/login/oidc_callback_screen.dart';
import '../features/my_foods/my_foods_screen.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/profile/profile_screen.dart';
import '../features/scan/scan_screen.dart';
import '../features/search/search_screen.dart';
import '../features/today/today_screen.dart';
import '../features/weight/weight_screen.dart';
import '../form_factor/breakpoints.dart';
import '../providers/food_providers.dart';
import '../providers/profile_providers.dart';
import '../providers/repository_providers.dart';
import '../repositories/food_repository.dart';
import '../theme/context_extensions.dart';
import '../widgets/empty_state.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/keyboard_shortcuts.dart';
import '../widgets/motion.dart';
import '../widgets/placeholder_screen.dart';
import '../widgets/primary_button.dart';
import '../widgets/skeleton.dart';
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
/// `/foods/barcode/:barcode` is a resolver (`_BarcodeResolveScreen`,
/// defined below) that calls `FoodRepository.byBarcode` and
/// `pushReplacement`s to either the food detail (hit) or
/// `/foods/new?barcode=…` (404) per T-021.

final appRouterProvider = Provider<GoRouter>((ref) {
  // LOG-007 — the auth-gate.
  //
  // `_RouterRefreshListenable` observes `authTokenProvider` and notifies
  // on every flip; `GoRouter` re-evaluates `redirect` on the next frame.
  // The subscription returned by `ref.listen` lives for the Provider's
  // lifetime — the `appRouterProvider` is unauto-disposed and lives for
  // the app's lifetime, so there's nothing to dispose by hand.
  final refreshListenable = _RouterRefreshListenable(ref);
  return GoRouter(
    initialLocation: Routes.todayPath,
    debugLogDiagnostics: false,
    refreshListenable: refreshListenable,
    // LOG-007 — synchronous redirect (go_router requires sync). Five
    // rules per architect_login.md §7.2, in this exact order:
    //
    //   1. no token + /login          → allow (return null)
    //   2. no token + /onboarding/*   → allow
    //   3. no token + anything else   → /login
    //   4. has token + /login         → /today
    //   5. has token + anything else  → allow
    //
    // Token read via `ref.read` (not `ref.watch`) — the
    // `refreshListenable` above is what triggers re-evaluation when the
    // token flips.
    redirect: (context, state) {
      final token = ref.read(authTokenProvider);
      final loc = state.matchedLocation;
      if (token == null) {
        if (loc == Routes.loginPath) return null;
        // Ask 8 — `/login/callback` is the OIDC handoff landing. The
        // user is still un-authed when they land here (the handoff
        // code is what gets exchanged for the bearer); let them
        // through so the exchange can run.
        if (loc == Routes.oidcCallbackPath) return null;
        if (loc.startsWith('/onboarding/')) return null;
        return Routes.loginPath;
      }
      if (loc == Routes.loginPath) return Routes.todayPath;

      // F3 — onboarding gate. Pass-throughs come BEFORE the meProvider
      // read so a user actively in the flow isn't re-fired through the
      // predicate on every step transition, and the OIDC callback
      // screen (mid-handshake) is never bounced. The
      // `loc.startsWith('/onboarding/')` pass-through is load-bearing
      // for loop avoidance — don't lift it.
      if (loc.startsWith('/onboarding/')) return null;
      if (loc == Routes.oidcCallbackPath) return null;

      // `meProvider` is a FutureProvider; redirect is sync. Bridge via
      // `.value` — returns the resolved `User` once data lands, `null`
      // while loading OR on error. Loading: no redirect this frame
      // (the screen renders its own skeleton; the meProvider listen on
      // the refreshListenable below re-fires the router when /me
      // resolves). Error: also `null` — we let the screen surface the
      // error rather than papering over server problems with an
      // onboarding redirect.
      final me = ref.read(meProvider).value;
      if (me == null) return null;
      if (needsOnboarding(me)) return '/onboarding/1';

      return null;
    },
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
            pageBuilder: (context, state) => _shellPage(
              context,
              state,
              const TodayScreen(),
            ),
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
            pageBuilder: (context, state) => _shellPage(
              context,
              state,
              const SearchScreen(),
            ),
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
                builder: (_, __) => const MyFoodsScreen(),
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
            pageBuilder: (context, state) => _shellPage(
              context,
              state,
              const ProfileScreen(),
            ),
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
      //
      // Order matters: specific paths declared before the catch-all
      // `:foodId` pattern. go_router 14.x walks `routes:` top-down and
      // the first match wins, so `/foods/new` (and every other reserved
      // verb under `/foods/*`) must register before `/foods/:foodId`
      // or it collapses into the detail route with `foodId: "new"`.
      // (Architect F2 — the negative-lookahead regex approach was
      // rejected because go_router 14.x can't parse it; reordering is
      // the supported fallback.)
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
      // Outside-the-shell barcode scanner route. Non-deep-linkable in
      // spirit per `specs/architect_barcode.md` §3.1; the only caller
      // is `openBarcodeScanner` which `kIsWeb`-gates.
      GoRoute(
        name: Routes.foodScanName,
        path: Routes.foodScanPath,
        builder: (_, __) => const ScanScreen(),
      ),
      GoRoute(
        name: Routes.foodEditName,
        path: Routes.foodEditPath,
        builder: (_, state) => _FoodEditResolveScreen(
          foodId: state.pathParameters['foodId']!,
        ),
      ),
      // Catch-all `:foodId` — MUST stay last in this block. Adding a new
      // sibling under `/foods/*`? Declare it above this route.
      GoRoute(
        name: Routes.foodDetailName,
        path: Routes.foodDetailPath,
        builder: (_, state) => FoodDetailScreen(
          foodId: state.pathParameters['foodId']!,
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
      // LOG-006 — the self-hosted login screen. Outside the `ShellRoute`
      // so it has no nav chrome (no bottom tabs, no sidebar). The
      // redirect rule + `refreshListenable` that pin unauthenticated
      // users here are owned by LOG-007; this ticket lands the route
      // registration only — navigating to `/login` directly works, but
      // navigating to `/today` with no token does NOT yet redirect.
      GoRoute(
        name: Routes.loginName,
        path: Routes.loginPath,
        builder: (_, __) => const LoginScreen(),
      ),
      // Ask 8 — OIDC callback landing. Outside the ShellRoute so the
      // exchange-in-progress screen has no nav chrome. Reads the
      // single-use handoff code off the query string and posts to
      // `/auth/oidc/exchange` for the real opaque bearer.
      GoRoute(
        name: Routes.oidcCallbackName,
        path: Routes.oidcCallbackPath,
        builder: (context, state) => OidcCallbackScreen(
          code: state.uri.queryParameters['code'] ?? '',
        ),
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
// LOG-007 — Router refresh listenable.
// ---------------------------------------------------------------------------

/// Bridges `authTokenProvider` + `meProvider` (Riverpod) to
/// `GoRouter.refreshListenable` (Flutter `Listenable`). Subscribes once
/// at construction; every token flip or `meProvider` transition calls
/// `notifyListeners()`, which prompts go_router to re-run its
/// `redirect` callback on the next frame.
///
/// The `meProvider` listen is what makes the F3 onboarding gate work:
/// the redirect callback reads `ref.read(meProvider).value` synchronously
/// (`null` while loading), so without a refresh trigger the router would
/// never re-evaluate once /me resolves. Riverpod fires the listener on
/// the initial loading → data transition as well as every invalidate,
/// so sign-in and onboarding-completion both wake the router up.
///
/// The subscription returned by `ref.listen` lives for the lifetime of the
/// owning Provider — `appRouterProvider` is unauto-disposed, so it lives
/// for the app's lifetime. No manual cleanup needed.
class _RouterRefreshListenable extends ChangeNotifier {
  _RouterRefreshListenable(this._ref) {
    _ref.listen<String?>(authTokenProvider, (prev, next) {
      notifyListeners();
    });
    _ref.listen<AsyncValue<User>>(meProvider, (prev, next) {
      notifyListeners();
    });
  }

  final Ref _ref;
}

// ---------------------------------------------------------------------------
// T-016 — High-traffic route transitions.
// ---------------------------------------------------------------------------

/// Form-factor-aware page builder for the three high-traffic shell tabs
/// (`/today`, `/foods`, `/me`). On expanded width (desktop web) the page
/// fades in over 180 ms; on compact/medium the default `MaterialPage`
/// slide-from-right is used.
///
/// Architect ruling (§B4): only these three routes get the custom
/// transition; the rest keep go_router's defaults. The form factor is
/// read off `MediaQuery.sizeOf(context)` since `state` does not expose
/// it directly — `ShellRoute` ensures a `MaterialApp` is mounted above
/// us at this point, so the lookup is safe.
Page<void> _shellPage(BuildContext context, GoRouterState state, Widget child) {
  final width = MediaQuery.sizeOf(context).width;
  final isExpanded = width >= Breakpoints.mediumMax;
  if (!isExpanded) {
    return MaterialPage<void>(key: state.pageKey, child: child);
  }
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionDuration: motion(context, const Duration(milliseconds: 180)),
    reverseTransitionDuration:
        motion(context, const Duration(milliseconds: 180)),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      return FadeTransition(
        opacity: CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        ),
        child: child,
      );
    },
  );
}

// ---------------------------------------------------------------------------
// T-021 — Barcode resolver screen.
// ---------------------------------------------------------------------------

/// `/foods/barcode/:barcode` resolver. Runs `FoodRepository.byBarcode`
/// once on first build:
///
/// - On success → `pushReplacement('/foods/${food.id}')`. The user's
///   back button lands wherever they were before they pasted the
///   barcode, not on this transient screen.
/// - On a `null` return (server `404 not_found`) →
///   `pushReplacement('/foods/new?barcode=…')`
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
      // `byBarcode` maps the server's `404 not_found` (no food known for
      // that barcode) to `null` — the expected scan miss surfaces as
      // "open the create-custom screen pre-filled with this barcode".
      if (food == null) {
        context.pushReplacement('/foods/new?barcode=${widget.barcode}');
        return;
      }
      context.pushReplacement('/foods/${food.id}');
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
        // QL-106 — the ~80 ms cache-hit window used to flash a centered
        // `CircularProgressIndicator`. T-08 + architect §7.1: render a
        // skeleton sized to the food-detail hero (~140 px) so the
        // surface is layout-stable across the resolve.
        child: _loading
            ? Padding(
                padding: EdgeInsets.fromLTRB(
                  context.space.x5,
                  context.space.x5,
                  context.space.x5,
                  0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Skeleton(
                      height: 140,
                      borderRadius:
                          BorderRadius.circular(context.radius.r3),
                    ),
                    SizedBox(height: context.space.x4),
                    const Skeleton(height: 18, width: 200),
                    SizedBox(height: context.space.x2),
                    const Skeleton(height: 12, width: 140),
                  ],
                ),
              )
            : Center(
                child: _BarcodeResolveError(
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

// ---------------------------------------------------------------------------
// Food edit resolver screen — `/foods/:foodId/edit`.
// ---------------------------------------------------------------------------

/// Resolver for `/foods/:foodId/edit`. Reads the food via
/// `foodDetailProvider`, then:
///
/// - **data + source == user** → renders the [CustomFoodScreen] in edit
///   mode with `existing: food`.
/// - **data + source != user** → renders a "Only your custom foods can
///   be edited" `EmptyState` with a back affordance. OFF / USDA rows
///   are not editable (PM ruling: their data is upstream and shared
///   across users).
/// - **loading** → the same shimmer the food detail screen shows, so
///   the layout doesn't jump when the data lands.
/// - **error** → an inline `EmptyState` with a Retry affordance.
class _FoodEditResolveScreen extends ConsumerWidget {
  const _FoodEditResolveScreen({required this.foodId});

  final String foodId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(foodDetailProvider(foodId));
    return async.when(
      loading: () => const _FoodEditLoading(),
      error: (err, _) => _FoodEditError(
        error: err,
        foodId: foodId,
        onRetry: () => ref.invalidate(foodDetailProvider(foodId)),
      ),
      data: (food) {
        if (food.source != FoodSource.user) {
          return _FoodEditNotEditable(foodId: food.id);
        }
        return CustomFoodScreen(existing: food);
      },
    );
  }
}

class _FoodEditLoading extends StatelessWidget {
  const _FoodEditLoading();

  @override
  Widget build(BuildContext context) {
    final space = context.space;
    return Scaffold(
      backgroundColor: context.colors.bg,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(space.x5, space.x4, space.x5, space.x6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Skeleton(height: 22, width: 180),
              SizedBox(height: space.x4),
              const SkeletonRow(),
              SizedBox(height: space.x1),
              const SkeletonRow(),
              SizedBox(height: space.x1),
              const SkeletonRow(),
            ],
          ),
        ),
      ),
    );
  }
}

class _FoodEditError extends StatelessWidget {
  const _FoodEditError({
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
    return Scaffold(
      backgroundColor: context.colors.bg,
      body: SafeArea(
        child: Center(
          child: EmptyState(
            icon: isNotFound ? Icons.no_food_outlined : Icons.cloud_off,
            title: isNotFound ? 'Food not found' : "Couldn't load food",
            body: isNotFound
                ? "We don't have a record for $foodId."
                : 'Pull to refresh or tap retry.',
            action: SizedBox(
              width: 200,
              child: isNotFound
                  ? PrimaryButton(
                      label: 'Go back',
                      onPressed: () => _popOrFallback(context),
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

class _FoodEditNotEditable extends StatelessWidget {
  const _FoodEditNotEditable({required this.foodId});

  final String foodId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.bg,
      body: SafeArea(
        child: Center(
          child: EmptyState(
            icon: Icons.lock_outline,
            title: 'Only your custom foods can be edited',
            body: 'This food was sourced from a public database.',
            action: SizedBox(
              width: 200,
              child: PrimaryButton(
                label: 'Back',
                onPressed: () => _popOrFallback(context, fallback: '/foods/$foodId'),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

void _popOrFallback(BuildContext context, {String fallback = '/foods'}) {
  final router = GoRouter.of(context);
  if (router.canPop()) {
    router.pop();
  } else {
    router.go(fallback);
  }
}
