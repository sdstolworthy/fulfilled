import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Coarse connectivity signal: `true` when any non-`none` interface is up.
///
/// Drives [LogOutboxNotifier] flushes (architecture §5 Outbox subsection).
/// We deliberately do not distinguish wifi vs cellular vs ethernet — the
/// outbox flushes on any non-`none` transition, and the user does not see
/// network type anywhere in v1.
///
/// On web, `connectivity_plus` returns `wifi` while the page is loaded and
/// `none` when navigator.onLine is false. That's good enough for the outbox
/// gate on `compact` web (rare, but a phone-in-PWA case).
final connectivityProvider = StreamProvider<bool>((ref) {
  final controller = StreamController<bool>();
  final connectivity = Connectivity();

  Future<void> emitFromList(List<ConnectivityResult> results) async {
    final online = results.any((r) => r != ConnectivityResult.none);
    controller.add(online);
  }

  // Seed the stream with the current state so consumers don't have to wait
  // for the first interface change to know whether to flush.
  unawaited(
    connectivity.checkConnectivity().then(
      emitFromList,
      onError: (Object _, StackTrace __) => controller.add(true),
    ),
  );

  final sub = connectivity.onConnectivityChanged.listen(emitFromList);

  ref.onDispose(() {
    sub.cancel();
    controller.close();
  });

  return controller.stream;
});
