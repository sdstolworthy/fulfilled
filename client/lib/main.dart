import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'app.dart';
import 'data/outbox/log_outbox_notifier.dart';

/// Entrypoint. Order matters:
///
/// 1. Ensure the Flutter binding so plugin channels are wired.
/// 2. Open Hive against `path_provider`'s app-documents directory
///    (`Hive.initFlutter` does both).
/// 3. Open the `outbox_log` box. The outbox notifier reads from it
///    synchronously after construction; if the box isn't open we crash —
///    we'd rather fail loud at boot than silently lose log writes.
/// 4. Run the app with the outbox box wired into the provider override.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  final outboxBox = await Hive.openBox<String>(outboxBoxName);

  runApp(
    ProviderScope(
      overrides: <Override>[
        outboxBoxProvider.overrideWithValue(outboxBox),
      ],
      child: const FulfilledApp(),
    ),
  );
}
