import 'package:flutter/widgets.dart';

import 'oidc_navigator_stub.dart'
    if (dart.library.html) 'oidc_navigator_web.dart';

/// Outcome of an OIDC sign-in flow.
sealed class OidcFlowResult {
  const OidcFlowResult();
}

/// User cancelled (closed the webview / dismissed the browser tab).
class OidcFlowCancelled extends OidcFlowResult {
  const OidcFlowCancelled();
}

/// Server-side error reported in the redirect (`?oidc_error=…`).
/// [code] is the raw error code the IdP / backend forwarded;
/// callers render an inline message keyed off it.
class OidcFlowError extends OidcFlowResult {
  const OidcFlowError(this.code);
  final String code;
}

/// Sign-in landed back on the FE with a fresh handoff code.
/// Pass [handoff] to [`runOidcExchange`] (in `../oidc_exchange.dart`)
/// to swap it for an opaque bearer.
class OidcFlowHandoff extends OidcFlowResult {
  const OidcFlowHandoff(this.handoff);
  final String handoff;
}

/// Cross-platform driver for the backend-as-RP OIDC flow.
///
/// **Web** ([_WebNavigator]): full-page navigation via
/// `window.location.href`. The current document tears down and is
/// replaced by the IdP authorize page; control returns when the
/// backend's callback redirects the browser back to the FE origin
/// with `?oidc_code=<handoff>`. `LoginScreen.initState` reads the
/// query param off `Uri.base` and runs the exchange. [startFlow]
/// triggers the redirect and returns a future that never completes
/// (the page is gone before any awaiter could resume).
///
/// **Mobile** (`oidc_navigator_mobile.dart`, swapped in by the
/// conditional import): open the start URL in an in-app webview,
/// listen for the redirect to land on the FE origin, capture the
/// `oidc_code` query param, dismiss the webview, return the handoff.
/// The caller then runs the exchange directly (no page reload).
abstract class OidcNavigator {
  /// Open the backend's OIDC start URL and complete the flow.
  ///
  /// `context` is required on mobile to push the webview route; web
  /// ignores it. Returns:
  /// - [OidcFlowHandoff] with the captured handoff (mobile only —
  ///   web never resolves the future).
  /// - [OidcFlowCancelled] if the user closed the webview without
  ///   completing sign-in.
  /// - [OidcFlowError] if the backend reported `oidc_error` in the
  ///   redirect.
  Future<OidcFlowResult> startFlow(
    String startUrl, {
    required BuildContext context,
  });

  /// Strip a single query-string parameter from the document URL via
  /// `window.history.replaceState`. Web only — no-op on mobile (no
  /// document URL to clean).
  void stripQueryParam(String name);

  static OidcNavigator get instance => navigatorImpl;
}
