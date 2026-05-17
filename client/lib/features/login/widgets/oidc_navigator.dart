/// Cross-platform full-page navigation for the OIDC redirect flow.
///
/// The OIDC start route on the backend issues a 302 with the IdP's
/// authorize URL. For that to work the browser must follow the 302 —
/// not Dio (which would try to decode the response body). On web we
/// set `window.location.href`; on mobile we'd use `url_launcher` in
/// external-application mode, but mobile OIDC is v1.1 work (the
/// stub on the non-web side intentionally throws so a caller misuse
/// surfaces loudly during dev).

import 'oidc_navigator_stub.dart'
    if (dart.library.html) 'oidc_navigator_web.dart';

abstract class OidcNavigator {
  /// Take the browser to [url]. Returns immediately — the page is
  /// torn down and rebuilt on the redirect target, so anything the
  /// caller does after this is moot.
  void redirect(String url);

  static OidcNavigator get instance => navigatorImpl;
}
