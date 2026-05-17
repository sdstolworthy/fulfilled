import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'app.dart';
import 'data/auth_config.dart';
import 'data/outbox/log_outbox_notifier.dart';
import 'data/secure_token_store.dart';

/// Entrypoint. Order matters:
///
/// 1. Ensure the Flutter binding so plugin channels are wired.
/// 2. Open Hive against `path_provider`'s app-documents directory
///    (`Hive.initFlutter` does both).
/// 3. Open the `outbox_log` and `auth_config` boxes in parallel. The
///    outbox notifier reads its box synchronously after construction;
///    `auth_config` is read by the login screen + the base-URL
///    provider. If either box isn't open we crash — we'd rather fail
///    loud at boot than silently lose log writes or run with a
///    not-yet-hydrated server URL. LOG-003 (architect §4.2).
/// 4. Construct the `SecureTokenStore` (`flutter_secure_storage`
///    backed) and pass it through a provider override so the
///    `AuthTokenNotifier` can hydrate from it on first build.
/// 5. Run the app with all three overrides wired into `ProviderScope`.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();

  // Parallel open: both boxes are small (a few keys each); doing them
  // sequentially adds ~10 ms of boot time on a cold start. Both boxes
  // happen to be `Box<String>` so a single `Future.wait` with a uniform
  // element type stays well-typed.
  final boxes = await Future.wait<Box<String>>(<Future<Box<String>>>[
    Hive.openBox<String>(outboxBoxName),
    Hive.openBox<String>(authConfigBoxName),
  ]);
  final outboxBox = boxes[0];
  final authConfigBox = boxes[1];

  final secureTokenStore = SecureTokenStore();

  runApp(
    ProviderScope(
      overrides: <Override>[
        outboxBoxProvider.overrideWithValue(outboxBox),
        authConfigBoxProvider.overrideWithValue(authConfigBox),
        secureTokenStoreProvider.overrideWithValue(secureTokenStore),
      ],
      child: const FulfilledApp(),
    ),
  );
}
