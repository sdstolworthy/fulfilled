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
/// Hive read is synchronous; this is a `ConsumerWidget`, not a
/// `ConsumerStatefulWidget`. The row does not auto-refresh on
/// `box.put` — acceptable for v1 because the only path that mutates
/// `baseUrl` mid-session is sign-out → sign-in, and the user is off
/// the profile screen during that path (see ticket Notes).
///
/// When the box has no `baseUrl` (fresh install before first sign-in),
/// the row collapses to `SizedBox.shrink()` — no visible chrome.
class ServerUrlRow extends ConsumerWidget {
  const ServerUrlRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final box = ref.watch(authConfigBoxProvider);
    final url = box.get(AuthConfigKey.baseUrl);
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
