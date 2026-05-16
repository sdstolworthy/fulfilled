import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../form_factor/form_factor.dart';
import '../routing/routes.dart';
import '../theme/context_extensions.dart';

/// The responsive shell. **One widget**, three nav chromes:
///
/// - `compact`: bottom `NavigationBar` (Today / Foods / Weight / Me) + FAB
/// - `medium`: `NavigationRail` (icon + label) on the left
/// - `expanded`: 240 px sidebar (Today / Foods / Weight / Goals / My foods)
///   and a `topBarTrailing` slot for the per-screen primary action
///
/// **Slots screen agents control:**
/// - `child` — the page body. Required.
/// - `title` — text rendered in the top bar / sidebar header.
/// - `floatingActionButton` — compact-only. Medium/expanded ignore it; T-12
///   reserves the FAB for `compact`.
/// - `topBarTrailing` — expanded-only "Log food"-style primary action,
///   plus search input or actions. Medium falls back to the FAB.
///
/// **What this widget does NOT build:**
/// - The right rail. Screen 01-W owns the `RingSummaryCard` / Quick add
///   stack and renders it inside `child`, gated on `FormFactor.expanded`.
/// - Tab badges (the pending-sync dot on Today). The screen-specific
///   provider drives that — `AppScaffold` exposes raw nav, not state.
class AppScaffold extends StatelessWidget {
  const AppScaffold({
    required this.child,
    this.title,
    this.floatingActionButton,
    this.topBarTrailing,
    super.key,
  });

  final Widget child;
  final String? title;
  final Widget? floatingActionButton;
  final List<Widget>? topBarTrailing;

  @override
  Widget build(BuildContext context) {
    final formFactor = FormFactor.of(context);
    switch (formFactor) {
      case FormFactor.compact:
        return _CompactScaffold(
          title: title,
          floatingActionButton: floatingActionButton,
          child: child,
        );
      case FormFactor.medium:
        return _MediumScaffold(title: title, child: child);
      case FormFactor.expanded:
        return _ExpandedScaffold(
          title: title,
          topBarTrailing: topBarTrailing,
          child: child,
        );
    }
  }
}

// ---------------------------------------------------------------------------
// Tab tables. Compact is 4-up (Today / Foods / Weight / Me); expanded is
// 5-up (Today / Foods / Weight / Goals / My foods). The discrepancy is
// intentional — architecture §4 ("Shell structure") explains it and PM
// Risk 3 removes the Trends slot from both.
// ---------------------------------------------------------------------------

class _ShellDestination {
  const _ShellDestination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.routePath,
    required this.routeName,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final String routePath;
  final String routeName;
}

const List<_ShellDestination> _compactDestinations = <_ShellDestination>[
  _ShellDestination(
    label: 'Today',
    icon: Icons.today_outlined,
    selectedIcon: Icons.today,
    routePath: Routes.todayPath,
    routeName: Routes.todayName,
  ),
  _ShellDestination(
    label: 'Foods',
    icon: Icons.restaurant_outlined,
    selectedIcon: Icons.restaurant,
    routePath: Routes.foodsPath,
    routeName: Routes.foodsName,
  ),
  _ShellDestination(
    label: 'Weight',
    icon: Icons.monitor_weight_outlined,
    selectedIcon: Icons.monitor_weight,
    routePath: Routes.weightPath,
    routeName: Routes.weightName,
  ),
  _ShellDestination(
    label: 'Me',
    icon: Icons.person_outline,
    selectedIcon: Icons.person,
    routePath: Routes.mePath,
    routeName: Routes.meName,
  ),
];

const List<_ShellDestination> _expandedDestinations = <_ShellDestination>[
  _ShellDestination(
    label: 'Today',
    icon: Icons.today_outlined,
    selectedIcon: Icons.today,
    routePath: Routes.todayPath,
    routeName: Routes.todayName,
  ),
  _ShellDestination(
    label: 'Foods',
    icon: Icons.restaurant_outlined,
    selectedIcon: Icons.restaurant,
    routePath: Routes.foodsPath,
    routeName: Routes.foodsName,
  ),
  _ShellDestination(
    label: 'Weight',
    icon: Icons.monitor_weight_outlined,
    selectedIcon: Icons.monitor_weight,
    routePath: Routes.weightPath,
    routeName: Routes.weightName,
  ),
  _ShellDestination(
    label: 'Goals',
    icon: Icons.flag_outlined,
    selectedIcon: Icons.flag,
    routePath: Routes.goalsPath,
    routeName: Routes.goalsName,
  ),
  _ShellDestination(
    label: 'My foods',
    icon: Icons.bookmark_outline,
    selectedIcon: Icons.bookmark,
    routePath: Routes.myFoodsPath,
    routeName: Routes.myFoodsName,
  ),
];

int _activeIndex(BuildContext context, List<_ShellDestination> destinations) {
  final location = GoRouterState.of(context).matchedLocation;
  // Pick the most specific prefix that matches. `/foods/search` and `/foods`
  // both highlight the Foods tab; `/today/2026-05-15` highlights Today.
  var bestIndex = 0;
  var bestLen = -1;
  for (var i = 0; i < destinations.length; i++) {
    final path = destinations[i].routePath;
    if (location == path || location.startsWith('$path/')) {
      if (path.length > bestLen) {
        bestIndex = i;
        bestLen = path.length;
      }
    }
  }
  return bestIndex;
}

// ---------------------------------------------------------------------------
// Compact: bottom NavigationBar + FAB.
// ---------------------------------------------------------------------------

class _CompactScaffold extends StatelessWidget {
  const _CompactScaffold({
    required this.child,
    required this.title,
    required this.floatingActionButton,
  });

