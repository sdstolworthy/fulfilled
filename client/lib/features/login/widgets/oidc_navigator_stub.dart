import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'oidc_navigator.dart';

/// Mobile / desktop OIDC navigator — in-app webview that intercepts
/// the redirect-back to the FE origin and captures the handoff code.
///
/// The flow:
///   1. [startFlow] pushes a full-screen route hosting a
///      [WebViewWidget] pointed at the backend's `/auth/oidc/{p}/start`.
///   2. The backend 302s to the IdP; the user signs in there inside
///      the webview.
///   3. The IdP redirects back to the backend's `/callback`; the
///      backend mints a handoff code and 302s to
///      `<LOSEIT_FE_ORIGIN>/?oidc_code=<code>#/login` (or
///      `?oidc_error=<code>` on failure).
///   4. The webview's [NavigationDelegate.onNavigationRequest] sees a
///      URL whose query carries `oidc_code` (or `oidc_error`),
///      [NavigationDecision.prevent]s the navigation, completes the
///      result future, and pops the route.
///   5. [OidcButton] receives the result and calls `runOidcExchange`
///      with the captured handoff.
///
/// **No backend change required.** The same redirect target the web
/// flow uses is what we intercept here — the in-app webview never
/// actually navigates to the FE origin; it just observes the URL the
/// browser was about to load and pulls the query params off it.
///
/// **Why webview and not a system browser session?** A system
/// `ASWebAuthenticationSession` (iOS) / Chrome Custom Tab (Android)
/// flow is the spec-correct shape (Apple/Google's preferred path for
/// auth), but it requires either an app-link / universal-link setup
/// or a custom URL scheme the backend redirects to — both involve
/// extra ops. The in-app webview works against the current backend
/// unchanged; for a closed-beta dev experience that's the right
/// trade-off. Revisit when we ship to an app store.
class _MobileNavigator implements OidcNavigator {
  const _MobileNavigator();

  @override
  Future<OidcFlowResult> startFlow(
    String startUrl, {
    required BuildContext context,
  }) async {
    final result = await Navigator.of(context, rootNavigator: true)
        .push<OidcFlowResult>(
      MaterialPageRoute<OidcFlowResult>(
        fullscreenDialog: true,
        builder: (_) => _OidcWebViewRoute(startUrl: startUrl),
      ),
    );
    return result ?? const OidcFlowCancelled();
  }

  @override
  void stripQueryParam(String name) {
    // No-op on mobile — there's no document URL to clean.
  }
}

/// Full-screen route that hosts the OIDC webview. Owns the
/// [WebViewController] + the result-completion handshake so the
/// navigation-delegate side-channel cleanly resolves the future
/// [_MobileNavigator.startFlow] returned.
class _OidcWebViewRoute extends StatefulWidget {
  const _OidcWebViewRoute({required this.startUrl});

  final String startUrl;

  @override
  State<_OidcWebViewRoute> createState() => _OidcWebViewRouteState();
}

class _OidcWebViewRouteState extends State<_OidcWebViewRoute> {
  late final WebViewController _controller;

  /// True once we've handed a result back to the caller — stops the
  /// `dispose` path from popping again.
  bool _resolved = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: _onNavigationRequest,
      ))
      ..loadRequest(Uri.parse(widget.startUrl));
  }

  /// Inspect each navigation target. The backend's success redirect
  /// carries `?oidc_code=<handoff>` in the URL's query (regardless of
  /// the FE origin); the failure path carries `?oidc_error=<code>`.
  /// Either case completes the flow without letting the webview
  /// actually navigate to the FE origin.
  NavigationDecision _onNavigationRequest(NavigationRequest req) {
    final uri = Uri.tryParse(req.url);
    if (uri == null) return NavigationDecision.navigate;
    final code = uri.queryParameters['oidc_code'];
    if (code != null && code.isNotEmpty) {
      _resolveWith(OidcFlowHandoff(code));
      return NavigationDecision.prevent;
    }
    final err = uri.queryParameters['oidc_error'];
    if (err != null && err.isNotEmpty) {
      _resolveWith(OidcFlowError(err));
      return NavigationDecision.prevent;
    }
    return NavigationDecision.navigate;
  }

  void _resolveWith(OidcFlowResult result) {
    if (_resolved) return;
    _resolved = true;
    // Pop on the next frame so the prevented navigation completes
    // its delegate work before the route disposes.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pop(result);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sign in'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () {
            if (_resolved) return;
            _resolved = true;
            Navigator.of(context).pop(const OidcFlowCancelled());
          },
        ),
      ),
      body: WebViewWidget(controller: _controller),
    );
  }
}

const OidcNavigator navigatorImpl = _MobileNavigator();
