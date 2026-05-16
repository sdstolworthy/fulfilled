import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../widgets/app_scaffold.dart';
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
/// Every leaf is a `PlaceholderScreen`. Screen agents replace the leaves
/// one by one. **Do not** restructure the shell tree without a foundation
/// pass — sidebar/bottom-tabs depend on the ShellRoute boundary.

/// Routes that are accessible from the persistent shell (bottom tabs /
/// sidebar). Adding a new shell route here is a foundation-level change.
final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: Routes.todayPath,
    debugLogDiagnostics: false,
    routes: <RouteBase>[
      ShellRoute(
        builder: (context, state, child) => AppScaffold(child: child),
        routes: <RouteBase>[
          GoRoute(
            name: Routes.todayName,
            path: Routes.todayPath,
            builder: (_, __) => const PlaceholderScreen(
              screenName: '01 Day view',
              routePath: Routes.todayPath,
            ),
            routes: <RouteBase>[
              GoRoute(
                name: Routes.todayDateName,
                path: ':date',
                builder: (_, state) => PlaceholderScreen(
                  screenName: '01 Day view',
                  routePath: '${Routes.todayPath}/${state.pathParameters['date']}',
                  detail: 'date = ${state.pathParameters['date']}',
                ),
              ),
            ],
          ),
          GoRoute(
            name: Routes.foodsName,
            path: Routes.foodsPath,
            builder: (_, __) => const PlaceholderScreen(
              screenName: '02 Search',
              routePath: Routes.foodsPath,
            ),
            routes: <RouteBase>[
              GoRoute(
                name: Routes.foodsSearchName,
                path: 'search',
                builder: (_, state) => PlaceholderScreen(
                  screenName: '02 Search',
                  routePath: Routes.foodsSearchPath,
                  detail: 'q = ${state.uri.queryParameters['q'] ?? ''}',
                ),
              ),
              GoRoute(
                name: Routes.myFoodsName,
                path: 'mine',
                builder: (_, __) => const PlaceholderScreen(
                  screenName: 'My foods',
                  routePath: Routes.myFoodsPath,
                ),
              ),
            ],
          ),
          GoRoute(
            name: Routes.weightName,
            path: Routes.weightPath,
            builder: (_, __) => const PlaceholderScreen(
              screenName: '06 Weight log',
              routePath: Routes.weightPath,
            ),
          ),
          GoRoute(
            name: Routes.meName,
            path: Routes.mePath,
            builder: (_, __) => const PlaceholderScreen(
              screenName: '08 Profile & settings',
              routePath: Routes.mePath,
            ),
          ),
          GoRoute(
            name: Routes.goalsName,
            path: Routes.goalsPath,
            builder: (_, __) => const PlaceholderScreen(
              screenName: '07 Goals',
              routePath: Routes.goalsPath,
            ),
            routes: <RouteBase>[
              GoRoute(
                name: Routes.goalsNewName,
                path: 'new',
                builder: (_, __) => const PlaceholderScreen(
                  screenName: '07 Goals — New goal',
                  routePath: Routes.goalsNewPath,
                ),
              ),
            ],
          ),
        ],
      ),

      // Outside the shell — full-page contexts. No nav chrome.
      GoRoute(
        name: Routes.foodDetailName,
        path: Routes.foodDetailPath,
        builder: (_, state) => PlaceholderScreen(
          screenName: '03 Food detail',
          routePath: '/foods/${state.pathParameters['foodId']}',
          detail: 'foodId = ${state.pathParameters['foodId']}',
        ),
      ),
      GoRoute(
        name: Routes.foodNewName,
        path: Routes.foodNewPath,
        builder: (_, __) => const PlaceholderScreen(
          screenName: '05 Custom food',
          routePath: Routes.foodNewPath,
        ),
      ),
      GoRoute(
        name: Routes.foodBarcodeName,
        path: Routes.foodBarcodePath,
        builder: (_, state) => PlaceholderScreen(
          screenName: 'Barcode resolve',
          routePath: '/foods/barcode/${state.pathParameters['barcode']}',
          detail: 'barcode = ${state.pathParameters['barcode']}',
        ),
      ),
      GoRoute(
        name: Routes.onboardingName,
        path: Routes.onboardingPath,
        builder: (_, state) => PlaceholderScreen(
          screenName: '09 Onboarding',
          routePath: '/onboarding/${state.pathParameters['step']}',
          detail: 'step = ${state.pathParameters['step']}',
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