  final Widget child;
  final String? title;
  final Widget? floatingActionButton;

  @override
  Widget build(BuildContext context) {
    final selected = _activeIndex(context, _compactDestinations);
    return Scaffold(
      backgroundColor: context.colors.bg,
      appBar: title == null
          ? null
          : AppBar(
              title: Text(title!, style: context.text.title),
              backgroundColor: context.colors.bg,
            ),
      body: SafeArea(top: title == null, child: child),
      floatingActionButton: floatingActionButton,
      bottomNavigationBar: NavigationBar(
        selectedIndex: selected,
        onDestinationSelected: (i) =>
            context.goNamed(_compactDestinations[i].routeName),
        destinations: <NavigationDestination>[
          for (final d in _compactDestinations)
            NavigationDestination(
              icon: Icon(d.icon),
              selectedIcon: Icon(d.selectedIcon),
              label: d.label,
              tooltip: d.label,
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Medium: NavigationRail (icon + label) on the left. Shares the compact
// destination list — Goals / My foods are reachable through Me here too.
// ---------------------------------------------------------------------------

class _MediumScaffold extends StatelessWidget {
  const _MediumScaffold({required this.child, required this.title});

  final Widget child;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final selected = _activeIndex(context, _compactDestinations);
    return Scaffold(
      backgroundColor: context.colors.bg,
      body: SafeArea(
        child: Row(
          children: <Widget>[
            NavigationRail(
              selectedIndex: selected,
              onDestinationSelected: (i) =>
                  context.goNamed(_compactDestinations[i].routeName),
              labelType: NavigationRailLabelType.all,
              destinations: <NavigationRailDestination>[
                for (final d in _compactDestinations)
                  NavigationRailDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selectedIcon),
                    label: Text(d.label),
                  ),
              ],
            ),
            VerticalDivider(width: 1, color: context.colors.line),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (title != null)
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: context.space.x6,
                        vertical: context.space.x4,
                      ),
                      child: Text(title!, style: context.text.pageTitle),
                    ),
                  Expanded(child: child),
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
// Expanded: 240 px sidebar + top bar with `topBarTrailing` slot. Goals and
// My foods get their own sidebar slots here, per architecture §4.
// ---------------------------------------------------------------------------

class _ExpandedScaffold extends StatelessWidget {
  const _ExpandedScaffold({
    required this.child,
    required this.title,
    required this.topBarTrailing,
  });

  final Widget child;
  final String? title;
  final List<Widget>? topBarTrailing;

  @override
  Widget build(BuildContext context) {
    final selected = _activeIndex(context, _expandedDestinations);
    return Scaffold(
      backgroundColor: context.colors.bg,
      body: Row(
        children: <Widget>[
          _Sidebar(
            selectedIndex: selected,
            destinations: _expandedDestinations,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _ExpandedTopBar(
                  title: title,
                  trailing: topBarTrailing,
                ),
                Expanded(child: child),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.selectedIndex, required this.destinations});

  final int selectedIndex;
  final List<_ShellDestination> destinations;

  @override
  Widget build(BuildContext context) {
    // Architecture §1 names this width by spec ("persistent sidebar (240 px)"),
    // so the literal IS the contract — not a magic number. If the design grows
    // a wider sidebar in v2, this single line moves with it; everything below
    // already references tokens.
    return Container(
      width: 240,
      decoration: BoxDecoration(
        color: context.colors.surface,
        border: Border(
          right: BorderSide(color: context.colors.line),
        ),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: EdgeInsets.fromLTRB(
                context.space.x5,
                context.space.x6,
                context.space.x5,
                context.space.x4,
              ),
              child: Text('Fulfilled', style: context.text.title),
            ),
            for (var i = 0; i < destinations.length; i++)
              _SidebarTile(
                destination: destinations[i],
                selected: i == selectedIndex,
              ),
            const Spacer(),
            _SidebarTile(
              destination: const _ShellDestination(
                label: 'Me',
                icon: Icons.person_outline,
                selectedIcon: Icons.person,
                routePath: Routes.mePath,
                routeName: Routes.meName,
              ),
              selected: GoRouterState.of(context).matchedLocation == Routes.mePath,
            ),
            SizedBox(height: context.space.x4),
          ],
        ),
      ),
    );
  }
}

class _SidebarTile extends StatelessWidget {
  const _SidebarTile({required this.destination, required this.selected});

  final _ShellDestination destination;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final color = selected ? context.colors.accent : context.colors.ink2;
    return InkWell(
      onTap: () => context.goNamed(destination.routeName),
      child: Container(
        margin: EdgeInsets.symmetric(
          horizontal: context.space.x3,
          vertical: context.space.x05,
        ),
        padding: EdgeInsets.symmetric(
          horizontal: context.space.x3,
          vertical: context.space.x3,
        ),
        decoration: BoxDecoration(
          color: selected ? context.colors.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(context.radius.r2),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              selected ? destination.selectedIcon : destination.icon,
              size: 22,
              color: color,
            ),
            SizedBox(width: context.space.x3),
            Text(
              destination.label,
              style: context.text.bodyStrong.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExpandedTopBar extends StatelessWidget {
  const _ExpandedTopBar({required this.title, required this.trailing});

  final String? title;
  final List<Widget>? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.space.x6,
        vertical: context.space.x4,
      ),
      decoration: BoxDecoration(
        color: context.colors.bg,
        border: Border(bottom: BorderSide(color: context.colors.line)),
      ),
      child: Row(
        children: <Widget>[
          if (title != null)
            Expanded(child: Text(title!, style: context.text.pageTitle))
          else
            const Spacer(),
          if (trailing != null) ...trailing!,
        ],
      ),
    );
  }
}
