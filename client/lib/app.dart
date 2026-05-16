import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'routing/app_router.dart';
import 'theme/theme_data.dart';

/// The app root. Stays small on purpose — the heavy lifting (theme,
/// router, providers) lives in dedicated modules. `main.dart` wraps this
/// in `ProviderScope` after Hive is open.
class FulfilledApp extends ConsumerWidget {
  const FulfilledApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    return MaterialApp.router(
      title: 'Fulfilled',
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(),
      // v1 is light-only (PM Risk 5). When dark mode lands, add `darkTheme`
      // and a `themeMode` driven by user preference, not OS by default —
      // that question is part of the v2 design pass.
      routerConfig: router,
    );
  }
}
