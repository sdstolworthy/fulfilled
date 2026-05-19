import 'package:flutter/material.dart';

import '../../../data/auth_providers.dart';
import '../../../theme/context_extensions.dart';

/// A `Sign in with <provider>` button.
///
/// Rendered once per entry in `authProvidersProvider`'s `oidc` list,
/// stacked above the local credentials form on `LoginScreen` (Ask 8).
///
/// **Web** — tap triggers a full-page redirect to the backend start
/// URL via `OidcNavigator.startFlow`. The browser tears down the
/// Flutter view; control returns when the backend's callback
/// redirects back to the FE origin with `?oidc_code=<handoff>` and
/// `LoginScreen.initState` runs the exchange.
///
/// **Mobile** — tap opens the start URL in an in-app webview (also
/// via `OidcNavigator.startFlow`); the navigator listens for the
/// redirect carrying `oidc_code`, captures it, dismisses the webview,
/// and returns the handoff. The container then runs the exchange
/// inline via `runOidcExchange` and routes to `/today` on success.
///
/// **Styling.** T-04 reserves the solid-accent fill for the single
/// primary action on the screen — `LoginButton` (the password
/// submit). OIDC buttons are a *secondary* style: ink-on-surface
/// with a hairline border. Same 54-px height + radius as the
/// primary so the column reads as a single button stack.
///
/// **Pure presentation widget** — see `specs/testing_guide.md` §4.4.
/// This file imports nothing from `package:flutter_riverpod`,
/// `go_router`, or `oidc_exchange.dart` / `oidc_navigator.dart`. The
/// container (`LoginScreen`) owns the `apiBaseUrlProvider` watch + the
/// `OidcNavigator.startFlow` / `runOidcExchange` orchestration and
/// passes back a single `onOidcTap` callback per button.
///
/// **Inputs.**
/// - `provider` — display name, icon URL, and start URL.
/// - `apiBase` — current API base URL (null disables the button while
///   the URL is still resolving).
/// - `busy` — true while the orchestration the container drives is in
///   flight; swaps the label for "Signing in…" and disables taps to
///   prevent double-submits.
/// - `onOidcTap` — fired on tap. Container kicks off the flow.
class OidcButton extends StatelessWidget {
  const OidcButton({
    super.key,
    required this.provider,
    required this.apiBase,
    required this.busy,
    required this.onOidcTap,
  });

  final OidcProviderMeta provider;
  final String? apiBase;
  final bool busy;
  final VoidCallback onOidcTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final radius = context.radius;

    return SizedBox(
      width: double.infinity,
      height: 54,
      child: OutlinedButton(
        onPressed: apiBase == null || busy ? null : onOidcTap,
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
            if (provider.hasIcon) ...<Widget>[
              // Perf (Flutter doc — "Performance" on Image): decode the
              // network bitmap at the painted resolution (40 px to
              // cover 2x DPR) instead of the source resolution. IdP
              // icon URLs commonly serve a 256-px favicon; without the
              // cache-size cap, the full 256² ARGB blob lives in
              // `PaintingBinding.instance.imageCache` and pays a
              // larger decode cost per IdP button.
              Image.network(
                provider.iconUrl,
                width: 20,
                height: 20,
                cacheWidth: 40,
                cacheHeight: 40,
                errorBuilder: (_, __, ___) =>
                    Icon(Icons.shield_outlined, size: 20, color: colors.ink2),
              ),
              SizedBox(width: context.space.x2),
            ] else ...<Widget>[
              Icon(Icons.shield_outlined, size: 20, color: colors.ink2),
              SizedBox(width: context.space.x2),
            ],
            Text(
              busy
                  ? 'Signing in…'
                  : 'Sign in with ${provider.displayName}',
              style: context.text.bodyStrong,
            ),
          ],
        ),
      ),
    );
  }
}
