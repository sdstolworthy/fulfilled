import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/auth_providers.dart';
import '../../../providers/api_base_url_provider.dart';
import '../../../theme/context_extensions.dart';
import 'oidc_navigator.dart';

/// A "Sign in with <provider>" button.
///
/// Rendered once per entry in [authProvidersProvider]'s `oidc` list,
/// stacked above the local credentials form on `LoginScreen` (Ask 8).
/// Tapping the button takes the browser to the backend's start route
/// for the provider; the backend 302s to the IdP, the IdP redirects
/// back to the backend's callback, which 302s the browser to
/// `/login/callback?code=<handoff>` on the FE. The FE handles the
/// final code-exchange there.
///
/// **Styling.** T-04 reserves the solid-accent fill for the single
/// primary action on the screen — `LoginButton` (the "Sign in"
/// password submit). OIDC buttons are a *secondary* style: ink-on-
/// surface with a hairline border, matching the design system's
/// secondary button shape. Same 54-px height + radius as the primary
/// so the column reads as a single button stack.
class OidcButton extends ConsumerWidget {
  const OidcButton({super.key, required this.provider});

  final OidcProviderMeta provider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final radius = context.radius;
    final apiBase = ref.watch(apiBaseUrlProvider);

    void onPressed() {
      final url = _resolveStartUrl(apiBase, provider.startUrl);
      OidcNavigator.instance.redirect(url);
    }

    return SizedBox(
      width: double.infinity,
      height: 54,
      child: OutlinedButton(
        onPressed: apiBase == null ? null : onPressed,
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
              Image.network(
                provider.iconUrl,
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
              'Sign in with ${provider.displayName}',
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
/// origin. We strip the `/api/v1` suffix off `apiBase` and concat with
/// the relative `startUrl` (which already includes `/api/v1`) so the
/// final URL doesn't double the prefix.
///
/// Example:
///   apiBase   = `https://api.coolify.stolworthy.co/api/v1`
///   startUrl  = `/api/v1/auth/oidc/authentik/start`
///   resolved  = `https://api.coolify.stolworthy.co/api/v1/auth/oidc/authentik/start`
String _resolveStartUrl(String? apiBase, String startUrl) {
  if (apiBase == null) return startUrl;
  // If start_url is already absolute, just use it.
  if (startUrl.startsWith('http://') || startUrl.startsWith('https://')) {
    return startUrl;
  }
  // Strip /api/v1 suffix off the base to get the origin.
  final origin = apiBase.endsWith('/api/v1')
      ? apiBase.substring(0, apiBase.length - '/api/v1'.length)
      : apiBase;
  return '$origin$startUrl';
}
