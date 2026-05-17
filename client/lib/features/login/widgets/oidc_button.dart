import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../data/auth_providers.dart';
import '../../../providers/api_base_url_provider.dart';
import '../../../routing/routes.dart';
import '../../../theme/context_extensions.dart';
import '../oidc_exchange.dart';
import 'oidc_navigator.dart';

/// A "Sign in with <provider>" button.
///
/// Rendered once per entry in [authProvidersProvider]'s `oidc` list,
/// stacked above the local credentials form on `LoginScreen` (Ask 8).
///
/// **Web** — tap triggers a full-page redirect to the backend start
/// URL via [OidcNavigator.startFlow]. The browser tears down the
/// Flutter view; control returns when the backend's callback
/// redirects back to the FE origin with `?oidc_code=<handoff>` and
/// `LoginScreen.initState` runs the exchange.
///
/// **Mobile** — tap opens the start URL in an in-app webview (also
/// via [OidcNavigator.startFlow]); the navigator listens for the
/// redirect carrying `oidc_code`, captures it, dismisses the webview,
/// and returns the handoff. The button then runs the exchange
/// inline via [runOidcExchange] and routes to `/today` on success.
///
/// **Styling.** T-04 reserves the solid-accent fill for the single
/// primary action on the screen — `LoginButton` (the password
/// submit). OIDC buttons are a *secondary* style: ink-on-surface
/// with a hairline border. Same 54-px height + radius as the
/// primary so the column reads as a single button stack.
class OidcButton extends ConsumerStatefulWidget {
  const OidcButton({super.key, required this.provider});

  final OidcProviderMeta provider;

  @override
  ConsumerState<OidcButton> createState() => _OidcButtonState();
}

class _OidcButtonState extends ConsumerState<OidcButton> {
  /// True while the webview is open or the exchange is in flight.
  /// On web this never transitions back to false (the page tears
  /// down during `startFlow`), but the visual loading state is fine
  /// for the brief moment between tap and redirect.
  bool _busy = false;

  Future<void> _onPressed() async {
    final apiBase = ref.read(apiBaseUrlProvider);
    if (apiBase == null) return;

    setState(() => _busy = true);
    try {
      final url = _resolveStartUrl(apiBase, widget.provider.startUrl);
      final result =
          await OidcNavigator.instance.startFlow(url, context: context);

      if (!mounted) return;

      switch (result) {
        case OidcFlowHandoff(:final handoff):
          final exchange =
              await runOidcExchange(ref: ref, handoff: handoff);
          if (!mounted) return;
          switch (exchange) {
            case OidcExchangeSuccess():
              context.go(Routes.todayPath);
            case OidcExchangeError(:final message):
              _surfaceError(message);
          }
        case OidcFlowError(:final code):
          _surfaceError(_messageForError(code));
        case OidcFlowCancelled():
          // User closed the webview — silent.
          break;
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _surfaceError(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }

  /// Map an IdP / backend `oidc_error` code onto a render-ready
  /// message. The codes are forwarded verbatim by the backend — we
  /// translate the common ones; everything else falls back to a
  /// generic line.
  String _messageForError(String code) {
    switch (code) {
      case 'access_denied':
        return 'Sign-in cancelled — access denied by the provider.';
      case 'state_mismatch':
        return 'Sign-in failed — state mismatch. Please try again.';
      case 'expired':
        return 'Sign-in expired before completion. Please try again.';
      default:
        return 'Sign-in failed: $code';
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = context.radius;
    final apiBase = ref.watch(apiBaseUrlProvider);

    return SizedBox(
      width: double.infinity,
      height: 54,
      child: OutlinedButton(
        onPressed: apiBase == null || _busy ? null : _onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: colors.ink,
          backgroundColor: colors.surface,
          side: BorderSide(color: colors.line2, width: 1),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius.r3),
          ),
          padding: EdgeInsets.symmetric(horizontal: context.space.x4),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            if (widget.provider.hasIcon) ...<Widget>[
              Image.network(
                widget.provider.iconUrl,
                width: 20,
                height: 20,
                errorBuilder: (_, __, ___) =>
                    Icon(Icons.shield_outlined, size: 20, color: colors.ink2),
              ),
              SizedBox(width: context.space.x2),
            ] else ...<Widget>[
              Icon(Icons.shield_outlined, size: 20, color: colors.ink2),
              SizedBox(width: context.space.x2),
            ],
            Text(
              _busy
                  ? 'Signing in…'
                  : 'Sign in with ${widget.provider.displayName}',
              style: context.text.bodyStrong,
            ),
          ],
        ),
      ),
    );
  }
}

/// Resolve a backend-relative start URL (e.g.
/// `/api/v1/auth/oidc/authentik/start`) against the configured api
/// origin. We strip the `/api/v1` suffix off `apiBase` and concat
/// with the relative `startUrl` (which already includes `/api/v1`)
/// so the final URL doesn't double the prefix.
String _resolveStartUrl(String? apiBase, String startUrl) {
  if (apiBase == null) return startUrl;
  if (startUrl.startsWith('http://') || startUrl.startsWith('https://')) {
    return startUrl;
  }
  final origin = apiBase.endsWith('/api/v1')
      ? apiBase.substring(0, apiBase.length - '/api/v1'.length)
      : apiBase;
  return '$origin$startUrl';
}
