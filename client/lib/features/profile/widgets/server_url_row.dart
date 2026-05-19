import 'package:flutter/material.dart';

import '../../../theme/context_extensions.dart';

/// Read-only "Server: ${baseUrl}" row on the profile screen.
///
/// LOG-009 / PM §10 punt-list-promotion. The user needs to see which
/// server they're signed into; this row is informational only. No
/// `onTap`, no trailing chevron, no edit affordance — PM §10
/// anti-recommendation 10 ("no 'switch server' in-app affordance
/// separate from sign-out"). To change servers, the user signs out and
/// re-enters the URL on the login screen per LOG-S4.
///
/// **Pure presentation widget** — `baseUrl` arrives via constructor
/// parameter (see `specs/testing_guide.md` §4.4). The container
/// (`ProfileScreen`) reads `baseUrlProvider` and passes the resolved
/// value down.
///
/// When [url] is `null` or empty (fresh install before first sign-in),
/// the row collapses to `SizedBox.shrink()` — no visible chrome.
class ServerUrlRow extends StatelessWidget {
  const ServerUrlRow({super.key, required this.url});

  /// The configured server base URL, or `null` / empty on a fresh
  /// install. Empty values collapse to a `SizedBox.shrink()`.
  final String? url;

  @override
  Widget build(BuildContext context) {
    final value = url;
    if (value == null || value.isEmpty) {
      return const SizedBox.shrink(); // signed-out path
    }
    return ListTile(
      leading: Icon(Icons.dns_outlined, color: context.colors.ink3),
      title: Text('Server', style: context.text.meta),
      subtitle: Text(value, style: context.text.body),
      dense: true,
      // Read-only — no trailing chevron, no onTap.
    );
  }
}
