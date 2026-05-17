// ignore: deprecated_member_use
import 'dart:html' as html;

import 'oidc_navigator.dart';

/// Web implementation — full-page redirect via `window.location.href`.
/// The browser tears down the Flutter view and loads the IdP's
/// authorize URL; control comes back when the IdP redirects to the
/// backend's `/auth/oidc/{id}/callback`, which in turn redirects to
/// the FE's `/login/callback?code=...`. The FE picks the code up via
/// the `/login/callback` route handler.
class _WebNavigator implements OidcNavigator {
  const _WebNavigator();

  @override
  void redirect(String url) {
    html.window.location.href = url;
  }
}

const OidcNavigator navigatorImpl = _WebNavigator();
