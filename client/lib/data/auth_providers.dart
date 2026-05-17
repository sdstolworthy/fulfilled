import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api_client.dart';

/// Public auth-discovery DTO returned by `GET /api/v1/auth/providers`.
///
/// The shape mirrors backend's Ask 8 ship: a `local` capability flag
/// plus a list of configured OIDC providers, each carrying the
/// metadata the FE needs to render a "Sign in with X" button + start
/// the redirect flow.
///
/// Endpoint is `security: []` — it's read before the user is signed in,
/// so the login screen can render the button list before the auth
/// gate fires.
class AuthProviders {
  const AuthProviders({required this.local, required this.oidc});

  /// Whether local username/password auth (BE-008) is mounted.
  final bool local;

  /// One entry per configured OIDC provider. Empty when no OIDC
  /// providers are configured; the login screen renders no buttons
  /// in that case and falls back to credentials-only.
  final List<OidcProviderMeta> oidc;

  factory AuthProviders.fromJson(Map<String, dynamic> json) {
    final localMap = json['local'] as Map<String, dynamic>?;
    final oidcList = (json['oidc'] as List<dynamic>? ?? const <dynamic>[])
        .cast<Map<String, dynamic>>();
    return AuthProviders(
      local: localMap?['enabled'] as bool? ?? false,
      oidc: <OidcProviderMeta>[
        for (final p in oidcList) OidcProviderMeta.fromJson(p),
      ],
    );
  }

  static const AuthProviders empty =
      AuthProviders(local: true, oidc: <OidcProviderMeta>[]);
}

/// One OIDC provider as advertised by the discovery endpoint.
///
/// `startUrl` is the path the FE navigates to when the button is
/// tapped (full-page redirect on web; external browser/webview on
/// mobile). The backend 302s to the IdP's authorize URL with the
/// PKCE challenge + state cookie attached.
class OidcProviderMeta {
  const OidcProviderMeta({
    required this.id,
    required this.displayName,
    required this.iconUrl,
    required this.startUrl,
  });

  /// Stable lowercase id, e.g. `'authentik'`. Used as a map key and
  /// surfaces in URL paths for the start/callback routes.
  final String id;

  /// Human-readable provider name, e.g. `'Authentik'`. Rendered on
  /// the button label.
  final String displayName;

  /// Optional absolute icon URL. Empty string when none — FE falls
  /// back to a generic OIDC glyph.
  final String iconUrl;

  /// Relative start-path under the api origin, e.g.
  /// `'/api/v1/auth/oidc/authentik/start'`. Resolve against the api
  /// origin (not the FE origin) when navigating.
  final String startUrl;

  bool get hasIcon => iconUrl.isNotEmpty;

  factory OidcProviderMeta.fromJson(Map<String, dynamic> json) {
    return OidcProviderMeta(
      id: json['id'] as String,
      displayName: json['display_name'] as String? ?? json['id'] as String,
      iconUrl: json['icon_url'] as String? ?? '',
      startUrl: json['start_url'] as String,
    );
  }
}

/// Live-fetched auth-provider discovery doc.
///
/// `autoDispose` so the discovery doc is re-fetched whenever the user
/// returns to the login screen (and never staled while the user is
/// signed in). On network failure the provider exposes the error;
/// the login screen falls back to the credentials-only form (no
/// OIDC buttons) so the user can still sign in if they have local
/// creds.
final authProvidersProvider = FutureProvider.autoDispose<AuthProviders>(
  (ref) async {
    final api = ref.read(apiClientProvider);
    try {
      final res = await api.dio.get<dynamic>('/auth/providers');
      final data = res.data;
      if (data is Map<String, dynamic>) {
        return AuthProviders.fromJson(data);
      }
      return AuthProviders.empty;
    } on DioException {
      // Discovery endpoint absent (older server) or unreachable: fall
      // back to credentials-only. Re-throw is wrong here — we want
      // graceful degradation, not a broken login screen.
      return AuthProviders.empty;
    }
  },
);
