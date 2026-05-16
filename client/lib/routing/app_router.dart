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
/// Each leaf binds to its real `<Name>Screen` from `lib/features/<name>/`.
/// `/foods/mine` and `/foods/barcode/:barcode` are still `PlaceholderScreen`
/// pending dedicated implementations.

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
        builder: (_, __) => const CustomFoodScreen(),
      ),
      GoRoute(
        name: Routes.foodBarcodeName,
        path: Routes.foodBarcodePath,
        builder: (_, state) => PlaceholderScreen(
          screenName: 'Barcode resolve',
          routePath: '/foods/barcode/${state.pathParameters['barcode']}',
          detail: 'Resolver pending. The scanner pushes here on detection; '
              'this route should look up the food by barcode and redirect '
              'to /foods/:foodId.',
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
