import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/auth_config.dart';
import '../../../theme/context_extensions.dart';

/// Read-only "Server: ${auth_config.baseUrl}" row on the profile screen.
///
/// LOG-009 / PM §10 punt-list-promotion. The user needs to see which
/// server they're signed into; this row is informational only. No
/// `onTap`, no trailing chevron, no edit affordance — PM §10
/// anti-recommendation 10 ("no 'switch server' in-app affordance
/// separate from sign-out"). To change servers, the user signs out and
/// re-enters the URL on the login screen per LOG-S4.
///
/// Reads through `baseUrlProvider` rather than touching Hive directly
/// — the UI layer depends on a Riverpod seam, never on the concrete
/// store (testability requirement: widget tests must be exercisable
/// without standing up a real Hive box).
///
/// When no `baseUrl` is persisted yet (fresh install before first
/// sign-in), the row collapses to `SizedBox.shrink()` — no visible
/// chrome.
class ServerUrlRow extends ConsumerWidget {
  const ServerUrlRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = ref.watch(baseUrlProvider);
    if (url == null || url.isEmpty) {
      return const SizedBox.shrink(); // signed-out path
    }
    return ListTile(
      leading: Icon(Icons.dns_outlined, color: context.colors.ink3),
      title: Text('Server', style: context.text.meta),
      subtitle: Text(url, style: context.text.body),
      dense: true,
      // Read-only — no trailing chevron, no onTap.
    );
  }
}
